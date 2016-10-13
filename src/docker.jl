using Docker

const HOST = "localhost:2375"
INITIALIZED = false

immutable DockerManager <: ContainerManager
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

function start_containers(manager::DockerManager, override_cmd::Cmd)
    num_containers = manager.max_workers

    for num in 1:num_containers
        container_id = Docker.create_container(
            HOST, manager.image;
            cmd=override_cmd,
            networkMode="host",
        )["Id"]
        Docker.start_container(HOST, container_id)
    end
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
        isfile("/var/run/docker.sock") || error("Docker engine unix-socket unavailable")

        # Expecting that this code is run within a docker container that has
        # /var/run/docker.sock mounted from the host.
        # Note: The reason we need to bind a port to a unix-socket is because the Docker.jl
        # and Requests.jl both do not support unix-sockets.
        run(detach(`socat TCP-LISTEN:2375,bind=127.0.0.1,reuseaddr,fork,range=127.0.0.0/8 UNIX-CLIENT:/var/run/docker.sock`))
        INITIALIZED = true
    end
end
