import Base: Semaphore, send, recv, close

const DEFAULT_HOST = ip"127.0.0.1"
const DEFAULT_PORT = 2000

type OverlaySocket
    id::UInt128
    sock::TCPSocket
    read_access::Semaphore
    write_access::Semaphore
    streams::Dict{UInt128,Tuple{IO,IO}}
    broker_host::Union{IPAddr,String}
    broker_port::Int
end

function OverlaySocket(id::Integer, broker=DEFAULT_HOST, port::Integer=DEFAULT_PORT)
    sock = connect(broker, port)

    # Trying this to keep the connection open while data needs to be send
    # Base.disable_nagle(sock)
    # Base.wait_connected(sock)

    write(sock, UInt128(id))  # Register
    return OverlaySocket(
        id,
        sock,
        Semaphore(1),
        Semaphore(1),
        Dict{UInt128,Tuple{IO,IO}}(),
        broker,
        port,
    )
end

function close(net::OverlaySocket)
    for (read_stream, write_stream) in values(net.streams)
        close(read_stream)
        close(write_stream)
    end

    close(net.sock)
end

function send(net::OverlaySocket, dest_id::Integer, typ::Integer, content)
    msg = OverlayMessage(net.id, dest_id, typ, content)

    # By the time we acquire the lock the socket may have been closed.
    acquire(net.write_access)
    isopen(net.sock) && write(net.sock, msg)
    release(net.write_access)
end

send(net::OverlaySocket, dest_id::Integer, typ::Integer) = send(net, dest_id, typ, UInt8[])

function recv(net::OverlaySocket)
    acquire(net.read_access)
    msg = read(net.sock, OverlayMessage)
    release(net.read_access)

    return msg
end

function setup_connection(net::OverlaySocket, dest_id::Integer)
    # read indicates data from the remote source to be processed by the current node
    # while write indicates data to be sent to the remote source
    read_stream = BufferStream()
    write_stream = BufferStream()

    net.streams[dest_id] = (read_stream, write_stream)

    # Transfer all data written to the write stream to the destination via the broker.
    @schedule while !eof(write_stream) && isopen(net.sock)
        debug("Transfer $(net.id) -> $dest_id")
        data = readavailable(write_stream)
        send(net, dest_id, DATA_TYPE, data)
    end

    return (read_stream, write_stream)
end