#
"""
Learn solution to diffusion equation

    -∇⋅ν₀∇ u = f

for constant ν₀, and variable f

test bed for Fourier Neural Operator experiments where
forcing is learned separately.
"""

using GeometryLearning

# PDE stack
using FourierSpaces, LinearAlgebra # PDE

# ML stack
using Lux, Random, ComponentArrays, Optimisers

# vis/analysis, serialization
using Plots, BSON

""" data """
function datagen(rng, V, K, ν0 = nothing, discr = Collocation())

    N = size(V, 1)

    # constant viscosity
    ν0 = isnothing(ν0) ? ones(Float32, N) : ν0
    ν0 = kron(ν0, ones(K)')

    x, = points(V)
    x = kron(x, ones(K)')

    f = 20 * rand(rng, Float32, N, K)

    @assert size(f) == size(ν0)

    V = make_transform(V, f)
    F = transformOp(V)

    # rm high freq modes
    Tr = truncationOp(V, (0.5,))
    ν0 = Tr * ν0
    f  = Tr * f

    # true sol
    A = diffusionOp(ν0, V, discr)
    u = A \ f

    d0 = zeros(Float32, (2, N, K))
    d0[1, :, :] = f
    d0[2, :, :] = x
    d1 = reshape(u, (1, N, K))

    data = (d0, d1)

    V, data
end

""" main program """

# parameters
N = 128    # problem size
K = 100    # X-samples
E = 2000  # epochs

rng = Random.default_rng()
Random.seed!(rng, 917)

# datagen
V = FourierSpace(N; domain = IntervalDomain(0, 2pi))
discr = Collocation()

ν0 = 1 .+ 1 * rand(Float32, N)
_V, _data = datagen(rng, V, K, ν0) # train
V_, data_ = datagen(rng, V, K, ν0) # test

# model
w = 2     # width
m = (32,) # modes
c = size(_data[1], 1) # in  channels
o = size(_data[2], 1) # out channels

# linear

# NN = Lux.Chain(
#
#     # lifting
#     Lux.Dense(c , w),
#
#     # operator layer
#     OpKernel(w, w, m),
#
#     # projection
#     # Lux.Dense(w , w),
#     Lux.Dense(w , o),
# )

# NN = OpKernel(c, o, m)
NN = OpConv(c, o, m)

opts = Optimisers.Adam.((1f-5, 1f-1, 1f-2, 1f-3,))
maxiters  = E .* (0.05, 0.05, 0.70, 0.20) .|> Int
dir = @__DIR__

p, st, _STATS = train_model(rng, NN, _data, data_, V; opts, maxiters, dir, cbstep = 50)

nothing
#
