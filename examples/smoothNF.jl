#
using GeometryLearning
using LinearAlgebra, ComponentArrays              # arrays
using Random, Lux, MLUtils, ParameterSchedulers   # ML
using OptimizationOptimJL, OptimizationOptimisers # opt
using LinearSolve, NonlinearSolve, LineSearches   # num
using Plots, JLD2                                 # vis / save
using CUDA, LuxCUDA, KernelAbstractions           # GPU
using LaTeXStrings
using TSne

CUDA.allowscalar(false)

# using FFTW
begin
    nt = Sys.CPU_THREADS
    nc = min(nt, length(Sys.cpu_info()))

    BLAS.set_num_threads(nc)
    # FFTW.set_num_threads(nt)
end

include(joinpath(pkgdir(GeometryLearning), "examples", "problems.jl"))

#======================================================#
function makedata_SNF(
    datafile::String;
    Ix = Colon(), # subsample in space
    _Ib = Colon(), # train/test split in batches
    Ib_ = Colon(),
    _It = Colon(), # train/test split in time
    It_ = Colon(),
)

    # TODO makedata_SNF: allow for _Ix, Ix_ for testing
    # TODO makedata_SNF: rm _Ib, Ib_, _It, It_. makes no sense for autodecode

    #==============#
    # load data
    #==============#
    data = jldopen(datafile)
    x = data["x"]
    u = data["u"] # [Nx, Nb, Nt] or [out_dim, Nx, Nb, Nt]
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

    _u = reshape(_u, out_dim, Nx, :)
    u_ = reshape(u_, out_dim, Nx, :)

    _Ns = size(_u, 3) # number of codes i.e. # trajectories
    Ns_ = size(u_, 3)

    println("$_Ns / $Ns_ trajectories in train/test sets.")

    # indices
    _idx = zeros(Int32, Nx, _Ns)
    idx_ = zeros(Int32, Nx, Ns_)

    _idx[:, :] .= 1:_Ns |> adjoint
    idx_[:, :] .= 1:Ns_ |> adjoint

    # space
    _xyz = zeros(Float32, in_dim, Nx, _Ns)
    xyz_ = zeros(Float32, in_dim, Nx, Ns_)

    _xyz[:, :, :] .= _x
    xyz_[:, :, :] .= x_

    # solution
    _y = reshape(_u, out_dim, :)
    y_ = reshape(u_, out_dim, :)

    _x = (reshape(_xyz, in_dim, :), reshape(_idx, 1, :))
    x_ = (reshape(xyz_, in_dim, :), reshape(idx_, 1, :))

    readme = "Train/test on the same trajectory."

    makedata_kws = (; Ix, _Ib, Ib_, _It, It_)

    metadata = (; ū, σu, x̄, σx,
        Nx, _Ns, Ns_,
        makedata_kws, md_data, readme,
    )

    (_x, _y), (x_, y_), metadata
end

#===========================================================#

