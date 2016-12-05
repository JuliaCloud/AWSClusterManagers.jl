type AWSBatchJob
    id::String
    name::String
    definition::String
    queue::String
    region::String
end

function AWSBatchJob()
    job_id = ENV["AWS_BATCH_JOB_ID"]
    job_queue = ENV["AWS_BATCH_JQ_NAME"]

    # Get the zone information from the EC2 instance metadata.
    zone = readstring(pipeline(`curl http://169.254.169.254/latest/meta-data/placement/availability-zone`, stderr=DevNull))
    region = chop(zone)

    # Requires permissions to access to "batch:DescribeJobs"
    json = JSON.parse(readstring(`aws --region $region batch describe-jobs --jobs $job_id`))
    details = first(json["jobs"])

    AWSBatchJob(
        job_id,
        details["jobName"],
        details["jobDefinition"],
        job_queue,
        region,
    )
end

type AWSBatchManager <: OverlayClusterManager
    np::Int
    network::OverlaySocket
    prefix::AbstractString
    definition::AbstractString
    queue::AbstractString
    region::AbstractString
end

function AWSBatchManager(
        np::Integer;
        broker=(ip"10.128.247.176", DEFAULT_PORT),
        prefix::AbstractString="",
        definition::AbstractString="",
        queue::AbstractString="",
        region::AbstractString="",
    )
    host, port = isa(broker, AbstractString) ? (broker, DEFAULT_PORT) : broker

    # Workers by default inherit the AWS Batch settings from the manager.
    # Note: only query for default values if we need them as the lookup requires special
    # permissions.
    if isempty(prefix) || isempty(definition) || isempty(queue) || isempty(region)
        job = AWSBatchJob()

        prefix = isempty(prefix) ? "$(job.name)Worker" : prefix
        definition = isempty(definition) ? job.definition : definition
        queue = isempty(queue) ? job.queue : queue
        region = isempty(region) ? job.region : region
    end

    AWSBatchManager(
        Int(np),
        OverlaySocket(1, host, port),
        prefix,
        definition,
        queue,
        region,
    )
end

AWSClusterManagers.OverlayCluster.num_processes(mgr::AWSBatchManager) = mgr.np

function AWSClusterManagers.OverlayCluster.spawn(mgr::AWSBatchManager, id::Integer)
    cookie = Base.cluster_cookie()
    host = mgr.network.broker_host
    port = mgr.network.broker_port

    override_cmd = `julia -e "using AWSClusterManagers; start_worker($id, \"$cookie\", \"$host\", $port)"`

    cmd = `aws --region $(mgr.region) batch submit-job`
    cmd = `$cmd --job-name "$(mgr.prefix)$(lpad(id, 2, 0))"`
    cmd = `$cmd --job-queue $(mgr.queue)`
    cmd = `$cmd --job-definition $(mgr.definition)`
    overrides = Dict(
        "command" => collect(override_cmd.exec),
    )
    cmd = `$cmd --container-overrides $(JSON.json(overrides))`

    run(cmd)
end
