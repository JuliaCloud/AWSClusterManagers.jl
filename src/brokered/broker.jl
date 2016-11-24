import Base: Semaphore, acquire, release

type BrokeredNode
    sock::TCPSocket
    read_access::Semaphore
    write_access::Semaphore
    BrokeredNode(sock::TCPSocket) = new(sock, Semaphore(1), Semaphore(1))
end

function start_broker(port::Integer=2000)
    mapping = Dict{UInt32,BrokeredNode}()
    server = listen(port)

    function process(sock)
        # Registration should happen before the async block otherwise we could associate
        # an ID with the wrong socket.
        sock_id = read(sock, UInt32)
        println("Registered: $sock_id")
        mapping[sock_id] = BrokeredNode(sock)

        k = collect(keys(mapping))
        n = length(k)
        for i = 1:n - 1, j = i + 1:n
            if mapping[k[i]].sock == mapping[k[j]].sock
                error("duplicate socket detected")
            end
        end

        for (k, v) in mapping
            println("$k: $v, $(object_id(v.sock))")
        end


        count = 50
        # println("Awaiting outbound data from $sock_id")
        while !eof(sock) && count > 0
            src = mapping[sock_id]
            println("New data from $sock_id ($(object_id(src.sock)))")

            acquire(src.read_access)
            src_id, dest_id, message = decode(src.sock)
            release(src.read_access)
            println("$(now()) IN:   $src_id -> $dest_id")

            assert(src_id == sock_id)

            if haskey(mapping, dest_id)
                dest = mapping[dest_id]
            else
                println("discarding")
                continue
            end

            if isopen(dest.sock)
                println("$(now()) OUT:  $src_id -> $dest_id")
                acquire(dest.write_access)
                encode(dest.sock, src_id, dest_id, message)
                release(dest.write_access)
            else
                println("discarding")
            end

            count -= 1
            if !(count > 0)
                println("COUNT SAFE GUARD")
            end
        end

        println("Deregistered: $sock_id")
        delete!(mapping, sock_id)

        # Shutdown the server when all connections have terminated.
        # Note: I would prefer to throw an exception but it doesn't get caught by the loop
        if isempty(mapping)
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

function process(sock::TCPSocket)

end
