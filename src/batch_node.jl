# A random ephemeral port. The port should always be free due to AWS Batch multi-mode
# parallel jobs using "awsvpc" networking on containers
const AWS_BATCH_JOB_NODE_PORT = 49152

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

    while isopen(server) && connected_workers < num_workers
        # TODO: Potential issue with a random connection consuming a worker slot?
        sock = accept(server)
        connected_workers += 1

        debug(LOGGER, "Worker connected")

        # Send the cluster cookie to the worker
        println(sock, cluster_cookie())

        # The worker will report it's own address through the socket. Eventually the
        # built in Julia cluster manager code will parse the stream and record the
        # address and port.
        config = WorkerConfig()
        config.io = sock

        # TODO: Should try to Julia worker numbers match to the AWS_BATCH_JOB_NODE_INDEX

        # Note: `launched` is treated as a queue and will have elements removed from it
        # periodically.
        push!(launched, config)
        notify(c)
    end

    close(server)
    notify(c)
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

    # Retrieve the cluster cookie from the manager
    cookie = readline(sock)

    # Hand off control to the Distributed stdlib which will have the worker report an IP
    # address and port at which connections can be established to this worker.
    start_worker(sock, cookie)
end
