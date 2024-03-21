#
using GeometryLearning
using LinearAlgebra, ComponentArrays              # arrays
using Random, Lux, MLUtils, ParameterSchedulers   # ML
using OptimizationOptimJL, OptimizationOptimisers # opt
using LinearSolve, NonlinearSolve, LineSearches   # num
using Plots, JLD2                                 # vis / save
using CUDA, LuxCUDA, KernelAbstractions           # GPU
using LaTeXStrings

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
function makedata_FNF(
    datafile::String;
    Ix = Colon(), # subsample in space
    _Ib = Colon(), # train/test split in batches
    Ib_ = Colon(),
    _It = Colon(), # train/test split in time
    It_ = Colon(),
)
    # load data
    x, t, mu, u, md_data = loaddata(datafile)

    # normalize
    x, x̄, σx = normalize_x(x)
    u, ū, σu = normalize_u(u)
    t, t̄, σt = normalize_t(t)

    # subsample, test/train split
    _x = @view x[:, Ix]
    x_ = @view x[:, Ix]

    _u = @view u[:, Ix, _Ib, _It]
    u_ = @view u[:, Ix, Ib_, It_]

    Nx = size(_x, 2)
    @assert size(_u, 2) == size(_x, 2)

    println("Using $Nx sample points per trajectory.")

    # get dimensions
    in_dim  = size(x, 1)
    out_dim = size(u, 1)
    prm_dim = 1

    if !isnothing(mu[1])
        prm_dim += length(mu[1])
    end

    # make arrays

    _u = reshape(_u, out_dim, Nx, :)
    u_ = reshape(u_, out_dim, Nx, :)

    _Ns = size(_u, 3) # number of codes i.e. # trajectories
    Ns_ = size(u_, 3)

    println("$_Ns / $Ns_ trajectories in train/test sets.")

    # space
    _xyz = zeros(Float32, in_dim, Nx, _Ns)
    xyz_ = zeros(Float32, in_dim, Nx, Ns_)

    _xyz[:, :, :] .= _x
    xyz_[:, :, :] .= x_

    # parameters
    _prm = zeros(Float32, prm_dim, Nx, _Ns)
    prm_ = zeros(Float32, prm_dim, Nx, Ns_)

    _prm[1, :, :] .= vec(t) |> adjoint
    prm_[1, :, :] .= vec(t) |> adjoint

    if !isnothing(mu[1])
        error("TODO FlatNF: varying mu")
        # prm_dim[2:prm_dim, :, :] .= mu
    end

    # solution
    _y = reshape(_u, out_dim, :)
    y_ = reshape(u_, out_dim, :)

    _x = (reshape(_xyz, in_dim, :), reshape(_prm, prm_dim, :))
    x_ = (reshape(xyz_, in_dim, :), reshape(prm_, prm_dim, :))

    readme = ""

    makedata_kws = (; Ix, _Ib, Ib_, _It, It_)

    metadata = (; ū, σu, x̄, σx, t̄, σt,
        Nx, _Ns, Ns_,
        makedata_kws, md_data, readme,
    )

    (_x, _y), (x_, y_), metadata
end

#===========================================================#

