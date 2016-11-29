import Base: ==, write, read

@enum MessageType DATA UNREACHABLE

type OverlayMessage
    src::UInt128
    dest::UInt128
    typ::MessageType
    body::Vector{UInt8}
end

function (==)(a::OverlayMessage, b::OverlayMessage)
    return (
        a.src == b.src &&
        a.dest == b.dest &&
        a.typ == b.typ &&
        a.body == b.body
    )
end

function write(io::IO, msg::OverlayMessage)
    write(io, UInt128(msg.src))
    write(io, UInt128(msg.dest))
    write(io, UInt8(msg.typ))

    if msg.typ == DATA
        write(io, UInt64(length(msg.body)))
        write(io, msg.body)
    end
end

function read(io::IO, ::Type{OverlayMessage})
    src = read(io, UInt128)
    dest = read(io, UInt128)
    typ = MessageType(read(io, UInt8))

    if typ == DATA
        len = read(io, UInt64)
        body = read(io, len)
    else
        body = Vector{UInt8}()
    end

    return OverlayMessage(src, dest, typ, body)
end

function header(msg::OverlayMessage)
    return (msg.src, msg.dest, msg.typ)
end
