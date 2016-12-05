import Base: launch, manage, connect, kill
import JSON

type BrokeredManager <: ClusterManager
    np::Int
    network::OverlaySocket
    launcher::Function
end

function BrokeredManager(np::Integer, broker=DEFAULT_HOST, port::Integer=DEFAULT_PORT; launcher::Function=spawn_local_worker)
    BrokeredManager(Int(np), OverlaySocket(1, broker, port), launcher)
end

function BrokeredManager(net::OverlaySocket)
    BrokeredManager(0, net, (id,cookie,host,port) -> nothing)
end

function spawn_local_worker(id, cookie, broker_host, broker_port)
    spawn(`$(Base.julia_cmd()) -e "using AWSClusterManagers; AWSClusterManagers.Brokered.start_worker($id, \"$cookie\", \"$broker_host\", $broker_port)"`)
end

function aws_batch_launcher(;
        name_prefix::AbstractString="",
        definition::AbstractString="",
        queue::AbstractString="",
        region::AbstractString="",
    )

    # Workers by default inherit the AWS Batch settings from the manager.
    # Note: only query for default values if we need them as the lookup requires special
    # permissions.
    if isempty(name_prefix) || isempty(definition) || isempty(queue) || isempty(region)
        job = AWSBatchJob()

        name_prefix = isempty(name_prefix) ? "$(job.name)Worker" : name_prefix
        definition = isempty(definition) ? job.definition : definition
        queue = isempty(queue) ? job.queue : queue
        region = isempty(region) ? job.region : region
    end

    function launcher(id::Integer, cookie::AbstractString, broker_host, broker_port::Integer)
        override_cmd = `julia -e "import AWSClusterManagers.Brokered: start_worker; start_worker($id, \"$cookie\", \"$broker_host\", $broker_port)"`

        cmd = `aws --region $region batch submit-job`
        cmd = `$cmd --job-name "$name_prefix$(lpad(id, 2, 0))"`
        cmd = `$cmd --job-queue $queue`
        cmd = `$cmd --job-definition $definition`
        overrides = Dict(
            "command" => collect(override_cmd.exec),
        )
        cmd = `$cmd --container-overrides $(JSON.json(overrides))`

        run(cmd)
    end

    return launcher
end

let next_id = 2    # 1 is reserved for the client (always)
    global get_next_broker_id
    function get_next_broker_id()
        id = next_id
        next_id += 1
        id
    end

    global reset_broker_id
    function reset_broker_id()
        next_id = 2
    end
end

function launch(manager::BrokeredManager, params::Dict, launched::Array, c::Condition)
    net = manager.network
    available_workers = 0

    @schedule begin
        while !eof(net.sock)
            msg = recv(net)
            from = msg.src

            # TODO: Do what worker does?
            if msg.typ == UNREACHABLE_TYPE
                debug("Receive UNREACHABLE from $from")

                if haskey(net.streams, from)
                    (r_s, w_s) = pop!(net.streams, from)
                    close(r_s)
                    close(w_s)
                end
            elseif msg.typ == DATA_TYPE
                debug("Receive DATA from $from")
                (r_s, w_s) = net.streams[from]
                unsafe_write(r_s, pointer(msg.payload), length(msg.payload))
            elseif msg.typ == HELLO_TYPE
                debug("Receive HELLO from $from")

                available_workers += 1

                # `launched` is treated as a queue and will have elements removed from it
                # periodically. Once an element is removed from the queue the manager will call
                # `connect` and send initial information to the worker.
                wconfig = WorkerConfig()
                wconfig.userdata = Dict{Symbol,Any}(:id=>from)
                push!(launched, wconfig)
                notify(c)
            else
                error("Unhandled message type: $(msg.typ)")
            end
        end

        # Close all remaining connections when the broker connection is terminated. This
        # will ensure that the local references to the workers are cleaned up.
        # Will generate "ERROR (unhandled task failure): EOFError: read end of file" when
        # the worker connection is severed.
        close(net)
    end

    # Note: The manager doesn't have to assign the broker ID. The workers could actually
    # self assign their own IDs as long as they are unique within the cluster.
    for i in 1:manager.np
        manager.launcher(
            get_next_broker_id(),
            Base.cluster_cookie(),
            net.broker_host,
            net.broker_port,
        )
    end

    # Wait until all requested workers are available.
    while available_workers < manager.np
        wait(c)
    end
end

# Used by the manager or workers to connect to estabilish connections to other nodes in the
# cluster.
function connect(manager::BrokeredManager, pid::Int, config::WorkerConfig)
    #println("connect_m2w")
    if myid() == 1
        zid = get(config.userdata)[:id]
        config.connect_at = zid # This will be useful in the worker-to-worker connection setup.
    else
        #println("connect_w2w")
        zid = get(config.connect_at)
        config.userdata = Dict{Symbol,Any}(:id=>zid)
    end

    # Curt: I think this is just used by the manager
    net = manager.network
    streams = get!(net.streams, zid) do
        info("Connect $(net.id) -> $zid")
        setup_connection(net, zid)
    end

    udata = get(config.userdata)
    udata[:streams] = streams

    streams
end

function manage(manager::BrokeredManager, id::Int, config::WorkerConfig, op)
    # println("manager: $op")
    # if op == :interrupt
    #     zid = get(config.userdata)[:zid]
    #     send(manager.network, zid, CONTROL_MSG, KILL_MSG)

    #     # TODO: Need to clear out mapping on workers?
    #     (r_s, w_s) = get(config.userdata)[:streams]
    #     close(r_s)
    #     close(w_s)

    #     # remove from our map
    #     delete!(manager.network.mapping, get(config.userdata)[:zid])
    # end

    # if op == :deregister
    #     # zid = get(config.userdata)[:id]
    #     # send(manager.network, zid, encode(Message(KILL_MSG, UInt8[])))

    #     # TODO: Do we need to cleanup the streams to this worker which are on other remote
    #     # workers?
    # elseif op == :finalize
    #     zid = get(config.userdata)[:id]
    #     send(manager.network, zid, encode(Message(KILL_MSG, UInt8[])))

    #     # TODO: Need to clear out mapping on workers?
    #     (r_s, w_s) = manager.network.streams[zid]
    #     close(r_s)
    #     close(w_s)

    #     # remove from our map
    #     delete!(manager.network.streams, zid)

    #     # TODO: Receive response?
    # end

    nothing
end

function kill(manager::BrokeredManager, pid::Int, config::WorkerConfig)
    zid = get(config.userdata)[:id]

    # TODO: I'm worried about the connection being terminated before the message is sent...
    info("Send KILL to $zid")
    send(manager.network, zid, KILL_TYPE)

    # Remove the streams from the node and close them
    (r_s, w_s) = pop!(manager.network.streams, zid)
    close(r_s)
    close(w_s)

    # Terminate socket from manager to broker when all workers have been killed
    # Doesn't work?
    net = manager.network
    if isempty(net.streams)
        close(net.sock)
    end

    nothing
end
