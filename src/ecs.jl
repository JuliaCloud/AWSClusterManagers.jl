import Base: wait, ==
export ECSManager

using JSON

immutable ECSManager <: ClusterManager
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
        timeout::Real=300,
    )
    ECSManager(min_workers, max_workers, task_def, task_name, cluster, region, timeout)
end

function ECSManager{I<:Integer}(workers::UnitRange{I}, task_def::AbstractString; kwargs...)
    ECSManager(start(workers), last(workers), task_def; kwargs...)
end

function ECSManager(workers::Integer, task_def::AbstractString; kwargs...)
    ECSManager(workers, workers, task_def; kwargs...)
end

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

function launch(manager::ECSManager, params::Dict, launched::Array, c::Condition)
    min_workers, max_workers = manager.min_workers, manager.max_workers
    region = manager.region
    cluster = manager.cluster
    task_definition = manager.task_def

    launch_tasks = Vector{Task}(max_workers)

    # TODO: Should be using TLS connections.
    port, server = listenany(ip"::", PORT_HINT)  # Listen on all IPv4 and IPv6 interfaces
    for i in 1:max_workers
        launch_tasks[i] = @schedule begin
            sock = accept(server)

            # The worker will report it's own address through the socket. Eventually the
            # built in Julia cluster manager code will parse the stream and record the
            # address and port.
            config = WorkerConfig()
            config.io = sock

            # Note: `launched` is treated as a queue and will have elements removed from it
            # periodically.
            push!(launched, config)
            notify(c)
        end
    end

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
    cmd = `aws $r ecs run-task --count $max_workers --task-definition $task_definition`
    if !isempty(cluster)
        cmd = `$cmd --cluster $cluster`
    end
    overrides = Dict(
        "containerOverrides" => [
            Dict(
                "command" => [
                    "julia",
                    "-e",
                    "sock = connect(ip\"$(getipaddr())\", $port); Base.start_worker(sock, \"$(cluster_cookie())\")",
                ],
                # When using overrides you need to specify the name of the task which
                # we are overriding. Needs to match what is within the task definition.
                "name" => manager.task_name,
            )
        ]
    )
    cmd = `$cmd --overrides $(JSON.json(overrides))`

    # In order to start ECS tasks the container needs to have the appropriate AWS access
    run(pipeline(cmd, stdout=DevNull))

    function callback(num_failed)
        num_launched = max_workers - num_failed
        if num_launched >= min_workers
            warn("Only managed to launch $num_launched/$max_workers workers")
        else
            error("Unable to launch the minimum number of workers")
        end
    end

    # Await for workers to inform the manager of their address.
    wait(launch_tasks, manager.timeout, callback)

    # TODO: Does stopping listening terminate the sockets from `accept`? If so, we could
    # potentially close the socket before we know the name of the connected worker. During
    # prototyping this has not been an issue.
    close(server)
    notify(c)
end

function manage(manager::ECSManager, id::Integer, config::WorkerConfig, op::Symbol)
    # Note: Terminating the TCP connection from the master to the worker will cause the
    # worker to shutdown automatically.
end

function wait(tasks::AbstractArray{Task}, timeout::Real, timed_out_cb::Function=(n)->nothing)
    start = time()
    unfinished = 0
    for t in tasks
        while true
            task_done = istaskdone(t)
            timed_out = (time() - start) >= timeout

            if timed_out || task_done
                if timed_out && !task_done
                    unfinished += 1
                end
                break
            end

            sleep(1)
        end
    end
    if unfinished > 0
        timed_out_cb(unfinished)
    end
end
