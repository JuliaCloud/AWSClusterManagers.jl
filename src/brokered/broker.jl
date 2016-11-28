import Base: Semaphore, acquire, release

type BrokeredNode
    sock::TCPSocket
    read_access::Semaphore
    write_access::Semaphore
    BrokeredNode(sock::TCPSocket) = new(sock, Semaphore(1), Semaphore(1))
end

function start_broker(port::Integer=2000; self_terminate=false)
    mapping = Dict{UInt128,BrokeredNode}()
    server = listen(port)

    function process(sock)
        # Registration should happen before the async block otherwise we could associate
        # an ID with the wrong socket.
        sock_id = read(sock, UInt128)
        info("Register: $sock_id")
        mapping[sock_id] = BrokeredNode(sock)

        # `@async` can act strangely sometimes where the same socket can get accidentally
        # mapped to different identifiers.
        k = collect(keys(mapping))
        n = length(k)
        for i = 1:n - 1, j = i + 1:n
            if mapping[k[i]].sock === mapping[k[j]].sock
                error("duplicate socket detected")
            end
        end

        # println("Awaiting outbound data from $sock_id")
        while !eof(sock)
            src = mapping[sock_id]

            acquire(src.read_access)
            src_id, dest_id, message = decode(src.sock)
            release(src.read_access)
            debug("IN:      $src_id -> $dest_id ($(length(message)))")

            # The reported source ID should match the registered ID for the socket
            assert(src_id == sock_id)

            if haskey(mapping, dest_id)
                dest = mapping[dest_id]
            else
                debug("DISCARD: $src_id -> $dest_id")
                continue
            end

            if isopen(dest.sock)
                debug("OUT:     $src_id -> $dest_id")
                acquire(dest.write_access)
                encode(dest.sock, src_id, dest_id, message)
                release(dest.write_access)
            else
                debug("TERM:    $src_id -> $dest_id")
            end
        end

        info("Deregister: $sock_id")
        delete!(mapping, sock_id)

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
