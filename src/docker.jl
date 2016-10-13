using Docker

const HOST = "localhost:2375"
INITIALIZED = false

immutable DockerManager <: ClusterManager
    min_workers::Int
    max_workers::Int
    image::AbstractString
    timeout::Float64

    function DockerManager(min_workers::Integer, max_workers::Integer,
            image::AbstractString, timeout::Real,
        )
        _init_docker_engine()
        if isempty(image)
            image = _image_id(HOST, _container_id())
        end
        new(min_workers, max_workers, image, timeout)
    end
end

function DockerManager(min_workers::Integer, max_workers::Integer; image::AbstractString="",
        timeout::Real=300,
    )
    DockerManager(min_workers, max_workers, image, timeout)
end

function DockerManager{I<:Integer}(workers::UnitRange{I}; kwargs...)
    DockerManager(start(workers), last(workers); kwargs...)
end

function DockerManager(workers::Integer; kwargs...)
    DockerManager(workers, workers; kwargs...)
end

function ==(a::DockerManager, b::DockerManager)
    return (
        a.min_workers == b.min_workers &&
        a.max_workers == b.max_workers &&
        a.image == b.image &&
        a.timeout == b.timeout
    )
end

function launch(manager::DockerManager, params::Dict, launched::Array, c::Condition)
    min_workers, max_workers = manager.min_workers, manager.max_workers
    image = manager.image

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

    exec = "sock = connect(ip\"$(getipaddr())\", $port); Base.start_worker(sock, \"$(cluster_cookie())\")"
    command = `julia -e $exec`
    println(command)
    container_id = Docker.create_container(
        HOST, manager.image;
        cmd=command,
        networkMode="host",
    )["Id"]
    Docker.start_container(HOST, container_id)

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

function manage(manager::DockerManager, id::Integer, config::WorkerConfig, op::Symbol)
    # Note: Terminating the TCP connection from the master to the worker will cause the
    # worker to shutdown automatically.
end

function _container_id()
    id = ""
    isfile("/proc/self/cgroup") || return id
    prefix = "/docker/"
    open("/proc/self/cgroup") do fp
        while !eof(fp)
            line = chomp(readline(fp))
            value = split(line, ':')[3]
            if startswith(value, prefix)
                id = value[(length(prefix) + 1):end]
                break
            end
        end
    end
    return String(id)
end

function _image_id(host, container_id)
    container = Docker.inspect_container(host, container_id)
    return last(split(container["Image"], ':'))
end

function _init_docker_engine()
    global INITIALIZED

    if !INITIALIZED
        # Expecting that this code is run within a docker container that has
        # /var/run/docker.sock mounted from the host.
        # Note: The reason we need to bind a port to a unix-socket is because the Docker.jl
        # and Requests.jl both do not support unix-sockets.
        run(detach(`socat TCP-LISTEN:2375,bind=127.0.0.1,reuseaddr,fork,range=127.0.0.0/8 UNIX-CLIENT:/var/run/docker.sock`))
        INITIALIZED = true
    end
end
