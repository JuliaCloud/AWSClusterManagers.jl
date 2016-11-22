type Broker
    sock::TCPSocket
end

function Broker(id::Integer)
    sock = connect(2000)
    write(sock, UInt32(id))  # Register
    return Broker(sock)
end

function encode(io::IO, src_id::Integer, dest_id::Integer, message::AbstractString)
    write(io, UInt32(dest_id))
    write(io, UInt32(src_id))
    write(io, UInt32(length(message)))
    write(io, message)
end

function decode(io::IO)
    dest_id = read(io, UInt32)
    src_id = read(io, UInt32)
    len = read(io, UInt32)
    msg = String(read(io, len))
    return (src_id, dest_id, msg)
end

