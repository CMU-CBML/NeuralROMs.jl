#
using GeometryLearning
using LinearAlgebra, ComponentArrays              # arrays
using Random, Lux, MLUtils, ParameterSchedulers   # ML
using OptimizationOptimJL, OptimizationOptimisers # opt
using LinearSolve, NonlinearSolve, LineSearches   # num
using Plots, JLD2                                 # vis / save
using CUDA, LuxCUDA, KernelAbstractions           # GPU

CUDA.allowscalar(false)

# using FFTW
begin
    nt = Sys.CPU_THREADS
    nc = min(nt, length(Sys.cpu_info()))

    BLAS.set_num_threads(nc)
    # FFTW.set_num_threads(nt)
end

#======================================================#

function cae_network(
    prob::GeometryLearning.AbstractPDEProblem,
    l::Integer,
    w::Integer,
    act,
)

    if prob isa Advection1D # 128 -> l -> 128
        encoder = Chain(
            Conv((8,), 1 => w, act; stride = 4, pad = 2), # /4
            Conv((8,), w => w, act; stride = 4, pad = 2), # /4
            Conv((8,), w => w, act; stride = 4, pad = 2), # /4
            Conv((2,), w => w, act; stride = 1, pad = 0), # /2
            flatten,
            Dense(w, l),
        )

        decoder = Chain(
            Dense(l, w, act),
            ReshapeLayer((1, w)),
            ConvTranspose((4,), w => w, act; stride = 1, pad = 0), # *4
            ConvTranspose((8,), w => w, act; stride = 4, pad = 2), # *4
            ConvTranspose((8,), w => w, act; stride = 4, pad = 2), # *4
            ConvTranspose((8,), w => 1     ; stride = 2, pad = 3), # *2
        )

        Chain(;encoder, decoder)

    elseif prob isa Burgers1D # 1024 -> l -> 1024

        encoder = Chain(
            Conv((8,), 1 => w, act; stride = 4, pad = 2), # /4
            Conv((8,), w => w, act; stride = 4, pad = 2), # /4
            Conv((8,), w => w, act; stride = 4, pad = 2), # /4
            Conv((2,), w => w, act; stride = 1, pad = 0), # /2
            flatten,
            Dense(w, l),
        )

        decoder = Chain(
            Dense(l, w, act),
            ReshapeLayer((1, w)),
            ConvTranspose((4,), w => w, act; stride = 1, pad = 0), # *4
            ConvTranspose((8,), w => w, act; stride = 4, pad = 2), # *4
            ConvTranspose((8,), w => w, act; stride = 4, pad = 2), # *4
            ConvTranspose((8,), w => 1     ; stride = 2, pad = 3), # *2
        )

        Chain(;encoder, decoder)
    end

    ###################

    # encoder = Chain(
    #     Conv((4,), 1 => w, act; stride = 4, pad = 0), # /4
    #     Conv((4,), w => w, act; stride = 4, pad = 0), # /4
    #     Conv((2,), w => w, act; stride = 2, pad = 0), # /2
    #     Conv((2,), w => w, act; stride = 2, pad = 0), # /2
    #     Conv((2,), w => w, act; stride = 2, pad = 0), # /2
    #     flatten,
    #     Dense(w, l),
    # )
    #
    # decoder = Chain(
    #     Dense(l, w, act),
    #     ReshapeLayer((1, w)),
    #     ConvTranspose((4,), w => w, act; stride = 1, pad = 0), # 1 -> 4
    #     ConvTranspose((4,), w => w, act; stride = 4, pad = 0), # *4
    #     ConvTranspose((2,), w => w, act; stride = 2, pad = 0), # *2
    #     ConvTranspose((2,), w => w, act; stride = 2, pad = 0), # *2
    #     ConvTranspose((2,), w => 1, act; stride = 2, pad = 0), # *2
    # )
    #
    # Chain(;encoder, decoder)

    ###################

