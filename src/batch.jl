import Base: ==
using JSON

# Note: Communication directly between AWS Batch jobs works since the underlying ECS task
# implicitly uses networkMode: host. If this changes to another networking mode AWS Batch
# jobs may no longer be able to listen to incoming connections.

"""
    AWSBatchManager(max_workers; kwargs...)
    AWSBatchManager(min_workers:max_workers; kwargs...)
    AWSBatchManager(min_workers, max_workers; kwargs...)

A cluster manager which spawns workers via [Amazon Web Services Batch](https://aws.amazon.com/batch/)
service. Typically used within an AWS Batch job to add additional resources. The number of
workers spawned may be potentially be lower than the requested `max_workers` due to resource
contention. Specifying `min_workers` can allow the launch to succeed with less than the
requested `max_workers`.

## Arguments
- `min_workers::Int`: The minimum number of workers to spawn or an exception is thrown
- `max_workers::Int`: The number of requested workers to spawn

## Keywords
- `definition::AbstractString`: Name of the AWS Batch job definition which dictates
  properties of the job including the Docker image, IAM role, and command to run
- `name::AbstractString`: Name of the job inside of AWS Batch
- `memory::Integer`: Memory limit (in MiB) for the job container. The container will be killed
  if it exceeds this value.
- `region::AbstractString`: The region in which the API requests are sent and in which new
  worker are spawned. Defaults to "us-east-1". [Available regions for AWS batch](http://docs.aws.amazon.com/general/latest/gr/rande.html#batch_region)
  can be found in the AWS documentation.
- `timeout::Float64`: The maximum number of seconds to wait for workers to become available
  before attempting to proceed without the missing workers.

## Examples
```julia
julia> addprocs(AWSBatchManager(3))  # Needs to be run from within a running AWS batch job
```
"""
AWSBatchManager

immutable AWSBatchManager <: ContainerManager
    min_workers::Int
    max_workers::Int
    job_definition::AbstractString
    job_name::AbstractString
    job_queue::AbstractString
    job_memory::Integer
    region::AbstractString
    timeout::Float64

    function AWSBatchManager(
        min_workers::Integer,
        max_workers::Integer,
        definition::AbstractString,
        name::AbstractString,
        queue::AbstractString,
        memory::Integer,
        region::AbstractString,
        timeout::Real=DEFAULT_TIMEOUT,
    )
        min_workers > 0 || throw(ArgumentError("min workers must be positive"))
        min_workers <= max_workers || throw(ArgumentError("min workers exceeds max workers"))

        # Workers by default inherit the AWS batch settings from the manager.
        # Note: only query for default values if we need them as the lookup requires special
        # permissions.
        if isempty(definition) || isempty(name) || isempty(queue) || memory == -1
            job = AWSBatchJob()

            definition = isempty(definition) ? job.definition : definition
            name = isempty(name) ? job.name : name  # Maybe append "Worker" to default?
            queue = isempty(queue) ? job.queue : queue
            region = isempty(region) ? job.region : region
            memory = if memory == -1
                round(Integer, job.container["memory"] / job.container["vcpus"])
            else
                memory
            end
        else
            # At the moment AWS batch only supports the "us-east-1" region
            region = isempty(region) ? "us-east-1" : region
        end

        new(min_workers, max_workers, definition, name, queue, memory, region, timeout)
    end
end

function AWSBatchManager(
    min_workers::Integer,
    max_workers::Integer;
    definition::AbstractString="",
    name::AbstractString="",
    queue::AbstractString="",
    memory::Integer=-1,
    region::AbstractString="",
    timeout::Real=DEFAULT_TIMEOUT,
)
    AWSBatchManager(
        min_workers,
        max_workers,
        definition,
        name,
        queue,
        memory,
        region,
        timeout
    )
end

function AWSBatchManager{I<:Integer}(workers::UnitRange{I}; kwargs...)
    AWSBatchManager(start(workers), last(workers); kwargs...)
end

function AWSBatchManager(workers::Integer; kwargs...)
    AWSBatchManager(workers, workers; kwargs...)
end

launch_timeout(mgr::AWSBatchManager) = mgr.timeout
num_workers(mgr::AWSBatchManager) = mgr.min_workers, mgr.max_workers

function ==(a::AWSBatchManager, b::AWSBatchManager)
    return (
        a.min_workers == b.min_workers &&
        a.max_workers == b.max_workers &&
        a.job_definition == b.job_definition &&
        a.job_name == b.job_name &&
        a.job_queue == b.job_queue &&
        a.job_memory == b.job_memory &&
        a.region == b.region &&
        a.timeout == b.timeout
    )
end

function spawn_containers(mgr::AWSBatchManager, override_cmd::Cmd)
    # Requires that the `awscli` is installed
    cmd = `aws --region $(mgr.region) batch submit-job`
    cmd = `$cmd --job-name $(mgr.job_name)`
    cmd = `$cmd --job-queue $(mgr.job_queue)`
    cmd = `$cmd --job-definition $(mgr.job_definition)`

    # Since each batch worker can only use 1 cpu we override the vcpus to 1 and
    # scale the memory accordingly.
    overrides = Dict(
        "vcpus" => 1,
        "memory" => mgr.job_memory,
        "command" => collect(override_cmd.exec),
    )
    cmd = `$cmd --container-overrides $(JSON.json(overrides))`

    # AWS Batch jobs only allow us to spawn a job at a time
    for id in 1:mgr.max_workers
        j = JSON.parse(@mock readstring(cmd))
        notice(logger, "Spawning job: $(j["jobId"])")
    end
end
