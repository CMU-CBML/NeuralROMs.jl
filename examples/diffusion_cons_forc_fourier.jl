#
"""
Geometry learning sandbox

Want to solve `A(x) * u = M(x) * f` for varying `x` by
learning the mapping `x -> (A^{-1} M)(x)`.

# Reference
* https://slides.com/vedantpuri/project-discussion-2023-05-10
"""

using GeometryLearning, FourierSpaces, NNlib
using SciMLOperators, LinearAlgebra, Random
using Zygote, Lux, ComponentArrays, Optimisers

using Plots

# using Flux, NeuralOperators

""" data """
function datagen(rng, V, discr, K, f = nothing)

    N = size(V, 1)

    # constant forcing
    f = isnothing(f) ? ones(Float32, N) : f
    f = kron(f, ones(K)')

    ν = 1 .+ rand(rng, Float32, N, K)

    @assert size(f) == size(ν)

    V = make_transform(V, ν)
    F = transformOp(V)

    # rm high freq
    Tr = truncationOp(V, (0.5,))
    ν  = Tr * ν
    f  = Tr * f

    # true sol
    A = diffusionOp(ν, V, discr)
    u = A \ f
    u = u .+ 1.0

    V, ν, u
end

""" model """
function model_setup() # input

    function model(p, ν)
        NN(ν, p, st)[1]
    end

    function loss(p, ν, utrue)
        upred = model(p, ν)

        norm(upred - utrue, 2)
    end

    function errors(p, ν, utrue)
        upred = model(p, ν)
        udiff = upred - utrue

        meanAE = norm(udiff, 1) / length(utrue)
        maxAE  = norm(udiff, Inf)

        urel   = udiff ./ utrue
        meanRE = norm(urel, 1) / length(utrue)
        maxRE  = norm(urel, Inf)

        meanAE, maxAE, meanRE, maxRE
    end

    model, loss, errors
end

function callback(iter, E, p, loss, errors)

    a = iszero(E) ? 1 : round(0.1 * E) |> Int
    if iter % a == 0 || iter == 1 || iter == E

        if !isnothing(errors)
            err = errors(p)

            str  = string("Iter $iter: LOSS: ", round(loss(p), digits=8))
            str *= string(", meanAE: ", round(err[1], digits=8))
            str *= string(", maxAE: " , round(err[2] , digits=8))
            str *= string(", meanRE: ", round(err[3], digits=8))
            str *= string(", maxRE: " , round(err[4] , digits=8))
        end

        println(str)
    end

    nothing
end

""" training """
function train(loss, p; opt = Optimisers.Adam(), E = 5000, cb = nothing)

    # dry run
    l, pb = Zygote.pullback(loss, p)
    gr = pb(one.(l))[1]

    println("Loss with initial parameter set: ", l)

    # init optimizer
    opt_st = Optimisers.setup(opt, p)

    for iter in 1:E
        l, pb = Zygote.pullback(loss, p)
        gr = pb(one.(l))[1]

        opt_st, p = Optimisers.update(opt_st, p, gr)

        !isnothing(cb) && cb(iter, E, p)
    end

    p
end

""" visualize """
function visualize(V, _u, u_, model; I = 5)
    x, = points(V)

    I = min(I, size(_u, 2))

    _plt = plot(title = "Training", legend = false)
    _u = _u[:, 1:I]
    plot!(_plt, x, _u, style = :dash, width = 2.0)
    plot!(_plt, x, model(_u), style = :solid, width = 2.0)

    plt_ = plot(title = "Testing", legend = false)
    u_ = u_[:, 1:I]
    plot!(plt_, x, u_, style = :dash, width = 2.0)
    plot!(plt_, x, model(u_), style = :solid, width = 2.0)

    _plt, plt_
end

""" main program """

# parameters
N = 128    # problem size
K = 100    # X-samples
E = 5000  # epochs

rng = Random.default_rng()
Random.seed!(rng, 0)

# space discr
V = FourierSpace(N; domain = IntervalDomain(0, 2pi))
discr = Collocation()

# datagen
f = 1 .+ rand(Float32, N)
_V, _ν, _u = datagen(rng, V, discr, K, f) # train
V_, ν_, u_ = datagen(rng, V, discr, K, f) # test

# model setup
NN = Lux.Chain(
    Lux.Dense(N , N, tanh),
    Lux.Dense(N , N, tanh),
    Lux.Dense(N , N, tanh),
    Lux.Dense(N , N),
)

p, st = Lux.setup(rng, NN)
p = p |> ComponentArray

model, loss, errors = model_setup()

# train setup
_errors = (p,) -> errors(p, _ν, _u)
_loss   = (p,) -> loss(p, _ν, _u)
_cb  = (i, E, p,) -> callback(i, E, p, _loss, _errors)

# test setup
errors_ = (p,) -> errors(p, ν_, u_)
loss_   = (p,) -> loss(p, ν_, u_)
cb_  = (i, E, p,) -> callback(i, E, p, loss_, errors_)

# test stats
println("### Test stats ###")
cb_(0, 0, p)

# training loop
@time p = train(_loss, p; opt = Optimisers.Adam(1f-2), E = Int(E*0.05), cb = _cb)
@time p = train(_loss, p; opt = Optimisers.Adam(1f-3), E = Int(E*0.70), cb = _cb)
@time p = train(_loss, p; opt = Optimisers.Adam(1f-4), E = Int(E*0.25), cb = _cb)

# test stats
println("### Test stats ###")
cb_(0, 0, p)

# visualization
_plt, plt_ = visualize(V, _u, u_, x -> model(p, x))
#
