using AWSSDK.Batch: describe_job_queues, describe_compute_environments

function get_compute_envs(job_queue::AbstractString)
    queue_desc = get(describe_job_queues(jobQueues = [job_queue]), "jobQueues", nothing)
    if queue_desc === nothing || length(queue_desc) < 1
        throw(BatchEnvironmentError("Cannot get job queue information for $job_queue."))
    end
    queue_desc = queue_desc[1]
    env_ord = get(queue_desc, "computeEnvironmentOrder", nothing)
    if env_ord === nothing
        throw(BatchEnvironmentError("Cannot get compute environment information for $job_queue."))
    end
    [env["computeEnvironment"] for env in env_ord if haskey(env, "computeEnvironment")]
end

function max_vcpus(job_queue::AbstractString)
    env_desc = describe_compute_environments(computeEnvironments = get_compute_envs(job_queue))
    comp_envs = get(env_desc, "computeEnvironments", nothing)
    if comp_envs === nothing
        throw(BatchEnvironmentError("Cannot get compute environment information for $job_queue."))
    end
    total_vcpus = 0
    for env in comp_envs
        total_vcpus += get(env["computeResources"], "maxvCpus", 0)
    end
    total_vcpus
end