end
#======================================================#
function makedata_CAE(
    datafile::String;
    Ix = Colon(), # subsample in space
    _Ib = Colon(), # train/test split in batches
    Ib_ = Colon(),
    _It = Colon(), # train/test split in time
    It_ = Colon(),
)

    #==============#
    # load data
    #==============#
    data = jldopen(datafile)
    t  = data["t"]
    x  = data["x"]
    u  = data["u"] # [Nx, Nb, Nt] or [out_dim, Nx, Nb, Nt]
    mu = data["mu"]
    md_data = data["metadata"]
    close(data)
    
    @assert ndims(u) ∈ (3,4,)
    @assert x isa AbstractVecOrMat
    x = x isa AbstractVector ? reshape(x, 1, :) : x # (Dim, Npoints)

    if ndims(u) == 3 # [Nx, Nb, Nt]
        u = reshape(u, 1, size(u)...) # [1, Nx, Nb, Nt]
    end
    
    in_dim  = size(x, 1)
    out_dim = size(u, 1)
    
    println("input size $in_dim with $(size(x, 2)) points per trajectory.")
    println("output size $out_dim.")
    
    @assert eltype(x) === Float32
    @assert eltype(u) === Float32
    
    #==============#
    # normalize
    #==============#
    
    ū  = sum(u, dims = (2,3,4)) / (length(u) ÷ out_dim) |> vec
    σu = sum(abs2, u .- ū, dims = (2,3,4)) / (length(u) ÷ out_dim) .|> sqrt |> vec
    u  = normalizedata(u, ū, σu)
    
    x̄  = sum(x, dims = 2) / size(x, 2) |> vec
    σx = sum(abs2, x .- x̄, dims = 2) / size(x, 2) .|> sqrt |> vec
    x  = normalizedata(x, x̄, σx)

    #==============#
    # subsample, test/train split
    #==============#
    _x = @view x[:, Ix]
    x_ = @view x[:, Ix]

    _u = @view u[:, Ix, _Ib, _It]
    u_ = @view u[:, Ix, Ib_, It_]

    Nx = size(_x, 2)
    @assert size(_u, 2) == size(_x, 2)

    println("Using $Nx sample points per trajectory.")

    _u = permutedims(_u, (2, 1, 3, 4))
    u_ = permutedims(_u, (2, 1, 3, 4))

    _Ns = size(_u, 3) * size(_u, 4)
    Ns_ = size(u_, 3) * size(u_, 4)

    println("$_Ns / $Ns_ trajectories in train/test sets.")

    _u = reshape(_u, Nx, out_dim, _Ns)
    u_ = reshape(u_, Nx, out_dim, Ns_)

    readme = "Train/test on 0.0-0.5."
    makedata_kws = (; Ix, _Ib, Ib_, _It, It_,)
    metadata = (; ū, σu, x̄, σx,
        Nx, _Ns, Ns_,
        makedata_kws, md_data, readme,
    )

    (_u, _u), (u_, u_), metadata
end

#======================================================#

function train_CAE(
    datafile::String,
    modeldir::String,
    NN::Lux.AbstractExplicitLayer,
    E::Int; # num epochs
    rng::Random.AbstractRNG = Random.default_rng(),
    warmup::Bool = false,
    _batchsize = nothing,
    batchsize_ = nothing,
    makedata_kws = (; Ix = :, _Ib = :, Ib_ = :, _It = :, It_ = :,),
    cb_epoch = nothing,
    device = Lux.cpu_device(),
)

    _data, _, metadata = makedata_CAE(datafile; makedata_kws...)
    dir = modeldir

    lossfun = function(NN, p, st, batch)
        x, ŷ = batch
        y, st = NN(x, p, st)
        loss = sum(abs2, ŷ - y) / length(ŷ)

        loss, st, (;)
    end

    _batchsize = isnothing(_batchsize) ? numobs(_data) ÷ 50 : _batchsize
    batchsize_ = isnothing(batchsize_) ? numobs(_data)      : batchsize_

    #--------------------------------------------#
    # optimizer
    #--------------------------------------------#
    lrs = (1f-3, 5f-4, 2f-4, 1f-4, 5f-5, 2f-5, 1f-5,)
    Nlrs = length(lrs)

    opts = Tuple(Optimisers.Adam(lr) for lr in lrs)

    nepochs = (round.(Int, E / (Nlrs) * ones(Nlrs))...,)
    schedules = Step.(lrs, 1f0, Inf32)
    early_stoppings = (fill(true, Nlrs)...,)

    if warmup
        opt_warmup = Optimisers.Adam(1f-2)
        nepochs_warmup = 10
        schedule_warmup = Step(1f-2, 1f0, Inf32)
        early_stopping_warmup = true
        
        ######################
        opts = (opt_warmup, opts...,)
        nepochs = (nepochs_warmup, nepochs...,)
        schedules = (schedule_warmup, schedules...,)
        early_stoppings = (early_stopping_warmup, early_stoppings...,)
    end

    #--------------------------------------------#

    train_args = (; E, _batchsize,)
    metadata   = (; metadata..., train_args)

    @show metadata

    @time model, ST = train_model(NN, _data; rng,
        _batchsize, batchsize_, 
        opts, nepochs, schedules, early_stoppings,
        device, dir, metadata, lossfun,
        cb_epoch,
    )

    @show metadata

    plot_training(ST...) |> display

    model, ST, metadata
