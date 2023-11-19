@with_kw struct PPOSolver{
    E<:AbstractMultiEnv, 
    RNG<:AbstractRNG, 
    OPT<:Flux.Optimisers.AbstractRule, 
    AC<:ActorCritic
    }
    
    env::E
    n_steps::Int64 = 1_000_000
    lr::Float32 = 3f-4
    clipl2::Float32 = 0.5
    lr_decay::Bool = false
    traj_len::Int64 = 2048
    batch_size::Int64 = 64
    n_epochs::Int64 = 10
    discount::Float32 = 0.99
    gae_lambda::Float32 = 0.95
    clip_coef::Float32 = 0.2
    norm_advantages::Bool = true
    ent_coef::Float32 = 0
    vf_coef::Float32 = 0.5
    rng::RNG = default_rng()
    kl_targ::Float32 = 0.02
    device::Function = cpu # cpu or gpu
    opt_0::OPT = Flux.Optimisers.Adam(lr)
    ac::AC = ActorCritic(env) 
    
    @assert device in [cpu, gpu]
    @assert iszero(Int64(length(env)*traj_len)%batch_size)

    @assert device == cpu "GPU capabilites currently under development"
end

function solve(solver::PPOSolver)
    @unpack env, ac, opt_0, n_steps, discount, gae_lambda, lr, lr_decay, traj_len = solver

    start_time = time()
    info = Logger{Tuple{Vector, Vector}}()

    opt = Flux.setup(opt_0, ac)
    buffer = Buffer(env, traj_len)

    reset!(env)
    
    prog = Progress((n_steps / length(buffer)) |> floor |> Int)

    for global_step in length(buffer):length(buffer):n_steps
        fill_buffer!(env, buffer, ac)

        learning_rate = lr_decay ? (lr - lr*global_step/n_steps) : lr
        Flux.Optimisers.adjust!(opt, learning_rate)

        loss_info = train_epochs!(ac, opt, buffer, solver)
        
        info(global_step; wall_time = time() - start_time, learning_rate, loss_info...)

        next!(prog; showvalues = zip(keys(info.log), map(x->x[2][end], values(info.log))))
    end

    finish!(prog)

    info_log = info.log

    if ac isa ContinuousActorCritic
        info_log = Dict{Symbol, Any}(info_log)
        info_log[:log_std] = (info_log[:log_std][1], stack(info_log[:log_std][2])')        
    end

    return cpu(ac), info_log
end

function fill_buffer!(env::AbstractMultiEnv, buffer::Buffer, ac::ActorCritic)
    sav = get_stateactionvalue(env, ac)

    for idx in 1:buffer.traj_len
        r = act!(env, sav.a)
        done = terminated(env)
        trunc = truncated(env)
        sav′ = get_stateactionvalue(env, ac)

       send_to!(buffer, idx; sav..., r, done, trunc, next_value=sav′.value) 

        if any(done .|| trunc)
            reset!(env, done .|| trunc)
            sav = get_stateactionvalue(env, ac)
        else
            sav = sav′
        end
    end
    nothing
end

function get_stateactionvalue(env, ac)
    s = observe(env)
    action_mask = if provided(valid_action_mask, env) valid_action_mask(env) end
    (a, a_logprob, _, value) = get_actionvalue(ac, s; action_mask)
    return (; s, action_mask, a, a_logprob, value)
end

function train_epochs!(ac, opt, buffer, solver)
    @unpack batch_size, discount, gae_lambda, norm_advantages = solver

    advantages, value_targets = gae(buffer, discount, gae_lambda)

    batch = (; buffer.s, buffer.a, buffer.a_logprob, buffer.action_mask, advantages, value_targets)

    loss_info = Logger{Vector}()

    for _ in 1:solver.n_epochs
        empty!(loss_info.log)

        for idxs in Iterators.partition(randperm(solver.rng, length(buffer)), batch_size)
            mini_batch = map(batch) do x
                isnothing(x) && return nothing
                y = reshape(x, size(x)[1:end-2]..., :) # flatten
                copy(selectdim(y, ndims(y), idxs)) # copy important!
            end

            if norm_advantages
                mini_batch.advantages .= normalize(mini_batch.advantages; dims=2)
            end
    
            flag = train_minibatch!(ac, opt, mini_batch, solver, loss_info)
            flag && return map(mean, (; loss_info.log...))
        end
    end

    return map(mean, (; loss_info.log...))
end

function train_minibatch!(ac, opt, mini_batch, solver, loss_info)
    @unpack clip_coef, ent_coef, vf_coef, clipl2 = solver

    grads = Flux.gradient(ac) do ac
        (_, newlogprob, entropy, newvalue) = get_actionvalue(ac, mini_batch.s, mini_batch.a; mini_batch.action_mask)

        log_ratio = newlogprob .- mini_batch.a_logprob
        ratio = exp.(log_ratio)
        pg_loss1 = -mini_batch.advantages .* ratio
        pg_loss2 = -mini_batch.advantages .* clamp.(ratio, 1-clip_coef, 1+clip_coef)
        policy_loss = mean(max.(pg_loss1, pg_loss2))
    
        value_loss = Flux.mse(newvalue, mini_batch.value_targets)
        entropy_loss = mean(entropy)
        total_loss = policy_loss - ent_coef*entropy_loss + vf_coef*value_loss

        ignore_derivatives() do 
            clip_frac = mean(abs.(ratio .- 1) .> clip_coef)
            kl_est = mean((ratio .- 1) .- log_ratio)

            loss_info(; 
                policy_loss, value_loss, entropy_loss, total_loss, clip_frac, kl_est
            )

            if ac isa ContinuousActorCritic
                loss_info(; ac.log_std)
            end
        end

        return total_loss
    end

    if loss_info.log[:kl_est][end] > 1.5*solver.kl_targ
        return true
    end

    if isfinite(clipl2)
        P = Flux.params(x)
        lambda = min(1, clipl2/sqrt(sum(x->norm(x)^2, P)))
        for p in P
            p .*= lambda
        end
    end

    Flux.update!(opt, ac, grads[1])

    return false
end

gae(buffer, γ, λ) = gae!(similar(buffer.r), similar(buffer.r), buffer, γ, λ)
function gae!(advantages, value_targets, buffer::Buffer, γ::Real, λ::Real)
    @unpack r, done, trunc, value, next_value = buffer

    @. advantages = r + γ * !done * next_value - value  # 1-step (td error) 

    trace = @. λ * γ * !(done || trunc)

    # cleanear code that works with gpu?
    next_advantage = similar(advantages, size(advantages,1)) .= 0
    for (advantages, trace) in Iterators.reverse(zip(eachslice.((advantages, trace); dims=ndims(advantages))...))
        next_advantage = @. advantages += trace * next_advantage
    end

    @. value_targets = advantages + value
    
    return advantages, value_targets
end

normalize(x::AbstractArray; eps=1e-8, dims) = (x .- mean(x; dims)) ./ (std(x; dims) .+ eltype(x)(eps))
