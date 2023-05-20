module PPO

using CommonRLInterface, Flux, ProgressMeter, Parameters
using CommonRLInterface.Wrappers: QuickWrapper
using Random: default_rng, seed!, randperm
using Statistics: mean, std
using ChainRules: ignore_derivatives, @ignore_derivatives
using CommonRLSpaces

using RLEnvTools

include("ActorCritics.jl")
using .ActorCritics: ActorCritic, DiscreteActorCritic, get_actionvalue, ContinuousActorCritic

export 
    solve,
    PPOSolver,
    ActorCritic

struct Buffer{Ts<:AbstractArray,Ta<:AbstractArray,Tr<:AbstractArray,Td<:AbstractArray{Bool}}
    s::Ts
    a::Ta
    a_logprob::Tr
    r::Tr
    done::Td
    value::Tr
    advantages::Tr
    returns::Tr
end

Flux.@functor Buffer

function Buffer(env, traj_len)
    na = length(rand(actions(env)))
    a_type = SpaceStyle(actions(env)) isa FiniteSpaceStyle ? Int64 : Float32
    n_envs = length(terminated(env))
    s_size = size(first(observe(env)))

    return Buffer(
        zeros(Float32, s_size..., n_envs, traj_len),
        zeros(a_type, na, n_envs, traj_len),
        zeros(Float32, n_envs, traj_len),
        zeros(Float32, n_envs, traj_len),
        zeros(Bool, n_envs, traj_len),
        zeros(Float32, n_envs, traj_len),
        zeros(Float32, n_envs, traj_len),
        zeros(Float32, n_envs, traj_len)
    )
end

flatten(b::Buffer, N) = fmap(x->reshape(x, size(x)[1:end-N]..., :), b)

function Base.copyto!(dst::Buffer, src::Buffer, idxs::Vector{Int64})
    copyfun(b1, b2) = copyto!(b1, selectdim(b2, ndims(b2), idxs))
    fmap(copyfun, dst, src)
end

function send_to!(buffer::Buffer, idx; kwargs...)
    for (key, val) in kwargs
        arr = getfield(buffer, key)
        arr_view = selectdim(arr, length(size(arr)), idx)
        copyto!(arr_view, val)
    end
    nothing
end


struct Logger{T}
    log::Dict{Symbol, T}
end
Logger() = Logger(Dict{Symbol, Tuple{Vector, Vector}}())
function (logger::Logger)(x_val; kwargs...)
    for (key, val) in kwargs
        x_vec, y_vec = get!(logger.log, key, (typeof(x_val)[], typeof(val)[]))
        push!(x_vec, x_val)
        push!(y_vec, val)
    end
    nothing
end

@with_kw struct PPOSolver
    n_steps::Int64 = 1_000_000
    lr::Float32 = 3f-4
    lr_decay::Bool = true
    traj_len::Int64 = 2048
    batch_size::Int64 = 64
    n_epochs::Int64 = 10
    discount::Float32 = 0.99f0
    gae_lambda::Float32 = 1f0 # 1.0 corresponds to not using GAE
    clip_coef::Float32 = 0.2f0
    clip_vloss::Bool = false
    norm_advantages::Bool = true
    ent_coef::Float32 = 0
    vf_coef::Float32 = 0.5f0
    max_grad_norm::Float32 = 0.5
    rng=default_rng()
    seed::Int64 = 0
    device::String = "cpu"
    shared_dims::Vector{Int64} = []
    actor_dims::Vector{Int64}  = [64, 64]
    critic_dims::Vector{Int64} = [64, 64]
    squash::Bool = false
    kl_targ::Float64 = 0.02
    action_space::String = "auto"
end

