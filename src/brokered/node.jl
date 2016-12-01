import Base: Semaphore, close

const DEFAULT_PORT = 2000

type Node
    id::UInt128
    sock::TCPSocket
    read_access::Semaphore
    write_access::Semaphore
    streams::Dict{UInt128,Tuple{IO,IO}}
    broker_host::IPAddr
    broker_port::Int
end

function Node(id::Integer, broker::IPAddr=ip"127.0.0.1", port::Integer=DEFAULT_PORT)
    sock = connect(broker, port)

    # Trying this to keep the connection open while data needs to be send
    # Base.disable_nagle(sock)
    # Base.wait_connected(sock)

    write(sock, UInt128(id))  # Register
    return Node(
        id,
        sock,
        Semaphore(1),
        Semaphore(1),
        Dict{UInt128,Tuple{IO,IO}}(),
        broker,
        port,
    )
end

function close(node::Node)
    for (read_stream, write_stream) in values(node.streams)
        close(read_stream)
        close(write_stream)
    end

    close(node.sock)
end

function send(node::Node, dest_id::Integer, typ::Integer, content)
    msg = OverlayMessage(node.id, dest_id, typ, content)

    # By the time we acquire the lock the socket may have been closed.
    acquire(node.write_access)
    isopen(node.sock) && write(node.sock, msg)
    release(node.write_access)
end

send(node::Node, dest_id::Integer, typ::Integer) = send(node, dest_id, typ, UInt8[])

function recv(node::Node)
    acquire(node.read_access)
    msg = read(node.sock, OverlayMessage)
    release(node.read_access)

    return msg
end


const send_to_broker = Condition()

function setup_connection(node::Node, dest_id::Integer)
    # read indicates data from the remote source to be processed by the current node
    # while write indicates data to be sent to the remote source
    read_stream = BufferStream()
    write_stream = BufferStream()

    node.streams[dest_id] = (read_stream, write_stream)

    # Transfer all data written to the write stream to the destination via the broker.
    @schedule while !eof(write_stream) && isopen(node.sock)
        debug("Transfer $(node.id) -> $dest_id")
        data = readavailable(write_stream)
        send(node, dest_id, DATA_TYPE, data)
        notify(send_to_broker)
    end

    return (read_stream, write_stream)
end

function transfer_pending(node::Node)
    for (read_stream, write_stream) in values(node.streams)
        if nb_available(write_stream) > 0
            return true
        end
    end

    return false
end

function Base.wait(node::Node)
    while transfer_pending(node)
        wait(send_to_broker)
    end
end
