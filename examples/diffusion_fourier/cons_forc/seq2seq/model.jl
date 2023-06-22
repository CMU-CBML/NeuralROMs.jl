#
"""
Learn solution to diffusion equation

    -∇⋅ν∇ u = f₀

for variable ν, and constant f₀

test bed for Fourier Neural Operator experiments where
forcing is learned separately.
"""

using GeometryLearning

# PDE stack
using FourierSpaces, LinearAlgebra # PDE

# ML stack
using Zygote, Lux, Random, ComponentArrays, Optimisers

# vis
using Plots, BSON

""" data """
function datagen(rng, V, K, f0 = nothing, discr = Collocation())

    N = size(V, 1)

    # constant forcing
    f0 = isnothing(f0) ? ones(Float32, N) : f0
    f0 = kron(f0, ones(K)')

    ν = 1 .+ 1 * rand(rng, Float32, N, K)

    @assert size(f0) == size(ν)

    V = make_transform(V, ν)
    F = transformOp(V)

    # rm high freq modes
    Tr = truncationOp(V, (0.5,))
    ν  = Tr * ν
    f0  = Tr * f0

    # true sol
    A = diffusionOp(ν, V, discr)
    u = A \ f0
    u = u

    V, (ν, u)
end

""" main program """

# parameters
N = 128    # problem size
K = 100    # X-samples
E = 200  # epochs

rng = Random.default_rng()
Random.seed!(rng, 917)

# datagen
V = FourierSpace(N; domain = IntervalDomain(0, 2pi))
discr = Collocation()

f0 = 20 * rand(Float32, N)
_V, _data = datagen(rng, V, K, f0) # train
V_, data_ = datagen(rng, V, K, f0) # test

# model
NN = Lux.Chain(
    Lux.Dense(N , N, tanh),
    Lux.Dense(N , N, tanh),
    Lux.Dense(N , N, tanh),
    Lux.Dense(N , N),
)

opts = Optimisers.Adam.((1f-5, 1f-2, 1f-3, 1f-4,))
maxiters  = E .* (0.05, 0.05, 0.70, 0.20) .|> Int
dir = @__DIR__

p, st, _STATS = train_model(rng, NN, _data, data_, V; opts, maxiters, dir)

nothing
#