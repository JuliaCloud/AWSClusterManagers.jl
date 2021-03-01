# Time to wait for the Docker containers to launch and the workers to connect to the
# manager
const DOCKER_TIMEOUT = Minute(1)

"""
    DockerManager(num_workers; kwargs...)

A cluster manager which spawns workers via a locally running [Docker](https://docs.docker.com/)
daemon service. Typically used on a single machine to debug multi-machine Julia code.

In order to make a local Docker cluster you'll need to have an available Docker image that
has Julia, a version of AWSClusterManagers which includes DockerManager, and the docker
cli all baked into the image.

You can then create a Docker container which is capable of spawning additional Docker
containers via:

   docker run --network=host -v /var/run/docker.sock:/var/run/docker.sock --rm -it <image> julia

**Note**: The host networking is required for the containers to be able to intercommunicate.
The Docker host's UNIX socket needs to be forwarded so we can allow the container to
communicate with host Docker process.

## Arguments
- `num_workers::Int`: The number of workers to spawn

## Keywords
- `image::AbstractString`: The docker image to run.
- `timeout::Second`: The maximum number of seconds to wait for workers to become available
  before aborting.

## Examples
```julia
julia> addprocs(DockerManager(4, "myproject:latest"))
```
"""
DockerManager

struct DockerManager <: ContainerManager
    num_workers::Int
    image::AbstractString
    timeout::Second
    min_ip::IPv4
    max_ip::IPv4

    function DockerManager(
        num_workers::Integer,
        image::AbstractString,
        timeout::Period=DOCKER_TIMEOUT,
        min_ip::IPv4=ip"0.0.0.0",
        max_ip::IPv4=ip"255.255.255.255",
    )
        num_workers >= 0 || throw(ArgumentError("num workers must be non-negative"))

        # Workers by default inherit the defaults from the manager.
        if isempty(image)
            image = @mock image_id()
        end

        new(num_workers, image, Second(timeout), min_ip, max_ip)
    end
end

function DockerManager(
    num_workers::Integer;
    image::AbstractString="",
    timeout::Union{Real, Period}=DOCKER_TIMEOUT,
    min_ip::IPv4=ip"0.0.0.0",
    max_ip::IPv4=ip"255.255.255.255",
)
    DockerManager(num_workers, image, timeout, min_ip, max_ip)
end

launch_timeout(mgr::DockerManager) = mgr.timeout
desired_workers(mgr::DockerManager) = mgr.num_workers, mgr.num_workers

function Base.:(==)(a::DockerManager, b::DockerManager)
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
        container_id = @mock read(cmd, String)
        notice(LOGGER, "Spawning container: $container_id")
    end
end

# Determine the image ID of the currently running container
function image_id(container_id::AbstractString=container_id())
    json = JSON.parse(read(`docker container inspect $container_id`, String))
    return last(split(json[1]["Image"], ':'))
end