end

#======================================================#
function evolve_CAE(
    prob::AbstractPDEProblem,
    datafile::String,
    modelfile::String,
    case::Integer;
    rng::Random.AbstractRNG = Random.default_rng(),

    data_kws = (; Ix = :, It = :),

    Δt::Union{Real, Nothing} = nothing,
    timealg::GeometryLearning.AbstractTimeAlg = EulerForward(),
    adaptive::Bool = false,
    scheme::Union{Nothing, GeometryLearning.AbstractSolveScheme} = nothing,

    autodiff_xyz::ADTypes.AbstractADType = AutoFiniteDiff(),
    ϵ_xyz::Union{Real, Nothing} = 1f-2,

    verbose::Bool = true,
    device = Lux.cpu_device(),
)

    #==============#
    # load data
    #==============#
    data = jldopen(datafile)
    Tdata = data["t"]
    Xdata = data["x"]
    Udata = data["u"]
    mu = data["mu"]

    close(data)

    @assert ndims(Udata) ∈ (3,4,)
    @assert Xdata isa AbstractVecOrMat
    Xdata = Xdata isa AbstractVector ? reshape(Xdata, 1, :) : Xdata # (Dim, Npoints)

    if ndims(Udata) == 3 # [Nx, Nb, Nt]
        Udata = reshape(Udata, 1, size(Udata)...) # [out_dim, Nx, Nb, Nt]
    end

    in_dim  = size(Xdata, 1)
    out_dim = size(Udata, 1)

    mu = isnothing(mu) ? fill(nothing, Nb) |> Tuple : mu
    mu = isa(mu, AbstractArray) ? vec(mu) : mu

    #==============#
    # load model
    #==============#
    model = jldopen(modelfile)
    NN, p, st = model["model"]
    md = model["metadata"] # (; ū, σu, _Ib, Ib_, _It, It_, readme)
    close(model)

    #==============#
    # subsample in space
    #==============#
    Udata = @view Udata[:, data_kws.Ix, :, data_kws.It]
    Xdata = @view Xdata[:, data_kws.Ix]
    Tdata = @view Tdata[data_kws.It]
    Nx = size(Xdata, 2)

    Ud = Udata[:, :, case, :]
    U0 = Ud[:, :, 1]

    data = (Xdata, U0, Tdata)
    data = copy.(data) # ensure no SubArrays

    #==============#
    # get encoder / decoer
    #==============#
    encoder = NN.layers.encoder, p.encoder, st.encoder
    encoder = GeometryLearning.remake_ca_in_model(encoder...)

    decoder = NN.layers.decoder, p.decoder, st.decoder
    decoder = GeometryLearning.remake_ca_in_model(decoder...)

    #==============#
    # get initial state
    #==============#
    U0_norm = normalizedata(U0, md.ū, md.σu)
    U0_perm = permutedims(U0_norm, (2, 1))
    U0_resh = reshape(U0_perm, size(U0_perm)..., 1)

    p0 = encoder[1](U0_resh, encoder[2], encoder[3])[1]
    p0 = dropdims(p0; dims = 2)

    #==============#
    # make model
    #==============#
    model = CAEModel(decoder..., Xdata, md)

    #==============#
    # evolve
    #==============#
    linsolve = QRFactorization()
    autodiff = AutoForwardDiff()
    linesearch = LineSearch()
    nlssolve = GaussNewton(;autodiff, linsolve, linesearch)
    nlsmaxiters = 10

    Δt = isnothing(Δt) ? -(-(extrema(Tdata)...)) / 100.0f0 : Δt

    if isnothing(scheme)
        scheme  = GalerkinProjection(linsolve, 1f-3, 1f-6) # abstol_inf, abstol_mse
    end

    @time _, ps, Up = evolve_model(prob, model, timealg, scheme, data, p0, Δt;
        nlssolve, nlsmaxiters, adaptive, autodiff_xyz, ϵ_xyz,
        verbose, device,
    )

    Xdata, Tdata, Ud, Up, ps
end
#======================================================#
nothing
#
