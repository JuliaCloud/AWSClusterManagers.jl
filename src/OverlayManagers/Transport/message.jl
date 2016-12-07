import Base: ==, write, read

# Note: 0x80 to 0xff are reserved for use by broker clients that defined their own custom
# message types.
const DATA_TYPE = 0x00
const UNREACHABLE_TYPE = 0x01
const REGISTER_SUCCESS = 0x02
const REGISTER_FAIL = 0x03

typealias OverlayID UInt128

type OverlayMessage
    src::OverlayID
    dest::OverlayID
    typ::UInt8
    payload::Vector{UInt8}
end

function OverlayMessage(src::Integer, dest::Integer, payload)
    OverlayMessage(src, dest, DATA_TYPE, payload)
end

function (==)(a::OverlayMessage, b::OverlayMessage)
    return (
        a.src == b.src &&
        a.dest == b.dest &&
        a.typ == b.typ &&
        a.payload == b.payload
    )
end

function write(io::IO, msg::OverlayMessage)
    write(io, UInt128(msg.src))
    write(io, UInt128(msg.dest))
    write(io, UInt8(msg.typ))
    write(io, UInt64(length(msg.payload)))
    write(io, msg.payload)
end

function read(io::IO, ::Type{OverlayMessage})
    src = read(io, UInt128)
    dest = read(io, UInt128)
    typ = read(io, UInt8)
    len = read(io, UInt64)
    payload = read(io, len)
    return OverlayMessage(src, dest, typ, payload)
end

function header(msg::OverlayMessage)
    return (msg.src, msg.dest, msg.typ)
end
