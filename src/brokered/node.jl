type Node
    id::UInt32
    sock::TCPSocket
    streams::Dict{UInt32,Tuple{IO,IO}}
end

function Node(id::Integer)
    sock = connect(2000)
    write(sock, UInt32(id))  # Register
    return Node(id, sock, Dict{UInt32,Tuple{IO,IO}}())
end

function encode(io::IO, src_id::Integer, dest_id::Integer, content::AbstractVector{UInt8})
    println("SEND: $(src_id) -> $dest_id ($(length(content)))")
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
    println("RECV: $src_id -> $dest_id ($len)")
    return (src_id, dest_id, content)
end

function encode(io::IO, src_id::Integer, dest_id::Integer, message::AbstractString)
    encode(io, src_id, dest_id, Vector{UInt8}(message))
end

function decode{T}(io::IO, ::Type{T})
    src_id, dest_id, content = decode(io)
    return (src_id, dest_id, T(content))
end

function send(node::Node, dest_id::Integer, content)
    encode(node.sock, node.id, dest_id, content)
end

function recv(node::Node)
    src_id, dest_id, content = decode(node.sock)
    return src_id, content
end




function setup_connection(node::Node, dest_id::Integer)
    # read indicates data from the remote source to be processed by the current node
    # while write indicates data to be sent to the remote source
    read_stream = BufferStream()
    write_stream = BufferStream()

    node.streams[dest_id] = (read_stream, write_stream)

    # Transfer all data written to the write stream to the destination via the broker.
    @schedule while !eof(write_stream)
        data = readavailable(write_stream)
        println("Sending buffer $(node.id) -> $dest_id")
        send(node, dest_id, data)
    end

    return (read_stream, write_stream)
end


