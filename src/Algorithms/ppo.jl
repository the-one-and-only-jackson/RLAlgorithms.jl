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
    burnin_steps::Int64 = 0
    discount::Float32 = 0.99
    gae_lambda::Float32 = 0.95
    clip_coef::Float32 = 0.2
    norm_advantages::Bool = true
    ent_coef::Float32 = 0f0
    vf_coef::Float32 = 0.5
    rng::RNG = default_rng()
    kl_targ::Float32 = 0.02
    device::Function = cpu # cpu or gpu
    opt_0::OPT = Flux.Optimisers.Adam(lr)
    ac_kwargs::NamedTuple = NamedTuple()
    ac::AC = ActorCritic(env; ac_kwargs...) 
    
    @assert device in [cpu, gpu]
    @assert iszero(Int64(length(env)*traj_len)%batch_size)

    @assert device == cpu "GPU capabilites currently under development"
end

function solve(solver::PPOSolver)
    @unpack env, ac, opt_0, n_steps, discount, gae_lambda, lr, lr_decay, traj_len, burnin_steps = solver

    start_time = time()
    info = Logger{Tuple{Vector, Vector}}()
    prog = Progress(n_steps)

    reset!(env)

    burnin_traj_len = floor(Int, burnin_steps/length(env))
    burnin_steps = length(env) * burnin_traj_len

    if burnin_steps > 0
        loss_info = critic_burnin(solver, burnin_traj_len)
        info(burnin_steps; wall_time = time() - start_time, learning_rate=lr, loss_info...)
        ProgressMeter.update!(prog, burnin_steps)
    end
    
    buffer = Buffer(env, traj_len)
    opt = Flux.setup(opt_0, ac)

    for global_step in burnin_steps+length(buffer):length(buffer):n_steps
        fill_buffer!(env, buffer, ac)

        learning_rate = lr_decay ? (lr - lr*global_step/n_steps) : lr
        Flux.Optimisers.adjust!(opt, learning_rate)

        loss_info = train_epochs!(ac, opt, buffer, solver)
        
        info(global_step; wall_time = time() - start_time, learning_rate, loss_info...)

        ProgressMeter.update!(
            prog, global_step; 
            showvalues = zip(keys(info.log), map(x->x[2][end], values(info.log)))
        )
    end

    finish!(prog)

    info_log = info.log

    # if ac isa ContinuousActorCritic
    #     info_log = Dict{Symbol, Any}(info_log)
    #     info_log[:log_std] = (info_log[:log_std][1], stack(info_log[:log_std][2])')        
    # end

    return cpu(ac), info_log
end

function critic_burnin(solver, burnin_traj_len)
    @unpack env, ac, opt_0, batch_size, discount, vf_coef, clipl2, rng = solver

    opt = Flux.setup(opt_0, ac)
    buffer = Buffer(env, burnin_traj_len)
    fill_buffer!(env, buffer, ac)

    _, value_targets = gae(buffer, discount, 1)

    loss_info = Logger{Vector}()

    for _ in 1:solver.n_epochs
        empty!(loss_info.log)

        for idxs in Iterators.partition(randperm(rng, length(buffer)), batch_size)
            function temp_fun(x)
                y = reshape(x, size(x)[1:end-2]..., :) # flatten
                copy(selectdim(y, ndims(y), idxs)) # copy important!        
            end
            temp_fun(x::Tuple) = temp_fun.(x)

            ac_input = ACInput(observation = temp_fun(buffer.s))
            targets = temp_fun(value_targets)
        
            grads = Flux.gradient(ac) do ac
                _, critic_out = get_actionvalue(ac, ac_input)
                value_loss = get_criticloss(ac.critic, critic_out, targets)[1]
                @ignore_derivatives loss_info(; value_loss, total_loss=vf_coef*value_loss)
                return value_loss
            end
        
            P = Flux.params(grads[1])
            l2_norm = sqrt(sum(x->norm(x)^2, P))
            loss_info(; l2_norm)
        
            if isfinite(clipl2)
                lambda = min(1, clipl2/l2_norm)
                for p in P
                    p .*= lambda
                end
            end
        
        
            Flux.update!(opt, ac, grads[1])
        end
    end

    return map(mean, (; loss_info.log...))   
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
    ac_input = ACInput(; observation = s, action_mask = action_mask)
    actor_out, critic_out = get_actionvalue(ac, ac_input)
    return (; s, action_mask, a=actor_out.action, a_logprob=actor_out.log_prob, critic_out.value)