function train_SNF(
    datafile::String,
    modeldir::String,
    l::Int, # latent space size
    h::Int, # num hidden layers
    w::Int, # hidden layer width
    E::Int; # num epochs
    rng::Random.AbstractRNG = Random.default_rng(),
    warmup::Bool = true,
    _batchsize = nothing,
    batchsize_ = nothing,
    λ1::Real = 0f0,
    λ2::Real = 0f0,
    σ2inv::Real = 0f0,
    α::Real = 0f0,
    weight_decays::Union{Real, NTuple{M, <:Real}} = 0f0,
    WeightDecayOpt = nothing,
    weight_decay_ifunc = nothing,
    makedata_kws = (; Ix = :, _Ib = :, Ib_ = :, _It = :, It_ = :,),
    init_code = nothing,
    cb_epoch = nothing,
    device = Lux.cpu_device(),
) where{M}
    _data, _, metadata = makedata_SNF(datafile; makedata_kws...)
    dir = modeldir

    #--------------------------------------------#
    # architecture
    #--------------------------------------------#
    in_dim, out_dim = size(_data[1][1], 1), size(_data[2], 1) # in/out dim

    println("input size, output size, $in_dim, $out_dim")

    decoder = begin
        init_wt_in = scaled_siren_init(1f1)
        init_wt_hd = scaled_siren_init(1f0)
        init_wt_fn = glorot_uniform

        init_bias = rand32 # zeros32
        use_bias_fn = false

        act = sin

        wi = l + in_dim
        wo = out_dim

        in_layer = Dense(wi, w , act; init_weight = init_wt_in, init_bias)
        hd_layer = Dense(w , w , act; init_weight = init_wt_hd, init_bias)
        fn_layer = Dense(w , wo     ; init_weight = init_wt_fn, init_bias, use_bias = use_bias_fn)

        Chain(in_layer, fill(hd_layer, h)..., fn_layer)
    end

    init_code = if isnothing(init_code)
        if l < 8
            randn32 # N(μ = 0, σ2 = 1.0^2)
        else
            scale_init(randn32, 1f-1, 0f0) # N(μ = 0, σ2 = 0.1^2)
        end
    else
        init_code
    end

    NN = AutoDecoder(decoder, metadata._Ns, l; init_weight = init_code)

    _batchsize = isnothing(_batchsize) ? numobs(_data) ÷ 100 : _batchsize
    batchsize_ = isnothing(batchsize_) ? numobs(_data) ÷ 1   : batchsize_

    lossfun = regularize_autodecoder(mse; σ2inv, α, λ1, λ2)

    #--------------------------------------------#
    # training hyper-params
    #--------------------------------------------#
    lrs = (1f-3, 5f-4, 2f-4, 1f-4, 5f-5, 2f-5, 1f-5,)
    Nlrs = length(lrs)

    weightdecay = if isnothing(WeightDecayOpt) | (WeightDecayOpt === IdxWeightDecay)

        decoder_idx = if isnothing(weight_decay_ifunc) | (weight_decay_ifunc === decoder_W_indices)
            decoder_W_indices(NN; rng)   # WD on decoder weights and biases
        else
            weight_decay_ifunc(NN; rng)
        end

        IdxWeightDecay(0f0, decoder_idx)

    elseif WeightDecayOpt === DecoderWeightDecay
        ca_axes = p_axes(NN; rng)
        DecoderWeightDecay(0f0, ca_axes)
    else
        error("Unsupported weight decay algorithm")
    end

    # Grokking (https://arxiv.org/abs/2201.02177)
    # Optimisers.Adam(lr, (0.9f0, 0.95f0)), # 0.999 (default), 0.98, 0.95  # https://www.youtube.com/watch?v=IHikLL8ULa4&ab_channel=NeelNanda
    opts = Tuple(
        OptimiserChain(
            Optimisers.Adam(lr),
            weightdecay,
        ) for lr in lrs
    )

    nepochs = (round.(Int, E / (Nlrs) * ones(Nlrs))...,)
    schedules = Step.(lrs, 1f0, Inf32)
    early_stoppings = (fill(true, Nlrs)...,)

    if warmup
        opt_warmup = OptimiserChain(Optimisers.Adam(1f-2), weightdecay,)
        nepochs_warmup = 10
        schedule_warmup = Step(1f-2, 1f0, Inf32)
        early_stopping_warmup = true

        ######################
        opts = (opt_warmup, opts...,)
        nepochs = (nepochs_warmup, nepochs...,)
        schedules = (schedule_warmup, schedules...,)
        early_stoppings = (early_stopping_warmup, early_stoppings...,)
    end

    #----------------------#----------------------#

    train_args = (; l, h, w, E, _batchsize, λ1, λ2, σ2inv, α, weight_decays)
    metadata   = (; metadata..., train_args)

    displaymetadata(metadata)

    @time model, ST = train_model(NN, _data; rng,
        _batchsize, batchsize_, weight_decays,
        opts, nepochs, schedules, early_stoppings,
        device, dir, metadata, lossfun,
        cb_epoch,
    )

    displaymetadata(metadata)
    
    plot_training(ST...) |> display

    model, ST, metadata
end

#======================================================#

