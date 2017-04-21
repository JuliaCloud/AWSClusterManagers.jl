import ..AWSClusterManagers: AWSBatchJob

type AWSBatchOverlayManager <: OverlayClusterManager
    np::Int
    network::OverlayNetwork
    prefix::AbstractString
    definition::AbstractString
    queue::AbstractString
    region::AbstractString
end

function AWSBatchOverlayManager(
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

    manager_id = overlay_id(1, Base.cluster_cookie())
    AWSBatchOverlayManager(
        Int(np),
        OverlayNetwork(manager_id, host, port),
        prefix,
        definition,
        queue,
        region,
    )
end

num_processes(mgr::AWSBatchOverlayManager) = mgr.np

function spawn(mgr::AWSBatchOverlayManager, oid::Integer)
    cookie = Base.cluster_cookie()
    host = mgr.network.broker_host
    port = mgr.network.broker_port

    override_cmd = `julia -e "using AWSClusterManagers.OverlayManagers; start_worker($oid, \"$cookie\", \"$host\", $port)"`

    cmd = `aws --region $(mgr.region) batch submit-job`
    cmd = `$cmd --job-name "$(mgr.prefix)$(lpad(oid, 2, 0))"`
    cmd = `$cmd --job-queue $(mgr.queue)`
    cmd = `$cmd --job-definition $(mgr.definition)`
    overrides = Dict(
        "command" => collect(override_cmd.exec),
    )
    cmd = `$cmd --container-overrides $(JSON.json(overrides))`

    run(cmd)
end
