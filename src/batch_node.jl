# A random ephemeral port. The port should always be free due to AWS Batch multi-mode
# parallel jobs using "awsvpc" networking on containers
const AWS_BATCH_JOB_NODE_PORT = 49152

# The manager (main node) is started before the workers (other nodes). The delay allows the
# manager to listen for worker connections before the workers attempt to connect. Due to the
# delay we'll need to wait for the workers to connect. In some cases the worker nodes will
# fail to start so we need to have a timeout for those cases.
const AWS_BATCH_NODE_TIMEOUT = Minute(2)

# Julia cluster manager for AWS Batch multi-node parallel jobs
# https://docs.aws.amazon.com/batch/latest/userguide/multi-node-parallel-jobs.html
struct AWSBatchNodeManager <: ContainerManager
    num_workers::Int

    function AWSBatchNodeManager()
        if !haskey(ENV, "AWS_BATCH_JOB_MAIN_NODE_INDEX")
            error("Unable to use $AWSBatchNodeManager outside of a running AWS Batch multi-node parallel job")
        end

        if ENV["AWS_BATCH_JOB_NODE_INDEX"] != ENV["AWS_BATCH_JOB_MAIN_NODE_INDEX"]
            error("$AWSBatchNodeManager can only be used by the main node")
        end

        # Don't include the manager in the number of workers
        num_workers = parse(Int, ENV["AWS_BATCH_JOB_NUM_NODES"]) - 1

        return new(num_workers)
    end
end

function Distributed.launch(manager::AWSBatchNodeManager, params::Dict, launched::Array, c::Condition)
    num_workers = manager.num_workers
    connected_workers = 0

    debug(LOGGER, "Awaiting connections")

    # We cannot listen only to the `ENV["AWS_BATCH_JOB_MAIN_NODE_PRIVATE_IPV4_ADDRESS"]` as
    # this variable is not available on the main node.
    server = listen(ip"::", AWS_BATCH_JOB_NODE_PORT)
    debug(LOGGER, "Manager accepting worker connections on port $AWS_BATCH_JOB_NODE_PORT")

    listen_task = @async while isopen(server) && connected_workers < num_workers
        # TODO: Potential issue with a random connection consuming a worker slot?
        sock = accept(server)
        connected_workers += 1

        # Receive the job id and node index from the connected worker
        job_id = parse_job_id(readline(sock))
        node_index = parse(Int, match(r"(?<=\#)\d+", job_id).match)

        debug(LOGGER, "Worker connected from node $node_index")

        # Send the cluster cookie to the worker
        println(sock, "julia_cookie:", cluster_cookie())
        flush(sock)

        # The worker will report it's own address through the socket. Eventually the
        # built in Julia cluster manager code will parse the stream and record the
        # address and port.
        config = WorkerConfig()
        config.io = sock
        config.userdata = Dict(
            :job_id => job_id,
            :node_index => node_index,
        )

        # Note: Julia worker numbers will not match up to the `node_index` of the worker.
        # Primarily this is due to the worker numbers being 1-indexed while nodes are
        # 0-indexed.

        # Note: `launched` is treated as a queue and will have elements removed from it
        # periodically.
        push!(launched, config)
        notify(c)
    end

    wait(listen_task, AWS_BATCH_NODE_TIMEOUT)

    close(server)
    notify(c)

    if connected_workers < num_workers
        warn(LOGGER, "Only $connected_workers of the $num_workers workers job have reported in")
    else
        debug(LOGGER, "All workers have successfully reported in")
    end
end

function start_batch_node_worker()
    if !haskey(ENV, "AWS_BATCH_JOB_ID") || !haskey(ENV, "AWS_BATCH_JOB_NODE_INDEX")
        error("Unable to start a worker outside of a running AWS Batch multi-node parallel job")
    end

    # The environmental variable for the main node address is only set within multi-node
    # parallel child nodes and is not present on the main node. See:
    # https://docs.aws.amazon.com/batch/latest/userguide/multi-node-parallel-jobs.html#mnp-env-vars
    manager_ip = parse(IPAddr, ENV["AWS_BATCH_JOB_MAIN_NODE_PRIVATE_IPV4_ADDRESS"])
    sock = connect(manager_ip, AWS_BATCH_JOB_NODE_PORT)

    # Note: The job ID also contains the node index
    println(sock, "job_id:", ENV["AWS_BATCH_JOB_ID"])
    flush(sock)

    # Retrieve the cluster cookie from the manager
    cookie = parse_cookie(readline(sock))

    # Hand off control to the Distributed stdlib which will have the worker report an IP
    # address and port at which connections can be established to this worker.
    start_worker(sock, cookie)
end

function parse_job_id(str::AbstractString)
    # Note: Require match on prefix to ensure we are parsing the correct value
    m = match(r"^job_id:([a-z0-9-]{36}\#\d+)", str)

    if m !== nothing
        return m.captures[1]
    else
        error(LOGGER, "Unable to parse job id: $str")
    end
end

function parse_cookie(str::AbstractString)
    # Note: Require match on prefix to ensure we are parsing the correct value
    m = match(r"^julia_cookie:(\w+)", str)

    if m !== nothing
        return m.captures[1]
    else
        error(LOGGER, "Unable to parse cluster cookie: $str")
    end
end
