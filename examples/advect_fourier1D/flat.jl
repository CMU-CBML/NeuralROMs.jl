#
using GeometryLearning
include(joinpath(pkgdir(GeometryLearning), "examples", "smoothNF.jl"))
include(joinpath(pkgdir(GeometryLearning), "examples", "problems.jl"))
#======================================================#

rng = Random.default_rng()
Random.seed!(rng, 199)

prob = Advection1D(0.25f0)
datafile  = joinpath(@__DIR__, "data_advect/", "data.jld2")
modeldir  = joinpath(@__DIR__, "dump")
modelfile = joinpath(modeldir, "model_08.jld2")
device = Lux.gpu_device()

## train
E = 1400
l = 2
hh, wh = 0, 8
hd, wd = 5, 64
λ2, α, weight_decays = 1f-3, 0f0, 1f-2

isdir(modeldir) && rm(modeldir, recursive = true)
model, STATS, metadata = train_FNF(datafile, modeldir,
    l, hh, hd, wh, wd, E;
    rng, warmup = true, λ2, α, weight_decays, device,
)

## process
postprocess_FNF(prob, datafile, modelfile; rng, device)
#======================================================#
nothing