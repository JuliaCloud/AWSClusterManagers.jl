# A random ephemeral port. The port should always be free due to AWS Batch multi-mode
# parallel jobs using "awsvpc" networking on containers
const AWS_BATCH_JOB_NODE_PORT = 49152

# The maximum amount of time to listen for worker connections. Note that the manager
# (main node) is started before the workers (other nodes) which allows the manager time to
# initialize before the workers attempt to connect. In a scenario in which a worker fails
# and never connects to the manager this timeout will allow the manager continue with the
# subset of workers which have already connected.
const AWS_BATCH_NODE_TIMEOUT = Minute(5)

# Julia cluster manager for AWS Batch multi-node parallel jobs
# https://docs.aws.amazon.com/batch/latest/userguide/multi-node-parallel-jobs.html
struct AWSBatchNodeManager <: ContainerManager
    num_workers::Int
    timeout::Second  # Duration to wait for workers to initially check-in with the manager

    function AWSBatchNodeManager(; timeout::Period=AWS_BATCH_NODE_TIMEOUT)
        if !haskey(ENV, "AWS_BATCH_JOB_ID") || !haskey(ENV, "AWS_BATCH_JOB_MAIN_NODE_INDEX")
            error(
                "Unable to use $AWSBatchNodeManager outside of a running AWS Batch multi-node parallel job",
            )
        end

        info(LOGGER, "AWS Batch Job ID: $(ENV["AWS_BATCH_JOB_ID"])")

        if ENV["AWS_BATCH_JOB_NODE_INDEX"] != ENV["AWS_BATCH_JOB_MAIN_NODE_INDEX"]
            error("$AWSBatchNodeManager can only be used by the main node")
        end

        # Don't include the manager in the number of workers
        num_workers = parse(Int, ENV["AWS_BATCH_JOB_NUM_NODES"]) - 1

        return new(num_workers, Second(timeout))
    end
end

function Distributed.launch(
    manager::AWSBatchNodeManager, params::Dict, launched::Array, c::Condition
)
    num_workers = manager.num_workers
    connected_workers = 0

    debug(LOGGER, "Awaiting connections")

    # We cannot listen only to the `ENV["AWS_BATCH_JOB_MAIN_NODE_PRIVATE_IPV4_ADDRESS"]` as
    # this variable is not available on the main node. However, since we known the workers
    # will use this IPv4 specific address we'll only listen to IPv4 interfaces.
    server = listen(IPv4(0), AWS_BATCH_JOB_NODE_PORT)
    debug(LOGGER, "Manager accepting worker connections on port $AWS_BATCH_JOB_NODE_PORT")

    # Maintain an internal array of worker configs to allow us to set the ordering
    workers = sizehint!(WorkerConfig[], num_workers)

    listen_task = @async while isopen(server) && connected_workers < num_workers
        # TODO: Potential issue with a random connection consuming a worker slot?
        sock = accept(server)
        connected_workers += 1

        # Receive the job id and node index from the connected worker
        job_id = parse_job_id(readline(sock))
        node_index = parse(Int, match(r"(?<=\#)\d+", job_id).match)

        debug(LOGGER, "Worker connected from node $node_index")

        # Send the cluster cookie and timeout to the worker
        println(sock, "julia_cookie:", cluster_cookie())
        println(sock, "julia_worker_timeout:", Dates.value(Second(manager.timeout)))
        flush(sock)

        # The worker will report it's own address through the socket. Eventually the
        # built in Julia cluster manager code will parse the stream and record the
        # address and port.
        config = WorkerConfig()
        config.io = sock
        config.userdata = (; :job_id => job_id, :node_index => node_index)

        push!(workers, config)
    end

    wait(listen_task, manager.timeout)
    close(server)

    # Note: `launched` is treated as a queue and will have elements removed from it
    # periodically from `addprocs`. By adding all the elements at once we can control the
    # ordering of the workers make it the same as the node index ordering.
    #
    # Note: Julia worker numbers will not match up to the node index of the worker.
    # Primarily this is due to the worker numbers being 1-indexed while nodes are 0-indexed.
    append!(launched, sort!(workers; by=w -> w.userdata.node_index))
    notify(c)

    if connected_workers < num_workers
        warn(
            LOGGER,
            "Only $connected_workers of the $num_workers workers job have reported in",
        )
    else
        debug(LOGGER, "All workers have successfully reported in")
    end
