#
"""
Train an autoencoder on 1D advection data
"""

using GeometryLearning

include(joinpath(pkgdir(GeometryLearning), "examples", "autodecoder.jl"))

#======================================================#
function test_autodecoder(
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
    data = jldopen(datafile)
    Tdata = data["t"]
    Xdata = data["x"]
    Udata = data["u"]
    mu = data["mu"]

    close(data)

    # data sizes
    Nx, Nb, Nt = size(Udata)

    mu = isnothing(mu) ? fill(nothing, Nb) |> Tuple : mu
    mu = isa(mu, AbstractArray) ? vec(mu) : mu

    # subsample in space
    Ix = 1:8:Nx
    Udata = @view Udata[Ix, :, :]
    Xdata = @view Xdata[Ix]
    Nx = length(Xdata)

    #==============#
    # load model
    #==============#
    model = jldopen(modelfile)
    NN, p, st = model["model"]
    md = model["metadata"] # (; ū, σu, _Ib, Ib_, _It, It_, readme)
    close(model)

    # TODO - rm after retraining this model
    @set! md.σx = sqrt(md.σx)
    @set! md.σu = sqrt(md.σu)

    #==============#
    # make outdir path
    #==============#
    mkpath(outdir)

    k = 1# 1, 7
    It = LinRange(1,length(Tdata), 10) .|> Base.Fix1(round, Int)

    Ud = Udata[:, k, It]
    U0 = Ud[:, 1]
    data = (reshape(Xdata, 1, :), reshape(U0, 1, :), Tdata[It])

    decoder, _code = GeometryLearning.get_autodecoder(NN, p, st)
    p0 = _code[2].weight[:, 1]

    CUDA.@time _, _, Up = evolve_autodecoder(prob, decoder, md, data, p0;
        rng, device, verbose)

    Ix = 1:32:Nx
    plt = plot(xlabel = "x", ylabel = "u(x, t)", legend = false)
    plot!(plt, Xdata, Up, w = 2, palette = :tab10)
    scatter!(plt, Xdata[Ix], Ud[Ix, :], w = 1, palette = :tab10)

    _inf  = norm(Up - Ud, Inf)
    _mse  = sum(abs2, Up - Ud) / length(Ud)
    _rmse = sum(abs2, Up - Ud) / sum(abs2, Ud) |> sqrt
    println("||∞ : $(_inf)")
    println("MSE : $(_mse)")
    println("RMSE: $(_rmse)")

    png(plt, joinpath(outdir, "evolve_$k"))
    display(plt)

    nothing
end
#======================================================#
# main
#======================================================#

rng = Random.default_rng()
Random.seed!(rng, 460)

prob = Advection1D(0.25f0)

device = Lux.gpu_device()
datafile = joinpath(@__DIR__, "data_advect/", "data.jld2")

modeldir = joinpath(@__DIR__, "model4")
modelfile = joinpath(modeldir, "model_08.jld2")

# E = 1000
# l, h, w = 4, 5, 32
# isdir(modeldir) && rm(modeldir, recursive = true)
# model, STATS = train_autodecoder(datafile, modeldir, l, h, w, E; λ = 5f-1,
#     _batchsize = nothing, batchsize_ = nothing, device)

outdir = joinpath(dirname(modelfile), "results")
postprocess_autodecoder(prob, datafile, modelfile, outdir; rng, device,
    makeplot = true, verbose = true)
# test_autodecoder(datafile, modelfile, outdir; rng, device,
#     makeplot = true, verbose = true)
#======================================================#
nothing
#
