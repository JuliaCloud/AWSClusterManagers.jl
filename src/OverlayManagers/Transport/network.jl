import Base: Semaphore, send, recv, close

const DEFAULT_HOST = ip"127.0.0.1"
const DEFAULT_PORT = 2000

type OverlayNetwork
    oid::OverlayID
    sock::TCPSocket
    read_access::Semaphore
    write_access::Semaphore
    streams::Dict{OverlayID,Tuple{IO,IO}}
    broker_host::Union{IPAddr,String}
    broker_port::Int
end

function OverlayNetwork(oid::Integer, broker=DEFAULT_HOST, port::Integer=DEFAULT_PORT)
    sock = connect(broker, port)

    # Trying this to keep the connection open while data needs to be send
    # Base.disable_nagle(sock)
    # Base.wait_connected(sock)

    write(sock, UInt128(oid))  # Register
    response = read(sock, OverlayMessage)

    if response.typ != REGISTER_SUCCESS
        error("Unable to register")
    end

    return OverlayNetwork(
        oid,
        sock,
        Semaphore(1),
        Semaphore(1),
        Dict{OverlayID,Tuple{IO,IO}}(),
        broker,
        port,
    )
end

function close(net::OverlayNetwork)
    for (read_stream, write_stream) in values(net.streams)
        close(read_stream)
        close(write_stream)
    end

    close(net.sock)
end

function send(net::OverlayNetwork, dest::Integer, typ::Integer, content)
    msg = OverlayMessage(net.oid, dest, typ, content)

    # By the time we acquire the lock the socket may have been closed.
    acquire(net.write_access)
    isopen(net.sock) && write(net.sock, msg)
    release(net.write_access)
end

send(net::OverlayNetwork, dest::Integer, typ::Integer) = send(net, dest, typ, UInt8[])

function recv(net::OverlayNetwork)
    acquire(net.read_access)
    msg = read(net.sock, OverlayMessage)
    release(net.read_access)

    return msg
end

function setup_connection(net::OverlayNetwork, dest::Integer)
    # read indicates data from the remote source to be processed by the current node
    # while write indicates data to be sent to the remote source
    read_stream = BufferStream()
    write_stream = BufferStream()

    net.streams[dest] = (read_stream, write_stream)

    # Transfer all data written to the write stream to the destination via the broker.
    @schedule while !eof(write_stream) && isopen(net.sock)
        debug("Transfer $(net.oid) -> $dest")
        data = readavailable(write_stream)
        send(net, dest, DATA_TYPE, data)
    end

    return (read_stream, write_stream)
end
