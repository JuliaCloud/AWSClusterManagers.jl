import Base: Semaphore, close

type Node
    id::UInt128
    sock::TCPSocket
    read_access::Semaphore
    write_access::Semaphore
    streams::Dict{UInt128,Tuple{IO,IO}}
end

function Node(id::Integer)
    sock = connect(2000)

    # Trying this to keep the connection open while data needs to be send
    # Base.disable_nagle(sock)
    # Base.wait_connected(sock)

    write(sock, UInt128(id))  # Register
    return Node(id, sock, Semaphore(1), Semaphore(1), Dict{UInt128,Tuple{IO,IO}}())
end

function close(node::Node)
    for (read_stream, write_stream) in values(node.streams)
        close(read_stream)
        close(write_stream)
    end

    close(node.sock)
end

function send(node::Node, dest_id::Integer, typ::MessageType, content)
    msg = OverlayMessage(node.id, dest_id, typ, content)

    # By the time we acquire the lock the socket may have been closed.
    acquire(node.write_access)
    isopen(node.sock) && write(node.sock, msg)
    release(node.write_access)
end

function recv(node::Node)
    acquire(node.read_access)
    msg = read(node.sock, OverlayMessage)
    release(node.read_access)

    return msg
end

const DATA_MSG = 0x00
const KILL_MSG = 0x01
const HELLO_MSG = 0x02

type Message
    typ::UInt8
    data::Vector{UInt8}
end

encode(msg::Message) = vcat(msg.typ, msg.data)
decode(content::AbstractVector{UInt8}) = Message(content[1], content[2:end])

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
        send(node, dest_id, DATA, encode(Message(DATA_MSG, data)))
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
