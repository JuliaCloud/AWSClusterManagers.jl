import Base: ==

# In order to make a local Docker cluster you'll need to have an available Docker image that
# has Julia, a version of AWSClusterManagers which includes DockerManager, and the docker
# cli all baked into the image.
#
# You can then create a Docker container which is capable of spawning additional Docker
# containers via:
#
#    docker run --network=host -v /var/run/docker.sock:/var/run/docker.sock --rm -it <image> julia
#
# Note that host networking is required for the container to be able to communicate and
# the local docker UNIX socket needs to be forwarded so we can allow the container to
# communicate with host Docker process.

immutable DockerManager <: ContainerManager
    num_workers::Int
    image::AbstractString
    timeout::Float64

    function DockerManager(
        num_workers::Integer,
        image::AbstractString,
        timeout::Real=DEFAULT_TIMEOUT,
    )
        num_workers > 0 || throw(ArgumentError("num workers must be positive"))

        # Workers by default inherit the defaults from the manager.
        if isempty(image)
            image = image_id()
        end

        new(num_workers, image, timeout)
    end
end

function DockerManager(
    num_workers::Integer;
    image::AbstractString="",
    timeout::Real=DEFAULT_TIMEOUT,
)
    DockerManager(num_workers, image, timeout)
end

launch_timeout(mgr::DockerManager) = mgr.timeout
num_workers(mgr::DockerManager) = mgr.num_workers, mgr.num_workers

function ==(a::DockerManager, b::DockerManager)
    return (
        a.num_workers == b.num_workers &&
        a.image == b.image &&
        a.timeout == b.timeout
    )
end

function spawn_containers(mgr::DockerManager, override_cmd::Cmd)
    # Requires that the `docker` is installed
    cmd = `docker run --detach --network=host --rm $(mgr.image)`
    cmd = `$cmd $override_cmd`

    # Docker only allow us to spawn a job at a time
    for id in 1:mgr.num_workers
        container_id = @mock readstring(cmd)
        notice(logger, "Spawning container: $container_id")
    end
end

# Determine the container ID of the currently running container
function container_id()
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

# Determine the image ID of the currently running container
function image_id()
    json = JSON.parse(readstring(`docker container inspect $(container_id())`))
    return last(split(json[1]["Image"], ':'))
end
