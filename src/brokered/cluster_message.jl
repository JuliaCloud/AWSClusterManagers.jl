import Base: convert

const DATA_MSG = 0x00
const KILL_MSG = 0x01
const HELLO_MSG = 0x02

type ClusterMessage
    typ::UInt8
    data::Vector{UInt8}
end

ClusterMessage(typ::UInt8) = ClusterMessage(typ, UInt8[])

convert(::Type{Vector{UInt8}}, msg::ClusterMessage) = vcat(msg.typ, msg.data)
convert(::Type{ClusterMessage}, d::Vector{UInt8}) = ClusterMessage(d[1], d[2:end])
