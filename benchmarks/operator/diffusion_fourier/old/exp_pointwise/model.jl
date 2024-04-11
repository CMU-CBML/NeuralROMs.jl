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
using FourierSpaces, LinearAlgebra

# ML stack
using Lux, Random, Optimisers

# vis/analysis, serialization
using Plots, BSON

""" data """
function datagen(rng, N, K1, K2)

    V = FourierSpace(N; domain = IntervalDomain(0, 2pi))
    x = points(V)[1]
    discr = Collocation()

    ν = 1 .+  1 * rand(Float32, N, K1)
    f = 0 .+ 20 * rand(Float32, N, K2)

    ν = kron(ones(K2)', ν)
    f = kron(f, ones(K1)')
    x = kron(x, ones(K1 * K2)')

    @assert size(f) == size(ν)

    V = make_transform(V, f)
    F = transformOp(V)

    # rm high freq modes
    Tr = truncationOp(V, (0.5,))
    ν  = Tr * ν
    f  = Tr * f

    # true sol
    A = diffusionOp(ν, V, discr)
    u = A \ f

    d0 = zeros(Float32, (3, N, K1 * K2))
    d0[1, :, :] = ν
    d0[2, :, :] = f
    d0[3, :, :] = x
    d1 = reshape(u, (1, N, K1 * K2))

    data = (d0, d1)

    V, data
end

""" main program """

# parameters
N  = 128    # problem size
K1 = 50     # X-samples
K2 = 50     # X-samples
E  = 100  # epochs

rng = Random.default_rng()
Random.seed!(rng, 917)

# datagen
_V, _data = datagen(rng, N, K1, K2) # train
V_, data_ = datagen(rng, N, K1, K2) # test

# model
w = 64
c = size(_data[1], 1)
o = size(_data[2], 1)

NN = Lux.Chain(
    # BatchNorm(c), # assumes channels (ndims(x)-1)th dim, not first.
    Lux.Dense(c , w, tanh),
    Lux.Dense(w , w, tanh),
    Lux.Dense(w , w, tanh) |> Base.Fix2(SkipConnection, +),
    Lux.Dense(w , w, tanh) |> Base.Fix2(SkipConnection, +),
    Lux.Dense(w , w, tanh) |> Base.Fix2(SkipConnection, +),
    Lux.Dense(w , w, tanh) |> Base.Fix2(SkipConnection, +),
    Lux.Dense(w , w, tanh) |> Base.Fix2(SkipConnection, +),
    Lux.Dense(w , w, tanh) |> Base.Fix2(SkipConnection, +),
    Lux.Dense(w , o),
)

opt = Optimisers.Adam()
learning_rates = (1f-6, 1f-4, 1f-4, 1f-5, 1f-6,)
maxiters  = E .* (0.05, 0.05, 0.10, 0.50, 0.30,) .|> Int

dir = @__DIR__

p, st, STATS = train_model(rng, NN, _data, data_, _V, opt;
                           learning_rates, maxiters, dir, cbstep = 1)

nothing
#