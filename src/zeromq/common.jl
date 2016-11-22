module Common

using ZMQ

import Base: launch, manage, connect, kill

const BROKER_SUB_PORT = 8100
const BROKER_PUB_PORT = 8101

const SELF_INITIATED = 0
const REMOTE_INITIATED = 1

const PAYLOAD_MSG = "J"
const CONTROL_MSG = "Z"

const REQUEST_ACK = "R"
const ACK_MSG = "A"
const KILL_MSG = "K"

# Keep track of some state on the node
type Node
    id::Int  # The ID of the current node
    mapping::Dict{Int,Tuple}
    context::Context
    pub::Socket
    sub::Socket
    isfree::Bool
    condition::Condition
end

function Node(id::Integer)
    context = Context()

    pub = Socket(context, PUB)  # Outbound messages to broker
    connect(pub, "tcp://127.0.0.1:$BROKER_SUB_PORT")

    sub = Socket(context, SUB)  # Inbound messages from broker
    connect(sub, "tcp://127.0.0.1:$BROKER_PUB_PORT")
    ZMQ.set_subscribe(sub, string(id))  # TODO: Better way to do this?

    Node(
        Int(id),
        Dict{Int,Tuple}(),
        context,
        pub,
        sub,
        true,
        Condition(),
    )
end

# TODO: Should only be needed temporarily
function Node()
    context = Context()
    Node(
        0,
        Dict{Int,Tuple}(),
        context,
        Socket(context, PUB),
        Socket(context, SUB),
        true,
        Condition(),
    )
end

type ZMQManager <: ClusterManager
    node::Node
end

ZMQManager() = ZMQManager(Node())


# Used by: worker
function lock(node::Node)
    if node.isfree
        node.isfree = false
    else
        while !node.isfree
            wait(node.condition)
            if node.isfree
                node.isfree = false
                return
            end
        end
    end
end

# Used by: worker
function release(node::Node)
    node.isfree = true
    notify(node.condition, all=true)
end

# Used by: worker
function send(node::Node, zid::Integer, mtype, data)
    lock(node)
    ZMQ.send(node.pub, Message(string(zid)), SNDMORE)
    ZMQ.send(node.pub, Message(string(node.id)), SNDMORE)
    #println("Sending message of type $mtype to $zid")
    ZMQ.send(node.pub, Message(mtype), SNDMORE)
    ZMQ.send(node.pub, Message(data))
    release(node)
end

# Used by: worker
function setup_connection(node::Node, zid, initiated_by)
    try
        read_stream=BufferStream()
        write_stream=BufferStream()

        if initiated_by == REMOTE_INITIATED
            test_remote = false
        else
            test_remote = true
        end

        node.mapping[zid] = (read_stream, write_stream, test_remote)

        @schedule begin
            while true
                (r_s, w_s, do_test_remote) = node.mapping[zid]
                if do_test_remote
                    send(node, zid, CONTROL_MSG, REQUEST_ACK)
                    sleep(0.5)
                else
                    break
                end
            end
            (r_s, w_s, do_test_remote) = node.mapping[zid]

            while true
                data = readavailable(w_s)
                send(node, zid, PAYLOAD_MSG, data)
            end
        end
        (read_stream, write_stream)
    catch e
        Base.show_backtrace(STDOUT,catch_backtrace())
        println(e)
        rethrow(e)
    end
end



# Used by: manager, worker
function recv(node::Node)
    try
        #println("On $(node.id) waiting to recv message")
        zid = parse(Int,unsafe_string(ZMQ.recv(node.sub)))
        assert(zid == node.id)

        from_zid = parse(Int,unsafe_string(ZMQ.recv(node.sub)))
        mtype = unsafe_string(ZMQ.recv(node.sub))

        #println("$zid received message of type $mtype from $from_zid")

        data = ZMQ.recv(node.sub)
        if mtype == CONTROL_MSG
            cmsg = unsafe_string(data)
            if cmsg == REQUEST_ACK
                #println("$from_zid REQUESTED_ACK from $zid")
                # send back a control_msg
                send(node, from_zid, CONTROL_MSG, ACK_MSG)
            elseif cmsg == ACK_MSG
                #println("$zid got ACK_MSG from $from_zid")
                (r_s, w_s, test_remote) = node.mapping[from_zid]
                node.mapping[from_zid] = (r_s, w_s, false)
            elseif cmsg == KILL_MSG
                exit(0)
            else
                error("Unknown control message : ", cmsg)
            end
            data = ""
        end

        (from_zid, data)
    catch e
        Base.show_backtrace(STDOUT,catch_backtrace())
        println(e)
        rethrow(e)
    end

end

function launch(manager::ZMQManager, params::Dict, launched::Array, c::Condition)
    #println("launch $(params[:np])")
    for i in 1:params[:np]
        spawn(`$(params[:exename]) -e "using AWSClusterManagers; AWSClusterManagers.ZeroMQ.Worker.start_worker($i, \"$(Base.cluster_cookie())\")"`)

        wconfig = WorkerConfig()
        wconfig.userdata = Dict{Symbol,Any}(:zid=>i)
        push!(launched, wconfig)
        notify(c)
    end
end

function connect(manager::ZMQManager, pid::Int, config::WorkerConfig)
    #println("connect_m2w")
    if myid() == 1
        zid = get(config.userdata)[:zid]
        config.connect_at = zid # This will be useful in the worker-to-worker connection setup.
    else
        #println("connect_w2w")
        zid = get(config.connect_at)
        config.userdata = Dict{Symbol,Any}(:zid=>zid)
    end

    streams = setup_connection(manager.node, zid, SELF_INITIATED)

    udata = get(config.userdata)
    udata[:streams] = streams

    streams
end

function manage(manager::ZMQManager, id::Int, config::WorkerConfig, op)
    if op == :interrupt
        zid = get(config.userdata)[:zid]
        send(manager.node, zid, CONTROL_MSG, KILL_MSG)

        # TODO: Need to clear out mapping on workers?
        (r_s, w_s) = get(config.userdata)[:streams]
        close(r_s)
        close(w_s)

        # remove from our map
        delete!(manager.node.mapping, get(config.userdata)[:zid])
    end
    nothing
end

function kill(manager::ZMQManager, pid::Int, config::WorkerConfig)
    send(manager.node, get(config.userdata)[:zid], CONTROL_MSG, KILL_MSG)
    (r_s, w_s) = get(config.userdata)[:streams]
    close(r_s)
    close(w_s)

    # remove from our map
    delete!(manager.node.mapping, get(config.userdata)[:zid])

    nothing
end


function print_worker_stdout(io, pid)
    @schedule while !eof(io)
        line = readline(io)
        print("\tFrom worker $(pid):\t$line")
    end
end

end
