export ECSManager

using JSON

immutable ECSManager <: ClusterManager
    np::Integer
    region::AbstractString
    cluster::AbstractString
    task_def::AbstractString
    task_name::AbstractString

    function ECSManager(
            np::Integer, region::AbstractString="us-east-1", cluster::AbstractString="ETS",
            task_def::AbstractString="julia-baked:11", task_name::AbstractString="",
        )
        if isempty(task_name)
            task_name = first(split(task_def, ':'))
        end
        new(np, region, cluster, task_def, task_name)
    end
end

function launch(manager::ECSManager, params::Dict, launched::Array, c::Condition)
    np = manager.np
    region = manager.region
    cluster = manager.cluster
    task_definition = manager.task_def

    # Await for workers to inform their manager of their address
    port, server = listenany(ip"::", PORT_HINT)  # Listen on all IPv4 and IPv6 interfaces
    @sync begin
        # TODO: Need to stop listening after a period of time
        @async for p in 1:np
            sock = accept(server)

            config = WorkerConfig()
            config.io = sock

            push!(launched, config)
            notify(c)
        end

        # Launch new ECS tasks which will connect back to this manager
        # Note: Typically Julia workers use --bind-to and --worker
        cmd = `aws --region $region ecs run-task --cluster $cluster --task-definition $task_definition`
        overrides = Dict(
            "containerOverrides" => [
                Dict(
                    "command" => [
                        "julia",
                        "-e",
                        "sock = connect(ip\"$(getipaddr())\", $port); Base.start_worker(sock, \"$(cluster_cookie())\")",
                    ],
                    "name" => manager.task_name,
                )
            ]
        )

        # Need to have the appropriate AWS access
        run(pipeline(`$cmd --count $np --overrides $(JSON.json(overrides))`, stdout=DevNull))
    end

    # TODO: Does stopping listening terminate the sockets from `accept`? If so, we could
    # potentially close the socket before we know the name of the connected worker.
    close(server)
    notify(c)
end


function manage(manager::ECSManager, id::Integer, config::WorkerConfig, op::Symbol)
end
