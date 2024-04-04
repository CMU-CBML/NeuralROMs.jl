#
using GeometryLearning
using Plots, LaTeXStrings

joinpath(pkgdir(GeometryLearning), "examples", "compare.jl") |> include
#======================================================#

rng = Random.default_rng()
Random.seed!(rng, 199)

prob = BurgersViscous1D(1f-4)
datafile = joinpath(@__DIR__, "data_burg1D", "data.jld2")
device = Lux.gpu_device()

_Ib, Ib_ = [1, 3, 5,], [2, 4]
Ix  = Colon()
_It = Colon()
makedata_kws = (; Ix, _Ib, Ib_, _It, It_ = :)

# latent 
latent = 2
l_pca  = 8

#==================#
# train
#==================#

l0 = lpad(latent, 2, "0")
lp = lpad(l_pca , 2, "0")

modeldir_PCA = joinpath(@__DIR__, "model_PCA$(lp)") # traditional
modeldir_CAE = joinpath(@__DIR__, "model_CAE$(l0)") # Lee, Carlberg
modeldir_SNW = joinpath(@__DIR__, "model_SNW$(l0)") # us (Weight decay)
modeldir_SNL = joinpath(@__DIR__, "model_SNL$(l0)") # us (Lipschitz)

# # train PCA
# train_PCA(datafile, modeldir_PCA, l_pca; rng, makedata_kws, device)
#
# # train_CAE
# train_params_CAE = (; E = 1400, w = 64, makedata_kws,)
# train_CAE_compare(prob, latent, datafile, modeldir_CAE, train_params_CAE; rng, device)
#
# # train_SNW
# train_params_SNW = (; E = 1400, wd = 128, α = 0f-0, γ = 1f-2, makedata_kws)#, batchsize_)
# train_SNF_compare(latent, datafile, modeldir_SNW, train_params_SNW; rng, device)
#
# # train_SNL
# train_params_SNL = (; E = 1400, wd = 128, α = 1f-4, γ = 0f-0, makedata_kws)#, batchsize_)
# train_SNF_compare(latent, datafile, modeldir_SNL, train_params_SNL; rng, device)

#==================#
# postprocess
#==================#

modelfile_PCA = joinpath(modeldir_PCA, "model.jld2")
modelfile_CAE = joinpath(modeldir_CAE, "model_07.jld2")
modelfile_SNW = joinpath(modeldir_SNW, "model_08.jld2")
modelfile_SNL = joinpath(modeldir_SNL, "model_08.jld2")

# postprocess_PCA(prob, datafile, modelfile_PCA; rng, device)
# postprocess_CAE(prob, datafile, modelfile_CAE; rng)
# postprocess_SNF(prob, datafile, modelfile_SNW; rng, device)
# postprocess_SNF(prob, datafile, modelfile_SNL; rng, device)

#==================#
# make figures
#==================#

grid = (1024,)
casename = "burgers1d"
modeldirs = (; modeldir_PCA, modeldir_CAE, modeldir_SNL, modeldir_SNW,)
label = ("POD ($(l_pca) modes)", "CAE", "SNFL (ours)", "SNFW (ours)")

_, p1, e1 = compare_plots(modeldirs, label, @__DIR__, casename * "case1", 1, grid)
_, p2, e2 = compare_plots(modeldirs, label, @__DIR__, casename * "case2", 2, grid)
_, p3, e3 = compare_plots(modeldirs, label, @__DIR__, casename * "case3", 3, grid)
_, p4, e4 = compare_plots(modeldirs, label, @__DIR__, casename * "case4", 4, grid)
_, p5, e5 = compare_plots(modeldirs, label, @__DIR__, casename * "case5", 5, grid)
_, p6, e6 = compare_plots(modeldirs, label, @__DIR__, casename * "case6", 6, grid)

#======================================================#
nothing
