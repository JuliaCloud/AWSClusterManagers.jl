import Base: ==

# Seconds to wait for the AWS Batch cluster to scale up, spot requests to be fufilled,
# instances to finish initializing, and have the worker instances connect to the manager.
const BATCH_TIMEOUT = 900  # 15 minutes

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
- `queue::AbstractString`: The job queue in which workers are submitted. Can be either the
  queue name or the Amazon Resource Name (ARN) of the queue. If not set will default to
  the environmental variable "WORKER_JOB_QUEUE".
- `memory::Integer`: Memory limit (in MiB) for the job container. The container will be killed
  if it exceeds this value.
- `region::AbstractString`: The region in which the API requests are sent and in which new
  worker are spawned. Defaults to "us-east-1". [Available regions for AWS batch](http://docs.aws.amazon.com/general/latest/gr/rande.html#batch_region)
  can be found in the AWS documentation.
- `timeout::Real`: The maximum number of seconds to wait for workers to become available
  before attempting to proceed without the missing workers.

## Examples
```julia
julia> addprocs(AWSBatchManager(3))  # Needs to be run from within a running AWS batch job
```
"""
AWSBatchManager

struct AWSBatchManager <: ContainerManager
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
        timeout::Real=BATCH_TIMEOUT,
    )
        min_workers >= 0 || throw(ArgumentError("min workers must be non-negative"))
        min_workers <= max_workers || throw(ArgumentError("min workers exceeds max workers"))

        # Default the queue to using the WORKER_JOB_QUEUE environmental variable.
        if isempty(queue)
            queue = get(ENV, "WORKER_JOB_QUEUE", "")
        end

        region = isempty(region) ? "us-east-1" : region

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
    timeout::Real=BATCH_TIMEOUT,
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
desired_workers(mgr::AWSBatchManager) = mgr.min_workers, mgr.max_workers

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
    min_workers, max_workers = desired_workers(mgr)
    max_workers < 1 && return nothing

    queue = @mock JobQueue(mgr.job_queue)
    max_compute = @mock max_vcpus(queue)

    if min_workers > max_compute
        error(string(
            "Unable to launch the minimum number of workers ($min_workers) as the ",
            "minimum exceeds the max VCPUs available ($max_compute).",
        ))
    elseif max_workers > max_compute
        # Note: In addition to warning the user about the VCPU cap we could also also reduce
        # the number of worker we request. Unfortunately since we don't know how many jobs
        # are currently running or how long they will take we'll leave `max_workers`
        # untouched.
        warn(string(
            "Due to the max VCPU limit ($max_compute) most likely only a partial amount ",
            "of the requested workers ($max_workers) will be spawned.",
        ))
    end

    # Since each batch worker can only use one cpu we override the vcpus to one.
    job = run_batch(
        name = mgr.job_name,
        definition = mgr.job_definition,
        queue = mgr.job_queue,
        region = mgr.region,
        vcpus = 1,
        memory = mgr.job_memory,
        cmd = override_cmd,
        num_jobs = max_workers,
        allow_job_registration = false,
    )

    if max_workers > 1
        notice(logger, "Spawning array job: $(job.id) (n=$(mgr.max_workers))")
    else
        notice(logger, "Spawning job: $(job.id)")
    end

    return nothing
end