function infer_SNF(
    model::AbstractNeuralModel,
    data::Tuple, # (X, U, T)
    p0::AbstractVector;
    device = Lux.cpu_device(),
    learn_init::Bool = false,
    verbose::Bool = false,
)
    # make data
    xdata, udata, _ = data

    in_dim, Nx = size(xdata)
    out_dim, Nx, Nt = size(udata)

    model = model |> device # problem here.
    xdata = xdata |> device
    udata = udata |> device
    p = p0 |> device

    # optimizer
    autodiff = AutoForwardDiff()
    linsolve = QRFactorization()
    linesearch = LineSearch() # BackTracking(), HagerZhang(), 
    nlssolve = GaussNewton(;autodiff, linsolve, linesearch)

    codes  = ()
    upreds = ()
    MSEs   = []

    for iter in 1:Nt
        batch = xdata, udata[:, :, iter]

        if learn_init & (iter == 1)
            p, _ = nonlinleastsq(model, p, batch, Optimisers.Descent(1f-3); verbose, maxiters = 100)
            p, _ = nonlinleastsq(model, p, batch, Optimisers.Descent(1f-4); verbose, maxiters = 100)
            p, _ = nonlinleastsq(model, p, batch, Optimisers.Descent(1f-5); verbose, maxiters = 100)
        end

        p, _ = nonlinleastsq(model, p, batch, nlssolve; maxiters = 20, verbose)

        # eval
        upred = model(batch[1], p)
        l = round(mse(upred, batch[2]); sigdigits = 8)

        codes  = push(codes, p)
        upreds = push(upreds, upred)
        push!(MSEs, l)

        if verbose
            println("#=============================#")
            println("Iter $iter, MSE: $l")
            iter += 1
        end
    end

    code = mapreduce(getdata, hcat, codes) |> Lux.cpu_device()
    pred = cat(upreds...; dims = 3)        |> Lux.cpu_device()

    return code, pred, MSEs
end

