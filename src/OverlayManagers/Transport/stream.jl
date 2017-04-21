import Base: write, unsafe_write, flush, isopen, close, buffer_writes

type OverlayStream <: IO
    net::OverlayNetwork
    dest::OverlayID
    buffer::IOBuffer
    r_c::Condition
    is_open::Bool
    buffer_writes::Bool
    lock::ReentrantLock  # Used by ClusterManger internals. BAD!

    function OverlayStream(net::OverlayNetwork, dest)
        new(net, OverlayID(dest), PipeBuffer(), Condition(), true, false, ReentrantLock())
    end
end

isopen(s::OverlayStream) = s.is_open
function close(s::OverlayStream)
    s.is_open = false
    nothing
end

function write(s::OverlayStream, byte::UInt8)
    if s.buffer_writes
        write(s.buffer, byte)
    else
        send(s.net, s.dest, DATA_TYPE, [byte])
    end
end

function unsafe_write(s::OverlayStream, p::Ptr{UInt8}, n::UInt)
    unsafe_write(s.buffer, p, n)
    buffered_bytes = nb_available(s.buffer)

    if !s.buffer_writes
        send(s.net, s.dest, DATA_TYPE, read(s.buffer, buffered_bytes))
    end

    return n
end

function flush(s::OverlayStream)
    if s.buffer_writes
        payload = readavailable(s.buffer)
        !isempty(payload) && send(s.net, s.dest, DATA_TYPE, payload)
    end
    nothing
end

buffer_writes(s::OverlayStream, bufsize=0) = (s.buffer_writes = true; s)
