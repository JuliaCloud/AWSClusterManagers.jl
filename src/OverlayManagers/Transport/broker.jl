import Base: Semaphore, acquire, release

const BROKER_ID = UInt128(0)

type BrokeredNode
    sock::TCPSocket
    read_access::Semaphore
    write_access::Semaphore
    BrokeredNode(sock::TCPSocket) = new(sock, Semaphore(1), Semaphore(1))
end

function start_broker(host::IPAddr=ip"::", port::Integer=DEFAULT_PORT; self_terminate=false)
    mapping = Dict{OverlayID,BrokeredNode}()
    server = listen(host, port)
    info("Starting broker server on $(getipaddr()):$port")

    function process(sock)
        # `@async` can act strangely sometimes where the same socket can get accidentally
        # mapped to different identifiers.
        for mapped_sock in values(mapping)
            if mapped_sock == sock
                error("duplicate socket detected")
            end
        end

        # Registration should happen before the async block otherwise we could associate
        # an ID with the wrong socket.
        if !eof(sock)
            sock_id = read(sock, OverlayID)
            info("Register: $sock_id")

            src = BrokeredNode(sock)
            if sock_id != BROKER_ID && !haskey(mapping, sock_id)
                mapping[sock_id] = src
                registered = true
            else
                warn("attempted to register an ID already in use: $sock_id")
                registered = false
            end

            msg = OverlayMessage(BROKER_ID, sock_id, registered ? REGISTER_SUCCESS : REGISTER_FAIL, [])

            acquire(src.write_access)
            isopen(src.sock) && write(src.sock, msg)
            release(src.write_access)

            if !registered
                close(sock)
                return
            end
        else
            warn("socket closed before registration")
            return
        end

        # println("Awaiting outbound data from $sock_id")
        while !eof(sock)
            src = mapping[sock_id]

            acquire(src.read_access)
            msg = read(src.sock, OverlayMessage)
            release(src.read_access)
            src_id, dest_id, typ = header(msg)
            debug("IN:      $src_id -> $dest_id ($typ)")

            # The reported source ID should match the registered ID for the socket
            assert(src_id == sock_id)

            # Determine if the destination can have messages sent to it
            reachable = haskey(mapping, dest_id)
            if reachable
                dest = mapping[dest_id]
                reachable = isopen(dest.sock)
            end

            if reachable
                debug("OUT:     $src_id -> $dest_id")
                acquire(dest.write_access)
                write(dest.sock, msg)
                release(dest.write_access)
            else
                debug("UNREACH: $src_id -> $dest_id")

                msg = OverlayMessage(dest_id, src_id, UNREACHABLE_TYPE, [])
                acquire(src.write_access)
                isopen(src.sock) && write(src.sock, msg)
                release(src.write_access)
            end
        end

        info("Deregister: $sock_id")
        delete!(mapping, sock_id)

        # When a node de-registers inform all other nodes of the change.
        # Note: Could result in unecessary message traffic when using multiple clusters on
        # on the same broker.
        for (dest_id, dest) in mapping
            msg = OverlayMessage(sock_id, dest_id, UNREACHABLE_TYPE, [])
            acquire(dest.write_access)
            isopen(dest.sock) && write(dest.sock, msg)
            release(dest.write_access)
        end

        # Shutdown the server when all connections have terminated.
        # Note: I would prefer to throw an exception but it doesn't get caught by the loop
        if isempty(mapping) && self_terminate
            info("All connections terminated. Shutting down broker")
            close(server)
        end
    end

    try
        while true
            sock = accept(server)

            # Note: Using a function here instead of a block as it seems to solve the issue
            # with duplicate sockets.
            @async process(sock)
        end
    catch e
        # Closing the server causes `accept` to throw UVError
        if !isa(e, Base.UVError)
            rethrow()
        end
    finally
        close(server)
    end
end
