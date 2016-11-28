import Base: launch, manage, connect, kill

type BrokeredManager <: ClusterManager
    np::Int
    node::Node
    launcher::Function
end

function BrokeredManager(np::Integer; launcher::Function=spawn_local_worker)
    BrokeredManager(Int(np), Node(1), launcher)
end

function BrokeredManager(node::Node)
    BrokeredManager(0, node, (id,cookie) -> nothing)
end

function spawn_local_worker(id, cookie)
    spawn(`$(Base.julia_cmd()) -e "using AWSClusterManagers; AWSClusterManagers.Brokered.start_worker($id, \"$cookie\")"`)
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
    node = manager.node
    available_workers = 0

    @schedule begin
        while !eof(node.sock)
            (from_zid, data) = recv(node)
            msg = decode(data)

            # TODO: Do what worker does?
            if msg.typ == DATA_MSG
                debug("Receive DATA from $from_zid")

                (r_s, w_s) = node.streams[from_zid]
                unsafe_write(r_s, pointer(msg.data), length(msg.data))
            elseif msg.typ == HELLO_MSG
                debug("Receive HELLO from $from_zid")

                available_workers += 1

                # `launched` is treated as a queue and will have elements removed from it
                # periodically. Once an element is removed from the queue the manager will call
                # `connect` and send initial information to the worker.
                wconfig = WorkerConfig()
                wconfig.userdata = Dict{Symbol,Any}(:id=>from_zid)
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
        close(node)
    end

    # Note: The manager doesn't have to assign the broker ID. The workers could actually
    # self assign their own IDs as long as they are unique within the cluster.
    for i in 1:manager.np
        manager.launcher(get_next_broker_id(), Base.cluster_cookie())
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
    node = manager.node
    streams = get!(node.streams, zid) do
        info("Connect $(node.id) -> $zid")
        setup_connection(node, zid)
    end

    udata = get(config.userdata)
    udata[:streams] = streams

    streams
end

function manage(manager::BrokeredManager, id::Int, config::WorkerConfig, op)
    # println("manager: $op")
    # if op == :interrupt
    #     zid = get(config.userdata)[:zid]
    #     send(manager.node, zid, CONTROL_MSG, KILL_MSG)

    #     # TODO: Need to clear out mapping on workers?
    #     (r_s, w_s) = get(config.userdata)[:streams]
    #     close(r_s)
    #     close(w_s)

    #     # remove from our map
    #     delete!(manager.node.mapping, get(config.userdata)[:zid])
    # end

    # if op == :deregister
    #     # zid = get(config.userdata)[:id]
    #     # send(manager.node, zid, encode(Message(KILL_MSG, UInt8[])))

    #     # TODO: Do we need to cleanup the streams to this worker which are on other remote
    #     # workers?
    # elseif op == :finalize
    #     zid = get(config.userdata)[:id]
    #     send(manager.node, zid, encode(Message(KILL_MSG, UInt8[])))

    #     # TODO: Need to clear out mapping on workers?
    #     (r_s, w_s) = manager.node.streams[zid]
    #     close(r_s)
    #     close(w_s)

    #     # remove from our map
    #     delete!(manager.node.streams, zid)

    #     # TODO: Receive response?
    # end

    nothing
end

function kill(manager::BrokeredManager, pid::Int, config::WorkerConfig)
    zid = get(config.userdata)[:id]

    # TODO: I'm worried about the connection being terminated before the message is sent...
    info("Send KILL to $zid")
    send(manager.node, zid, encode(Message(KILL_MSG, UInt8[])))

    # Remove the streams from the node and close them
    (r_s, w_s) = pop!(manager.node.streams, zid)
    close(r_s)
    close(w_s)

    # Terminate socket from manager to broker when all workers have been killed
    # Doesn't work?
    node = manager.node
    if isempty(node.streams)
        close(node.sock)
    end

    nothing
end
