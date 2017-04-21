import Base: ==
using JSON

# Note: Communication directly between AWS Batch jobs works since the underlying ECS task
# implicitly uses networkMode: host. If this changes to another networking mode AWS Batch
# jobs may no longer be able to listen to incoming connections.

immutable AWSBatchManager <: ContainerManager
    min_workers::Int
    max_workers::Int
    job_definition::AbstractString
    job_name::AbstractString
    job_queue::AbstractString
    region::AbstractString
    timeout::Float64

    function AWSBatchManager(
        min_workers::Integer,
        max_workers::Integer,
        definition::AbstractString,
        name::AbstractString,
        queue::AbstractString,
        region::AbstractString,
        timeout::Real=DEFAULT_TIMEOUT,
    )
        min_workers > 0 || throw(ArgumentError("min workers must be positive"))
        min_workers <= max_workers || throw(ArgumentError("min workers exceeds max workers"))

        # Workers by default inherit the AWS Batch settings from the manager.
        # Note: only query for default values if we need them as the lookup requires special
        # permissions.
        if isempty(definition) || isempty(name) || isempty(queue)
            job = AWSBatchJob()

            definition = isempty(definition) ? job.definition : definition
            name = isempty(name) ? job.name : name  # Maybe append "Worker" to default?
            queue = isempty(queue) ? job.queue : queue
            region = isempty(region) ? job.region : region
        else
            # At the moment AWS batch only supports the "us-east-1" region
            region = isempty(region) ? "us-east-1" : region
        end

        new(min_workers, max_workers, definition, name, queue, region, timeout)
    end
end

function AWSBatchManager(
    min_workers::Integer,
    max_workers::Integer;
    definition::AbstractString="",
    name::AbstractString="",
    queue::AbstractString="",
    region::AbstractString="",
    timeout::Real=DEFAULT_TIMEOUT,
)
    AWSBatchManager(min_workers, max_workers, definition, name, queue, region, timeout)
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
        a.region == b.region &&
        a.timeout == b.timeout
    )
end

function start_containers(mgr::AWSBatchManager, override_cmd::Cmd)
    # Start new ECS tasks which will report back on to the manager via the open port
    # we just opened on the manager.
    #
    # Typically Julia workers are started using the hidden flags --bind-to and --worker.
    # We won't use the `--bind-to` flag as we don't know where the container will be
    # started and what ports will be available. We don't want to use `--worker COOKIE`
    # as this essentially runs `start_worker(STDOUT, COOKIE)` which reports the worker
    # address and port to STDOUT. Instead we'll run the code ourselves and report the
    # connection information back to the manager over a socket.

    cmd = `aws --region $(mgr.region) batch submit-job`
    cmd = `$cmd --job-name $(mgr.job_name)`
    cmd = `$cmd --job-queue $(mgr.job_queue)`
    cmd = `$cmd --job-definition $(mgr.job_definition)`
    overrides = Dict(
        "command" => collect(override_cmd.exec),
    )
    cmd = `$cmd --container-overrides $(JSON.json(overrides))`

    for id in 1:mgr.max_workers
        run(cmd)
    end
end