#======================================================#
function evolve_SNF(
    prob::AbstractPDEProblem,
    datafile::String,
    modelfile::String,
    case::Integer; # batch
    rng::Random.AbstractRNG = Random.default_rng(),

    data_kws = (; Ix = :, It = :),

    Δt::Union{Real, Nothing} = nothing,
    timealg::GeometryLearning.AbstractTimeAlg = EulerForward(),
    adaptive::Bool = false,
    scheme::Union{Nothing, GeometryLearning.AbstractSolveScheme} = nothing,

    autodiff_xyz::ADTypes.AbstractADType = AutoForwardDiff(),
    ϵ_xyz::Union{Real, Nothing} = nothing,

    zeroinit::Bool = false,
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
    md = model["metadata"]
    close(model)

    #==============#
    # subsample in space
    #==============#
    Udata = @view Udata[:, data_kws.Ix, :, data_kws.It]
    Xdata = @view Xdata[:, data_kws.Ix]
    Tdata = @view Tdata[data_kws.It]

    Nx = size(Xdata, 2)
    Nt = size(Udata, 4)

    Ud = Udata[:, :, case, :]
    U0 = Ud[:, :, 1]

    data = (Xdata, U0, Tdata)
    data = copy.(data) # ensure no SubArrays

    #==============#
    # get decoer
    #==============#

    decoder, _code = GeometryLearning.get_autodecoder(NN, p, st)

    #==============#
    # make model
    #==============#

    p0 = _code[2].weight[:, 1]
    NN, p0, st = freeze_autodecoder(decoder, p0; rng)
    model = NeuralEmbeddingModel(NN, st, Xdata, md)

    if zeroinit
        p0 *= 0
        # copy!(p0, randn32(rng, length(p0)))
    end

    #==============#
    # evolve
    #==============#

    ### WORKS
    # # device = Lux.cpu_device()
    # linsolve = QRFactorization()
    # autodiff = AutoForwardDiff()
    # nlssolve = LevenbergMarquardt(;autodiff, linsolve)
    # nlsmaxiters = 20

    # optimizer
    autodiff = AutoForwardDiff()
    linsolve = QRFactorization()
    linesearch = LineSearch()
    nlssolve = GaussNewton(;autodiff, linsolve, linesearch)
    nlsmaxiters = 20

    Δt = isnothing(Δt) ? -(-(extrema(Tdata)...)) / 100.0f0 : Δt

    if isnothing(scheme)
        scheme  = GalerkinProjection(linsolve, 1f-3, 1f-6) # abstol_inf, abstol_mse
        # scheme = LeastSqPetrovGalerkin(nlssolve, nlsmaxiters, 1f-6, 1f-3, 1f-6)
    end

    @time ts, ps, Up = evolve_model(
        prob, model, timealg, scheme, data, p0, Δt;
        nlssolve, nlsmaxiters, adaptive, autodiff_xyz, ϵ_xyz,
        verbose, device,
    )

    #==============#
    # save directory
    #==============#

    modeldir = dirname(modelfile)
    outdir = joinpath(modeldir, "results")
    mkpath(outdir)

    ###
    # visualization
    ###

    linewidth = 2.0
    palette = :tab10

    for od in 1:out_dim
        up = Up[od, :, :]
        ud = Ud[od, :, :]
        nr = sum(abs2, ud) / length(ud)
        er = (up - ud) / nr
        er = sum(abs2, er; dims = 1) / size(ud, 1) |> vec

        if in_dim == 1
            xd = vec(Xdata)

            Ixplt = LinRange(1, Nx, 32) .|> Base.Fix1(round, Int)
            Itplt = LinRange(1, Nt,  4) .|> Base.Fix1(round, Int)

            # u(x, t)
            plt = plot(;
                title = "Ambient space evolution, case = $(case)",
                xlabel = L"x", ylabel = L"u(x,t)", legend = false,
            )
            plot!(plt, xd, up[:, Itplt]; linewidth, palette)
            scatter!(plt, xd[Ixplt], ud[Ixplt, Itplt]; w = 1, palette)
            png(plt, joinpath(outdir, "evolve_u$(od)_case$(case)"))

            # e(t)
            plt = plot(;
                title = "Error evolution, case = $(case)",
                xlabel = L"Time ($s$)", ylabel = L"ε(t)", legend = false,
                yaxis = :log, ylims = (10^-9, 1.0),
            )
            plot!(plt, ts, er; linewidth, palette,)
            png(plt, joinpath(outdir, "evolve_e$(od)_case$(case)"))

        elseif in_dim == 2
        else
            throw(ErrorException("in_dim = $in_dim not supported."))
        end

        ###
        # parameter evolution
        ###
        plt = plot(;
                   title = "Parameter evolution, case $(case)",
                   xlabel = L"Time ($s$)", ylabel = L"\tilde{u}(t)", legend = false
                   )
        plot!(plt, ts, ps'; linewidth, palette)
        png(plt, joinpath(outdir, "evolve_p$(od)_case$(case)"))
    end

    ###
    # parameter scatter plot
    ###

    plt = plot(; title = "Parameter scatter plot, case = $case")

    kw_scatter = (;
        color = :blues,
        zcolor = ts,
        label = nothing,
        markerstrokewidth = 0,
    )

    if size(ps, 1) == 1
        scatter!(plt, vec(ps); kw_scatter...)
    elseif size(ps, 1) == 2
        scatter!(plt, ps[1,:], ps[2,:]; kw_scatter...)
    elseif size(ps, 1) == 3
        scatter!(plt, ps[1,:], ps[2,:], ps[3,:]; kw_scatter...)
    else
        _ps = tsne(ps', 2)'
        scatter!(plt, _ps[1,:], _ps[2,:]; kw_scatter...)
    end

    png(plt, joinpath(outdir, "p_scatter_case$(case)"))

    filename = joinpath(outdir, "evolve$case.jld2")
    jldsave(filename; Xdata, Tdata, Udata = Ud, Upred = Up, Ppred = ps)

    Xdata, Tdata, Ud, Up, ps
end

#===========================================================#
function postprocess_SNF(
    prob::AbstractPDEProblem,
    datafile::String,
    modelfile::String,
    outdir::String;
    rng::Random.AbstractRNG = Random.default_rng(),
    device = Lux.cpu_device(),
    makeplot::Bool = true,
    verbose::Bool = true,
    fps::Int = 300,
)

    #==============#
    # load data
    #==============#
    data  = jldopen(datafile)
    Tdata = data["t"]
    Xdata = data["x"]
    Udata = data["u"]
    mu    = data["mu"]
    md_data = data["metadata"]

    close(data)

    @assert ndims(Udata) ∈ (3,4,)
    @assert Xdata isa AbstractVecOrMat
    Xdata = Xdata isa AbstractVector ? reshape(Xdata, 1, :) : Xdata # (Dim, Npoints)

    if ndims(Udata) == 3 # [Nx, Nb, Nt]
        Udata = reshape(Udata, 1, size(Udata)...)
    end

    in_dim  = size(Xdata, 1)
    out_dim, Nx, Nb, Nt = size(Udata)

    mu = isnothing(mu) ? fill(nothing, Nb) |> Tuple : mu
    mu = isa(mu, AbstractArray) ? vec(mu) : mu

    #==============#
    # load model
    #==============#
    model = jldopen(modelfile)
    NN, p, st = model["model"]
    md = model["metadata"]
    close(model)

    #==============#
    mkpath(outdir)
    #==============#

    #==============#
    # subsample in space
    #==============#
    # Udata = @view Udata[:, md.makedata_kws.Ix, :, :]
    # Xdata = @view Xdata[:, md.makedata_kws.Ix]

    in_dim, Nx = size(Xdata)

    #==============#
    # train/test split
    #==============#
    _Udata = @view Udata[:, :, md.makedata_kws._Ib, md.makedata_kws._It] # un-normalized
    Udata_ = @view Udata[:, :, md.makedata_kws.Ib_, md.makedata_kws.It_]

    #==============#
    # from training data
    #==============#
    _Ib = isa(md.makedata_kws._Ib, Colon) ? (1:size(Udata, 3)) : md.makedata_kws._Ib
    Ib_ = isa(md.makedata_kws.Ib_, Colon) ? (1:size(Udata, 3)) : md.makedata_kws.Ib_

    _It = isa(md.makedata_kws._It, Colon) ? (1:size(Udata, 4)) : md.makedata_kws._It
    It_ = isa(md.makedata_kws.It_, Colon) ? (1:size(Udata, 4)) : md.makedata_kws.It_

    displaymetadata(md)

    _data, _, _ = makedata_SNF(datafile; _Ib = md.makedata_kws._Ib, _It = md.makedata_kws._It)
    _xdata, _Icode = _data[1]
    _xdata = unnormalizedata(_xdata, md.x̄, md.σx)

    model  = NeuralEmbeddingModel(NN, st, md, _Icode)
    _Upred = eval_model(model, (_xdata, _Icode), p; device) |> cpu_device()
    _Upred = reshape(_Upred, out_dim, Nx, length(_Ib), length(_It))

    @show mse(_Upred, _Udata) / mse(_Udata, 0*_Udata)

    if makeplot
        for k in axes(_Ib, 1)

            _mu = mu[_Ib[k]]
            title  = isnothing(_mu) ? "" : "μ = $(round(_mu, digits = 2))"

            Ud = @view _Udata[:, :, k, :]
            Up = @view _Upred[:, :, k, :]

            # time-indices
            idx_data = LinRange(1, size(Ud, 3), 4) .|> Base.Fix1(round, Int)
            idx_pred = LinRange(1, size(Up, 3), 4) .|> Base.Fix1(round, Int)

            for od in 1:out_dim
                upred = Up[od, :, idx_pred]
                udata = Ud[od, :, idx_data]

                if in_dim == 1
                    xlabel = "x"
                    ylabel = "u$(od)(x, t)"

                    xdata = vec(Xdata)
                    Iplot = 1:8:Nx

                    plt = plot(; xlabel, ylabel, legend = false)
                    plot!(plt, xdata, upred, w = 2, palette = :tab10)
                    scatter!(plt, xdata[Iplot], udata[Iplot, :], w = 1, palette = :tab10)
                    png(plt, joinpath(outdir, "train_u$(od)_k$(k)"))

                    It_data = LinRange(1, size(Ud, 2), 100) .|> Base.Fix1(round, Int)
                    It_pred = LinRange(1, size(Up, 2), 100) .|> Base.Fix1(round, Int)

                    # anim = animate1D(Ud[:, It_data], Up[:, It_pred], vec(Xdata), Tdata[It_data];
                    #                  w = 2, xlabel, ylabel, title)
                    # gif(anim, joinpath(outdir, "train$(k).gif"); fps)

                    display(plt)

                elseif in_dim == 2
                    xlabel = "x"
                    ylabel = "y"
                    zlabel = "u$(od)(x, t)"

                    kw = (; xlabel, ylabel, zlabel,)

                    x_re = reshape(Xdata[1, :], md_data.Nx, md_data.Ny)
                    y_re = reshape(Xdata[2, :], md_data.Nx, md_data.Ny)

                    upred_re = reshape(upred, md_data.Nx, md_data.Ny, :)
                    udata_re = reshape(udata, md_data.Nx, md_data.Ny, :)

                    for i in eachindex(idx_pred)
                        up_re = upred_re[:, :, i]
                        ud_re = udata_re[:, :, i]

                        # p1 = plot()
                        # p1 = meshplt(x_re, y_re, up_re; plt = p1, c=:black, w = 1.0, kw...,)
                        # p1 = meshplt(x_re, y_re, up_re - ud_re; plt = p1, c=:red  , w = 0.2, kw...,)
                        #
                        # p2 = meshplt(x_re, y_re, ud_re - up_re; title = "error", kw...,)
                        #
                        # png(p1, joinpath(outdir, "train_u$(od)_$(k)_time_$(i)"))
                        # png(p2, joinpath(outdir, "train_u$(od)_$(k)_time_$(i)_error"))

                        p3 = heatmap(up_re; title = "u$(od)(x, y)")
                        p4 = heatmap(up_re - ud_re; title = "u$(od)(x, y)")

                        png(p3, joinpath(outdir, "train_u$(od)_$(k)_time_$(i)"))
                        png(p4, joinpath(outdir, "train_u$(od)_$(k)_time_$(i)_error"))
                    end

                    # anim = animate2D(udata_re, upred_re, x_re, y_re, Tdata[idx_data])
                    # gif(anim, joinpath(outdir, "train_u$(od)_$(k).gif"); fps)

                end # in_dim
            end # out_dim
        end # k ∈ _Ib
    end # makeplot

    #==============#
    # infer with nonlinear solve
    #==============#

    # # get decoder
    # decoder, _code = GeometryLearning.get_autodecoder(NN, p, st)
    #
    # # make model
    # p0 = _code[2].weight[:, 1]
    # NN, p0, st = freeze_autodecoder(decoder, p0; rng)
    # model = NeuralEmbeddingModel(NN, st, Xdata, md)
    #
    # # make data tuple
    # case = 1
    # Ud = Udata[:, :, case, :]
    # data = (Xdata, Ud, Tdata)
    #
    # learn_init = false
    # learn_init = true
    # ps, Up, Ls = infer_SNF(model, data, p0; device, verbose, learn_init)
    #
    # plt = plot(Xdata[1,:], Ud[1,:,begin], w = 4, c = :black, label = nothing)
    # plot!(plt, Xdata[1,:], Up[1,:,begin], w = 4, c = :red  , label = nothing)
    # plot!(plt, Xdata[1,:], Ud[1,:,end  ], w = 4, c = :black, label = "data")
    # plot!(plt, Xdata[1,:], Up[1,:,end  ], w = 4, c = :red  , label = "pred")
    # display(plt)

    #==============#
    # evolve
    #==============#
    
    # decoder, _code = GeometryLearning.get_autodecoder(NN, p, st)
    # p0 = _code[2].weight[:, 1]
    #
    # for k in axes(mu)[1]
    #     Ud = Udata[:, k, :]
    #     data = (Xdata, Ud, Tdata)
    #     @time _, Up, Tpred = evolve_autodecoder(prob, decoder, md, data, p0;
    #         rng, device, verbose)
    #
    #     if makeplot
    #         if in_dim == 1
    #             xlabel = "x"
    #             ylabel = "u(x, t)"
    #
    #             _mu   = mu[k]
    #             title = isnothing(_mu) ? "" : "μ = $(round(_mu, digits = 2))"
    #             _name = k in _Ib ? "evolve_train$(k)" : "evolve_test$(k)"
    #
    #             plt = plot(; title, xlabel, ylabel, legend = false)
    #             plot!(plt, Xdata, Up[:, idx], w = 2.0,  s = :solid)
    #             plot!(plt, Xdata, Ud[:, idx], w = 4.0,  s = :dash)
    #             png(plt, joinpath(outdir, _name))
    #             display(plt)
    #
    #             anim = animate1D(Ud, Up, Xdata, Tdata;
    #                              w = 2, xlabel, ylabel, title)
    #             gif(anim, joinpath(outdir, "$(_name).gif"); fps)
    #
    #         elseif in_dim == 2
    #             xlabel = "x"
    #             ylabel = "y"
    #             zlabel = "u(x, t)"
    #
    #             kw = (; xlabel, ylabel, zlabel,)
    #
    #             x_re = reshape(Xdata[1, :], md_data.Nx, md_data.Ny)
    #             y_re = reshape(Xdata[2, :], md_data.Nx, md_data.Ny)
    #
    #             for i in eachindex(idx_pred)
    #                 upred_re = reshape(upred[:, i], md_data.Nx, md_data.Ny)
    #                 udata_re = reshape(udata[:, i], md_data.Nx, md_data.Ny)
    #
    #                 p1 = meshplt(x_re, y_re, upred_re;
    #                     title, kw...,)
    #                 png(p1, joinpath(outdir, "train_$(k)_time_$(i)"))
    #
    #                 p2 = meshplt(x_re, y_re, upred_re - udata_re;
    #                     title = "error", kw...,)
    #                 png(p2, joinpath(outdir, "train_$(k)_time_$(i)_error"))
    #             end
    #         end
    #     end
    # end

    #==============#
    # check derivative
    #==============#
    begin
        decoder, _code = GeometryLearning.get_autodecoder(NN, p, st)
        ncodes = size(_code[2].weight, 2)
        idx = LinRange(1, ncodes, 4) .|> Base.Fix1(round, Int)
    
        for i in idx
            p0 = _code[2].weight[:, i]
    
            if in_dim == 1
    
                ###
                # AutoFiniteDiff
                ###
    
                # ϵ  = 1f-2
                #
                # plt = plot_derivatives1D_autodecoder(
                #     decoder, vec(Xdata), p0, md;
                #     second_derv = false, third_derv = false, fourth_derv = false,
                #     autodiff = AutoFiniteDiff(), ϵ,
                # )
                # png(plt, joinpath(outdir, "dudx1_$(i)_FIN_AD"))
                #
                # plt = plot_derivatives1D_autodecoder(
                #     decoder, vec(Xdata), p0, md;
                #     second_derv = true, third_derv = false, fourth_derv = false,
                #     autodiff = AutoFiniteDiff(), ϵ,
                # )
                # png(plt, joinpath(outdir, "dudx2_$(i)_FIN_AD"))
                #
                # plt = plot_derivatives1D_autodecoder(
                #     decoder, vec(Xdata), p0, md;
                #     second_derv = false, third_derv = true, fourth_derv = false,
                #     autodiff = AutoFiniteDiff(), ϵ,
                # )
                # png(plt, joinpath(outdir, "dudx3_$(i)_FIN_AD"))
                #
                # plt = plot_derivatives1D_autodecoder(
                #     decoder, vec(Xdata), p0, md;
                #     second_derv = false, third_derv = false, fourth_derv = true,
                #     autodiff = AutoFiniteDiff(), ϵ,
                # )
                # png(plt, joinpath(outdir, "dudx4_$(i)_FIN_AD"))
    
                ###
                # AutoForwardDiff
                ###
    
                plt = plot_derivatives1D_autodecoder(
                    decoder, vec(Xdata), p0, md;
                    second_derv = false, third_derv = false, fourth_derv = false,
                    autodiff = AutoForwardDiff(),
                )
                png(plt, joinpath(outdir, "dudx1_$(i)_FWD_AD"))
    
                plt = plot_derivatives1D_autodecoder(
                    decoder, vec(Xdata), p0, md;
                    second_derv = true, third_derv = false, fourth_derv = false,
                    autodiff = AutoForwardDiff(),
                )
                png(plt, joinpath(outdir, "dudx2_$(i)_FWD_AD"))
    
                plt = plot_derivatives1D_autodecoder(
                    decoder, vec(Xdata), p0, md;
                    second_derv = false, third_derv = true, fourth_derv = false,
                    autodiff = AutoForwardDiff(),
                )
                png(plt, joinpath(outdir, "dudx3_$(i)_FWD_AD"))
    
                plt = plot_derivatives1D_autodecoder(
                    decoder, vec(Xdata), p0, md;
                    second_derv = false, third_derv = false, fourth_derv = true,
                    autodiff = AutoForwardDiff(),
                )
                png(plt, joinpath(outdir, "dudx4_$(i)_FWD_AD"))
    
            elseif in_dim == 2
    
            end # in-dim
    
        end
    end

    #==============#
    # Done
    #==============#
    if haskey(md, :readme)
        RM = joinpath(outdir, "README.md")
        RM = open(RM, "w")
        write(RM, md.readme)
        close(RM)
    end

    nothing
end

#======================================================#
function displaymetadata(metadata::NamedTuple)
    println("METADATA:")
    println("ū, σu: $(metadata.ū), $(metadata.σu)")
    println("x̄, σx: $(metadata.x̄), $(metadata.σx)")
    println("Model README: ", metadata.readme)
    println("Data-metadata: ", metadata.md_data)
    println("train_args: ", metadata.train_args)
    println("Nx, _Ncodes, Ncodes_: $(metadata.Nx), $(metadata._Ns), $(metadata.Ns_)")
    nothing
end

#===========================================================#
function eval_model(
    model::GeometryLearning.AbstractNeuralModel,
    x::AbstractArray,
    p::AbstractArray;
    batchsize = numobs(x) ÷ 100,
    device = Lux.cpu_device(),
)
    loader = MLUtils.DataLoader(x; batchsize, shuffle = false, partial = true)

    p = p |> device
    model = model |> device

    if device isa Lux.LuxCUDADevice
        loader = CuIterator(loader)
    end

    y = ()
    for batch in loader
        yy = model(batch, p)
        y = (y..., yy)
    end

    hcat(y...)
end

function eval_model(
    model::NeuralEmbeddingModel,
    x::Tuple,
    p::AbstractArray;
    batchsize = numobs(x) ÷ 100,
    device = Lux.cpu_device(),
)
    loader = MLUtils.DataLoader(x; batchsize, shuffle = false, partial = true)

    p = p |> device
    model = model |> device

    if device isa Lux.LuxCUDADevice
        loader = CuIterator(loader)
    end

    y = ()
    for batch in loader
        yy = model(batch[1], p, batch[2])
        yy = reshape(yy, size(yy, 1), :)
        y = (y..., yy)
    end

    hcat(y...)
end

#===========================================================#
function p_axes(NN;
    rng::Random.AbstractRNG = Random.default_rng(),
)
    p = Lux.setup(copy(rng), NN)[1]
    p = ComponentArray(p)
    getaxes(p)
end

function decoder_indices(NN;
    rng::Random.AbstractRNG = Random.default_rng(),
)
    p = Lux.setup(copy(rng), NN)[1]
    p = ComponentArray(p)
    decoder_idx = only(getaxes(p))[:decoder].idx

    println("[decoder_indices]: Passing $(length(decoder_idx)) / $(length(p)) decoder parameters to IdxWeightDecay")

    decoder_idx
end

function decoder_W_indices(NN;
    rng::Random.AbstractRNG = Random.default_rng(),
)
    p = Lux.setup(copy(rng), NN)[1]
    p = ComponentArray(p)

    idx = Int32[]

    for lname in propertynames(p.decoder)
        w = getproperty(p.decoder, lname).weight # reshaped array

        @assert ndims(w) == 2

        i = if w isa Base.ReshapedArray
            only(w.parent.indices)
        elseif w isa SubArray
            w.indices
        end

        println("Grabbing weight indices from decoder layer $lname, size $(size(w))")

        idx = vcat(idx, Int32.(i))
    end

    println("[decoder_W_indices]: Passing $(length(idx)) / $(length(p)) decoder parameters to IdxWeightDecay")

    idx
end

#===========================================================#
#