end

function start_batch_node_worker()
    if !haskey(ENV, "AWS_BATCH_JOB_ID") || !haskey(ENV, "AWS_BATCH_JOB_NODE_INDEX")
        error(
            "Unable to start a worker outside of a running AWS Batch multi-node parallel job",
        )
    end

    info(LOGGER, "AWS Batch Job ID: $(ENV["AWS_BATCH_JOB_ID"])")

    # Note: Limiting to IPv4 to match what AWS Batch provides us with for the manager.
    function available_ipv4_msg()
        io = IOBuffer()
        write(io, "Available IPv4 interfaces are:")

        # Include a listing of external IPv4 interfaces and addresses for debugging.
        for i in get_interface_addrs()
            if i.address isa IPv4 && !i.is_internal
                write(io, "\n  $(i.name): inet $(i.address)")
            end
        end

        return String(take!(io))
    end

    # A multi-node parallel job uses the "awsvpc" networking mode which defines "ecs-eth0"
    # in addition to the "eth0" interface. By default Julia tries to use the IP address from
    # "ecs-eth0" which uses a local-link address (169.254.0.0/16) which is unreachable from
    # the manager. Typically this is fixed by specifying the "eth0" IP address as
    # `--bind-to` when starting the Julia worker process.
    opts = Base.JLOptions()
    ip = if opts.bindto != C_NULL
        parse(IPAddr, unsafe_string(opts.bindto))
    else
        getipaddr()
    end

    if is_link_local(ip)
        error(LOGGER) do
            "Aborting due to use of link-local address ($ip) on worker which will be " *
            "unreachable by the manager. Be sure to specify a `--bind-to` address when " *
            "starting Julia. $(available_ipv4_msg())"
        end
    else
        info(LOGGER, "Reporting worker address $ip to the manager")
        debug(LOGGER) do
            available_ipv4_msg()
        end
    end

    # The environmental variable for the main node address is only set within multi-node
    # parallel child nodes and is not present on the main node. See:
    # https://docs.aws.amazon.com/batch/latest/userguide/multi-node-parallel-jobs.html#mnp-env-vars
    manager_ip = parse(IPv4, ENV["AWS_BATCH_JOB_MAIN_NODE_PRIVATE_IPV4_ADDRESS"])

    # Establish a connection to the manager. If the manager is slow to startup the worker
    # will attempt to connect for ~2 minutes.
    manager_connect = retry(
        () -> connect(manager_ip, AWS_BATCH_JOB_NODE_PORT);
        delays=ExponentialBackOff(; n=8, max_delay=30),
        check=(s, e) -> e isa Base.IOError,
    )
    sock = manager_connect()

    # Note: The job ID also contains the node index
    println(sock, "job_id:", ENV["AWS_BATCH_JOB_ID"])
    flush(sock)

    # Retrieve the cluster cookie from the manager
    cookie = parse_cookie(readline(sock))

    # Retrieve the worker timeout as specified in the manager
    timeout = parse_worker_timeout(readline(sock))

    # Hand off control to the Distributed stdlib which will have the worker report an IP
    # address and port at which connections can be established to this worker.
    #
    # The worker timeout needs to be equal to or exceed the amount of time in which the
    # manager waits for workers to report in. The reason for this is that the manager waits
    # to connect to all workers until connecting to any worker. If we use the default
    # timeout then a worker could report in early and self-terminate before the manager
    # connects to that worker. If that scenario occurs then the manager will become stuck
    # during the setup process.
    withenv("JULIA_WORKER_TIMEOUT" => timeout) do
        start_worker(sock, cookie)
    end
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

function parse_worker_timeout(str::AbstractString)
    # Note: Require match on prefix to ensure we are parsing the correct value
    m = match(r"^julia_worker_timeout:(\d+)", str)

    if m !== nothing
        return parse(Int, m.captures[1])
    else
        error(LOGGER, "Unable to parse worker timeout: $str")
    end
end