function train_FNF(
    datafile::String,
    modeldir::String,
    l::Int, # latent space size
    hh::Int, # num hidden layers
    hd::Int, # num hidden layers
    wh::Int, # hidden layer width
    wd::Int, # hidden layer width
    E::Int; # num epochs
    rng::Random.AbstractRNG = Random.default_rng(),
    warmup::Bool = true,
    _batchsize = nothing,
    batchsize_ = nothing,
    λ2::Real = 0f0,
    σ2inv::Real = 0f0,
    α::Real = 0f0,
    weight_decays::Union{Real, NTuple{M, <:Real}} = 0f0,
    makedata_kws = (; Ix = :, _Ib = :, Ib_ = :, _It = :, It_ = :,),
    cb_epoch = nothing,
    device = Lux.cpu_device(),
) where{M}

    _data, data_, metadata = makedata_FNF(datafile; makedata_kws...)
    dir = modeldir

    in_dim  = size(_data[1][1], 1)
    prm_dim = size(_data[1][2], 1)
    out_dim = size(_data[2], 1)

    #--------------------------------------------#
    # architecture
    #--------------------------------------------#

    println("input size: $in_dim")
    println("param size: $prm_dim")
    println("output size: $out_dim")

    hyper = begin
        wi = prm_dim
        wo = l

        act = tanh
        in_layer = Dense(wi, wh, act)
        hd_layer = Dense(wh, wh, act)
        fn_layer = Dense(wh, wo; use_bias = false)

        Chain(in_layer, fill(hd_layer, hh)..., fn_layer)
    end

    decoder = begin
        init_wt_in = scaled_siren_init(1f1)
        init_wt_hd = scaled_siren_init(1f0)
        init_wt_fn = glorot_uniform

        init_bias = rand32 # zeros32
        use_bias_fn = false

        act = sin

        wi = l + in_dim
        wo = out_dim

        in_layer = Dense(wi, wd, act; init_weight = init_wt_in, init_bias)
        hd_layer = Dense(wd, wd, act; init_weight = init_wt_hd, init_bias)
        fn_layer = Dense(wd, wo     ; init_weight = init_wt_fn, init_bias, use_bias = use_bias_fn)

        Chain(in_layer, fill(hd_layer, hd)..., fn_layer)
    end

    #----------------------#---------------------#
    # training hyper-params
    #----------------------#---------------------#

    NN = FlatDecoder(hyper, decoder)

    _batchsize = isnothing(_batchsize) ? numobs(_data) ÷ 100 : _batchsize
    batchsize_ = isnothing(batchsize_) ? numobs(_data) ÷ 1   : batchsize_

    lossfun = GeometryLearning.regularize_flatdecoder(mse; α, λ2)

    idx = ps_W_indices(NN, :decoder; rng)
    weightdecay = IdxWeightDecay(0f0, idx)
    opts, nepochs, schedules, early_stoppings = make_optimizer(E, warmup, weightdecay)

    #----------------------#----------------------#

    train_args = (; l, hh, hd, wh, wd, E, _batchsize, λ2, σ2inv, α, weight_decays)
    metadata   = (; metadata..., train_args)

    displaymetadata(metadata)
    display(NN)

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
function evolve_FNF(
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
    learn_ic::Bool = false,
    verbose::Bool = true,
    device = Lux.cpu_device(),
)
    # load data
    Xdata, Tdata, mu, Udata, md_data = loaddata(datafile)

    # load model
    (NN, p, st), md = loadmodel(modelfile)

    #==============#
    # subsample in space
    #==============#
    Udata = @view Udata[:, data_kws.Ix, :, data_kws.It]
    Xdata = @view Xdata[:, data_kws.Ix]
    Tdata = @view Tdata[data_kws.It]

    Ud = Udata[:, :, case, :]
    U0 = Ud[:, :, 1]

    data = (Xdata, U0, Tdata)
    data = copy.(data) # ensure no SubArrays

    #==============#
    # get decoer
    #==============#
    hyper, decoder = get_flatdecoder(NN, p, st)

    # get codes
    codes = jldopen(joinpath(dirname(modelfile), "train_codes.jld2"))
    _code = codes["_code"]

    #==============#
    # make model
    #==============#
    p0 = _code[:, 1]
    NN, p0, st = freeze_decoder(decoder, length(p0); rng, p0)
    model = NeuralModel(NN, st, md)

    #==============#
    # evolve
    #==============#

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
        learn_ic,
        verbose, device,
    )

    #==============#
    # visualization
    #==============#

    modeldir = dirname(modelfile)
    outdir = joinpath(modeldir, "results")
    mkpath(outdir)

    # field visualizations
    grid = get_prob_grid(prob)
    fieldplot(Xdata, Tdata, Ud, Up, grid, outdir, "evolve", case)

    # parameter plots
    _ps = _code
    _ps = reshape(_ps, size(_ps, 1), :)
    paramplot(Tdata, _ps, ps, outdir, "evolve", case)

    # save files
    filename = joinpath(outdir, "evolve$case.jld2")
    jldsave(filename; Xdata, Tdata, Udata = Ud, Upred = Up, Ppred = ps)

    Xdata, Tdata, Ud, Up, ps