function policy_loss_fun(
    a_logprob::T, 
    newlogprob::T, 
    advantages::T, 
    clip_coef::T2
    ) where {T2<:Real, T<:AbstractVector{T2}}

    log_ratio = newlogprob .- a_logprob
    ratio = exp.(log_ratio)
    pg_loss1 = -advantages .* ratio
    pg_loss2 = -advantages .* clamp.(ratio, 1-clip_coef, 1+clip_coef)
    policy_batch_loss = mean(max.(pg_loss1, pg_loss2))

    clip_fracs = @ignore_derivatives mean(abs.(ratio .- 1) .> clip_coef)
    kl_est = @ignore_derivatives mean((ratio .- 1) .- log_ratio)

    return policy_batch_loss, clip_fracs, kl_est
end

function value_loss_fun(
    values::T, 
    newvalue::T, 
    returns::T, 
    clip_vloss::Bool, 
    clip_coef::T2
    ) where {T2<:Real, T<:AbstractVector{T2}}

    if clip_vloss
        v_loss_unclipped = (newvalue .- returns).^2
        v_clipped = values .+ clamp.(newvalue .- values, -clip_coef, clip_coef)
        v_loss_clipped = (v_clipped .- returns).^2
        v_loss_max = max.(v_loss_unclipped, v_loss_clipped)
        value_batch_loss = mean(v_loss_max)/2
    else
        value_batch_loss = Flux.mse(newvalue, returns)/2
    end

    return value_batch_loss
end

function train_batch!(
        ac::ActorCritic,
        opt,
        buffer::Buffer, 
        solver::PPOSolver
    )
    @unpack_PPOSolver solver

    loss_tup = (
        policy_loss = Float32[],
        value_loss  = Float32[],
        entropy_loss= Float32[],
        total_loss  = Float32[],
        clip_frac   = Float32[],
        kl_est      = Float32[]
    )

    mini_b::typeof(buffer) = fmap(x->similar(x, size(x)[1:end-1]..., batch_size), buffer)

    for idxs in Iterators.partition(randperm(size(buffer.done,1)), batch_size)
        # copyto!(mini_b, buffer, idxs)
        copyfun(b1, b2) = copyto!(b1, selectdim(b2, ndims(b2), idxs))
        fmap(copyfun, mini_b, buffer)

        if norm_advantages
            advantages = (mini_b.advantages .- mean(mini_b.advantages)) / (std(mini_b.advantages) + 1f-8)
        else
            advantages = mini_b.advantages
        end

        grads = Flux.gradient(ac) do ac
            (_, newlogprob, entropy, newvalue) = get_actionvalue(ac, mini_b.s, mini_b.a)

            (policy_loss, clip_frac, kl_est) = policy_loss_fun(mini_b.a_logprob, newlogprob, advantages, clip_coef)
            
            value_loss = value_loss_fun(mini_b.value, newvalue, mini_b.returns, clip_vloss, clip_coef)
            
            entropy_loss = mean(entropy)
            
            total_loss = policy_loss - ent_coef*entropy_loss + vf_coef*value_loss

            ignore_derivatives() do
                push!(loss_tup.policy_loss, policy_loss)
                push!(loss_tup.value_loss, value_loss)
                push!(loss_tup.entropy_loss, entropy_loss)
                push!(loss_tup.total_loss, total_loss) 
                push!(loss_tup.clip_frac, clip_frac)
                push!(loss_tup.kl_est, kl_est)
            end

            return total_loss
        end

        Flux.update!(opt, ac, grads[1])
    end

    return map(mean, loss_tup)
end

function rollout!(env, buffer, ac, traj_len, device)
    # infer device from ac?
    
    for traj_step in 1:traj_len
        s = observe(env) |> stack .|> Float32 |> device
        (a, a_logprob, _, value) = get_actionvalue(ac, s)
        r = act!(env, cpu(a))
        done = terminated(env)
        send_to!(buffer, traj_step; s, a, a_logprob, value, r, done)
    end
    last_s = observe(env) |> stack .|> Float32 |> device
    (_, _, _, last_value) = get_actionvalue(ac, last_s)
    return last_value
end

