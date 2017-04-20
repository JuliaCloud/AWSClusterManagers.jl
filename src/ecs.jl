import Base: ==
using JSON

const MAX_COUNT = 10  # Maximum count value that can be supplied to ECS RunTask

immutable ECSManager <: ContainerManager
    min_workers::Int
    max_workers::Int
    task_def::AbstractString
    task_name::AbstractString
    cluster::AbstractString
    region::AbstractString
    timeout::Float64

    function ECSManager(min_workers::Integer, max_workers::Integer, task_def::AbstractString,
        task_name::AbstractString, cluster::AbstractString, region::AbstractString,
        timeout::Real,
    )
        if isempty(task_name)
            task_name = first(split(task_def, ':'))
        end
        new(min_workers, max_workers, task_def, task_name, cluster, region, timeout)
    end
end

function ECSManager(min_workers::Integer, max_workers::Integer, task_def::AbstractString;
        task_name::AbstractString="", cluster::AbstractString="", region::AbstractString="",
        timeout::Real=DEFAULT_TIMEOUT,
    )
    ECSManager(min_workers, max_workers, task_def, task_name, cluster, region, timeout)
end

function ECSManager{I<:Integer}(workers::UnitRange{I}, task_def::AbstractString; kwargs...)
    ECSManager(start(workers), last(workers), task_def; kwargs...)
end

function ECSManager(workers::Integer, task_def::AbstractString; kwargs...)
    ECSManager(workers, workers, task_def; kwargs...)
end

launch_timeout(mgr::ECSManager) = mgr.timeout
num_workers(mgr::ECSManager) = mgr.min_workers, mgr.max_workers

function ==(a::ECSManager, b::ECSManager)
    return (
        a.min_workers == b.min_workers &&
        a.max_workers == b.max_workers &&
        a.task_def == b.task_def &&
        a.task_name == b.task_name &&
        a.cluster == b.cluster &&
        a.region == b.region &&
        a.timeout == b.timeout
    )
end

function start_containers(manager::ECSManager, override_cmd::Cmd)
    num_containers = manager.max_workers
    region = manager.region
    cluster = manager.cluster
    task_definition = manager.task_def

    # Start new ECS tasks which will report back on to the manager via the open port
    # we just opened on the manager.
    #
    # Typically Julia workers are started using the hidden flags --bind-to and --worker.
    # We won't use the `--bind-to` flag as we don't know where the container will be
    # started and what ports will be available. We don't want to use `--worker COOKIE`
    # as this essentially runs `start_worker(STDOUT, COOKIE)` which reports the worker
    # address and port to STDOUT. Instead we'll run the code ourselves and report the
    # connection information back to the manager over a socket.

    r = isempty(region) ? `` : `--region $(region)`
    cmd = `aws $r ecs run-task --count $num_containers --task-definition $task_definition`
    if !isempty(cluster)
        cmd = `$cmd --cluster $cluster`
    end
    overrides = Dict(
        "containerOverrides" => [
            Dict(
                # When using overrides you need to specify the name of the task which
                # we are overriding. Needs to match what is within the task definition.
                "name" => manager.task_name,
                "command" => collect(override_cmd.exec),
            )
        ]
    )
    cmd = `$cmd --overrides $(JSON.json(overrides))`

    # ECS RunTask operation limits count. We'll get around this by running the command
    # multiple times.
    remaining = num_containers
    while remaining > 0
        count = remaining > MAX_COUNT : MAX_COUNT : remaining

        # In order to start ECS tasks the container needs to have the appropriate AWS access.
        run(pipeline(`$cmd --count $count`, stdout=DevNull))
        remaining -= count
    end
end