end
#===========================================================#
function postprocess_FNF(
    prob::AbstractPDEProblem,
    datafile::String,
    modelfile::String;
    rng::Random.AbstractRNG = Random.default_rng(),
    makeplot::Bool = true,
    verbose::Bool = true,
    fps::Int = 300,
    device = Lux.cpu_device(),
)
    # load data
    Xdata, Tdata, mu, Udata, md_data = loaddata(datafile)

    # load model
    model, md = loadmodel(modelfile)

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

    #==============#
    # Get model
    #==============#
    hyper, decoder = get_flatdecoder(model...)
    model = NeuralModel(decoder[1], decoder[3], md)

    #==============#
    # evaluate model
    #==============#
    _data, data_, _ = makedata_FNF(datafile; _Ib = md.makedata_kws._Ib, _It = md.makedata_kws._It)

    in_dim  = size(Xdata, 1)
    out_dim, Nx, Nb, Nt = size(Udata)

    _code = hyper[1](_data[1][2], hyper[2], hyper[3])[1]
    code_ = hyper[1](data_[1][2], hyper[2], hyper[3])[1]

    _xc = vcat(_data[1][1], _code)
    xc_ = vcat(data_[1][1], code_)

    _upred = decoder[1](_xc, decoder[2], decoder[3])[1]
    upred_ = decoder[1](xc_, decoder[2], decoder[3])[1]

    _upred = reshape(_upred, out_dim, Nx, length(_Ib), length(_It))
    upred_ = reshape(upred_, out_dim, Nx, length(Ib_), length(It_))

    _Upred = unnormalizedata(_upred, md.ū, md.σu)
    Upred_ = unnormalizedata(upred_, md.ū, md.σu)

    @show mse(_Upred, _Udata) / mse(_Udata, 0 * _Udata)
    @show mse(Upred_, Udata_) / mse(Udata_, 0 * Udata_)

    #==============#
    # save codes
    #==============#
    code_len = size(_code, 1)

    _code = reshape(_code, code_len, Nx, Nt)
    code_ = reshape(code_, code_len, Nx, Nt)

    _code = _code[:, 1, :]
    code_ = code_[:, 1, :]

    modeldir = dirname(modelfile)
    jldsave(joinpath(modeldir, "train_codes.jld2"); _code, code_)

    if makeplot
        modeldir = dirname(modelfile)
        outdir = joinpath(modeldir, "results")
        mkpath(outdir)

        grid = get_prob_grid(prob)

        # field plots
        for case in axes(_Ib, 1)
            Ud = _Udata[:, :, case, :]
            Up = _Upred[:, :, case, :]
            fieldplot(Xdata, Tdata, Ud, Up, grid, outdir, "train", case)
        end

        # parameter plots
        _ps = _code # [code_len, _Nb * Nt]
        _ps = reshape(_ps, size(_ps, 1), length(_Ib), length(_It))

        linewidth = 2.0
        palette = :tab10
        colors = (:reds, :greens, :blues,)
        shapes = (:circle, :square, :star,)

        plt = plot(; title = "Parameter scatter plot")

        for case in axes(_Ib, 1)
            _p = _ps[:, case, :]
            plt = make_param_scatterplot(_p, Tdata; plt,
                label = "Case $(case)", color = colors[case])

            # parameter evolution plot
            p2 = plot(;
                title = "Learned parameter evolution, case $(case)",
                xlabel = L"Time ($s$)", ylabel = L"\tilde{u}(t)", legend = false
            )
            plot!(p2, Tdata, _p'; linewidth, palette)
            png(p2, joinpath(outdir, "train_p_case$(case)"))
        end

        for case in axes(Ib_, 1)
            if case ∉ _Ib
                _p = _ps[:, case, :]
                plt = make_param_scatterplot(_p, Tdata; plt,
                    label = "Case $(case) (Testing)", color = colors[case], shape = :star)

                # parameter evolution plot
                p2 = plot(;
                    title = "Trained parameter evolution, case $(case)",
                    xlabel = L"Time ($s$)", ylabel = L"\tilde{u}(t)", legend = false
                )
                plot!(p2, Tdata, _p'; linewidth, palette)
                png(p2, joinpath(outdir, "test_p_case$(case)"))
            end
        end

        png(plt, joinpath(outdir, "train_p_scatter"))

    end # makeplot

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
#===========================================================#
#===========================================================#
#