function gae!(buffer::Buffer, last_value, discount, gae_lambda)
    last_advantage = similar(buffer.advantages, size(buffer.advantages,1)) .= 0
    
    itrs = eachcol.((
        buffer.advantages, 
        buffer.r, 
        buffer.done, 
        buffer.value
    ))

    for (advantages, r, done, value) in Iterators.reverse(zip(itrs...))
        td = r .+ discount * (.!done .* last_value) .- value
        advantages .= td .+ (discount*gae_lambda) * (.!done .* last_advantage)
        last_value, last_advantage = value, advantages
    end

    buffer.returns .= buffer.advantages .+ buffer.value
    nothing
end

function solve(
    env::Union{CommonRLInterface.AbstractEnv, CommonRLInterface.Wrappers.AbstractWrapper}, 
    solver::PPOSolver
    )    

    @unpack_PPOSolver solver

    @assert isa(base_env(env), MultiEnv) "This PPO algorithm is only designed to work on RLEnvTools.MultiEnv environments"

    n_envs = length(terminated(env))
    n_transitions = Int64(n_envs*solver.traj_len)
    @assert iszero(n_transitions%batch_size) "traj_len*n_envs not divisible by batch_size"

    acts = first(actions(env)) # first because multienv
    actionspace = SpaceStyle(acts)
    if actionspace isa FiniteSpaceStyle
        @assert sort(collect(acts))==collect(1:length(acts)) "actions(env) should correspond to action indices."

        ac = DiscreteActorCritic(env; solver.shared_dims, solver.actor_dims, solver.critic_dims)
    elseif actionspace isa ContinuousSpaceStyle
        lb = all(bounds(acts)[1] .≈ -1)
        ub = all(bounds(acts)[2] .≈ 1)
        @assert solver.squash&&lb&&ub "Squash is active, but action bounds are not [-1, 1]"

        ac = ContinuousActorCritic(env; solver.shared_dims, solver.actor_dims, solver.critic_dims, solver.squash)
    else
        @assert false "Action space is not finite or continous (see CommonRLSpaces)."
    end

    buffer = Buffer(env, solver.traj_len)

    opt_0 = Flux.Optimisers.OptimiserChain(
        Flux.Optimisers.ClipNorm(solver.max_grad_norm), 
        Flux.Optimisers.Adam(solver.lr)
    )

    ppo(env, ac, opt_0, buffer, solver)
end

function ppo(
    env::Union{MultiEnv, CommonRLInterface.Wrappers.AbstractWrapper}, 
    ac::ActorCritic,
    opt_0,
    buffer::Buffer,
    solver::PPOSolver
    )

    @unpack_PPOSolver solver

    start_time = time()
    info = Logger()
    global_step = 0

    seed!(rng, seed)
    reset!(env)

    device = (device == "gpu") ? gpu : cpu
    learning_rate = lr

    buffer = buffer |> device
    ac = ac |> device
    opt = Flux.setup(opt_0, ac)

    prog = Progress(n_steps)
    n_transitions = Int64(length(terminated(env))*traj_len)
    for global_step in n_transitions:n_transitions:n_steps
        last_value = rollout!(env, buffer, ac, traj_len, device)
        gae!(buffer, last_value, discount, gae_lambda)

        if lr_decay
            learning_rate = (1-global_step/n_steps)*lr
            Flux.Optimisers.adjust!(opt, learning_rate)
        end

        for epoch in 1:n_epochs
            loss_info = train_batch!(ac, opt, flatten(buffer, 2), solver)

            if epoch == n_epochs || loss_info.kl_est > kl_targ
                info(global_step; loss_info...)
                break
            end
        end
        
        info(global_step; learning_rate, wall_time = time() - start_time)

        next!(prog; 
            step = n_transitions, 
            showvalues = [(k,v[2][end]) for (k,v) in zip(keys(info.log),values(info.log))]
        )
    end
    finish!(prog)

    return cpu(ac), info.log
end

end