end

function train_epochs!(ac, opt, buffer, solver)
    @unpack batch_size, discount, gae_lambda, norm_advantages = solver

    advantages, value_targets = gae(buffer, discount, gae_lambda)

    batch = (; buffer.s, buffer.a, buffer.a_logprob, buffer.action_mask, advantages, value_targets)

    loss_info = Logger{Vector}()

    for _ in 1:solver.n_epochs
        empty!(loss_info.log)

        for idxs in Iterators.partition(randperm(solver.rng, length(buffer)), batch_size)
            function temp_fun(x)
                y = reshape(x, size(x)[1:end-2]..., :) # flatten
                copy(selectdim(y, ndims(y), idxs)) # copy important!        
            end
            temp_fun(x::Tuple) = temp_fun.(x)
            temp_fun(::Nothing) = nothing
            mini_batch = map(temp_fun, batch)

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

    ac_input = ACInput(mini_batch.s, mini_batch.a, mini_batch.action_mask)

    grads = Flux.gradient(ac) do ac
        actor_out, critic_out = get_actionvalue(ac, ac_input)

        policy_loss, clip_frac, kl_est = get_policyloss(actor_out.log_prob, mini_batch.a_logprob, mini_batch.advantages, clip_coef)
        entropy = get_entropy(actor_out.entropy)
        value_loss, unexplained_variance = get_criticloss(ac.critic, critic_out, mini_batch.value_targets)
        total_loss = policy_loss - ent_coef * entropy + vf_coef * value_loss

        ignore_derivatives() do
            loss_info(; policy_loss, clip_frac, kl_est, unexplained_variance)
            loss_info(; value_loss, total_loss, entropy)
        end

        return total_loss
    end

    if haskey(loss_info.log, :kl_est) && loss_info.log[:kl_est][end] > 1.5*solver.kl_targ
        return true
    end

    P = Flux.params(grads[1])
    l2_norm = sqrt(sum(x->norm(x)^2, P))
    loss_info(; l2_norm)

    if isfinite(clipl2)
        lambda = min(1, clipl2/l2_norm)
        for p in P
            p .*= lambda
        end
    end

    Flux.update!(opt, ac, grads[1])

    return false
end

function get_policyloss(newlogprob::AbstractArray, oldlogprob::AbstractArray, advantages, clip_coef)
    log_ratio = newlogprob .- oldlogprob
    ratio = exp.(log_ratio)
    pg_loss1 = -advantages .* ratio
    pg_loss2 = -advantages .* clamp.(ratio, 1-clip_coef, 1+clip_coef)
    policy_loss = mean(max.(pg_loss1, pg_loss2))

    clip_frac = @ignore_derivatives mean(abs.(ratio .- 1) .> clip_coef)
    kl_est = @ignore_derivatives mean((ratio .- 1) .- log_ratio)

    return policy_loss, clip_frac, kl_est
end

function get_policyloss(newlogprob::Tuple, oldlogprob::Tuple, advantages, clip_coef)
    policyloss_tups = Tuple(
        get_policyloss(_newlogprob, _oldlogprob, advantages, clip_coef) 
        for (_newlogprob, _oldlogprob) in zip(newlogprob, oldlogprob)
    )

    policy_loss = sum(x->x[1], policyloss_tups)
    clip_frac = sum(x->x[2], policyloss_tups) / length(policyloss_tups)
    kl_est = sum(x->x[3], policyloss_tups)

    return policy_loss, clip_frac, kl_est
end

get_entropy(entropy::AbstractArray) = mean(entropy)
get_entropy(entropy::Tuple) = sum(get_entropy, entropy)

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
