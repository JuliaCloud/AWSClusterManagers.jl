export ECSManager

using JSON

immutable ECSManager <: ClusterManager
    np::Integer
    task_def::AbstractString
    task_name::AbstractString
    cluster::AbstractString
    region::AbstractString
end

function ECSManager(
        np::Integer, task_def::AbstractString; task_name::AbstractString="",
        cluster::AbstractString="", region::AbstractString="",
    )
    if isempty(task_name)
        task_name = first(split(task_def, ':'))
    end
    ECSManager(np, task_def, task_name, cluster, region)
end

function launch(manager::ECSManager, params::Dict, launched::Array, c::Condition)
    np = manager.np
    region = manager.region
    cluster = manager.cluster
    task_definition = manager.task_def

    # Await for workers to inform their manager of their address.
    # TODO: Should be using TLS connections.
    port, server = listenany(ip"::", PORT_HINT)  # Listen on all IPv4 and IPv6 interfaces
    @sync begin
        # TODO: Support a timeout in case some containers never start
        @async for p in 1:np
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
        cmd = `aws $r ecs run-task --count $np --task-definition $task_definition`
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
    end

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
