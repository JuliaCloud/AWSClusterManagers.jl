import Base: Semaphore, close

type Node
    id::UInt32
    sock::TCPSocket
    read_access::Semaphore
    write_access::Semaphore
    streams::Dict{UInt32,Tuple{IO,IO}}
end

function Node(id::Integer)
    sock = connect(2000)

    # Trying this to keep the connection open while data needs to be send
    # Base.disable_nagle(sock)
    # Base.wait_connected(sock)

    write(sock, UInt32(id))  # Register
    return Node(id, sock, Semaphore(1), Semaphore(1), Dict{UInt32,Tuple{IO,IO}}())
end

function close(node::Node)
    for (read_stream, write_stream) in values(node.streams)
        close(read_stream)
        close(write_stream)
    end

    close(node.sock)
end

function encode(io::IO, src_id::Integer, dest_id::Integer, content::AbstractVector{UInt8})
    println("$(now()) SEND: $(src_id) -> $dest_id ($(length(content)))")
    write(io, UInt32(dest_id))
    write(io, UInt32(src_id))
    write(io, UInt32(length(content)))
    write(io, content)
end

function decode(io::IO)
    dest_id = read(io, UInt32)
    src_id = read(io, UInt32)
    len = read(io, UInt32)
    content = read(io, len)
    # println("$(now()) RECV: $src_id -> $dest_id ($len)")
    return (src_id, dest_id, content)
end

function encode(io::IO, src_id::Integer, dest_id::Integer, message::AbstractString)
    encode(io, src_id, dest_id, Vector{UInt8}(message))
end

function decode{T}(io::IO, ::Type{T})
    src_id, dest_id, content = decode(io)
    return (src_id, dest_id, T(content))
end

function encode(io::IO, src_id::Integer, dest_id::Integer, message::IO)
    encode(io, src_id, dest_id, readavailable(message))
end

function send(node::Node, dest_id::Integer, content)
    # By the time we acquire the lock the socket may have been closed.
    acquire(node.write_access)
    isopen(node.sock) && encode(node.sock, node.id, dest_id, content)
    release(node.write_access)
end

function recv(node::Node)
    acquire(node.read_access)
    src_id, dest_id, content = decode(node.sock)
    release(node.read_access)
    return src_id, content
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
        println("Sending buffer $(node.id) -> $dest_id")
        data = readavailable(write_stream)
        send(node, dest_id, encode(Message(DATA_MSG, data)))
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
