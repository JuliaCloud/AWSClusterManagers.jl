import Base: Semaphore, acquire, release

type BrokeredNode
    sock::TCPSocket
    read_access::Semaphore
    write_access::Semaphore
    BrokeredNode(sock::TCPSocket) = new(sock, Semaphore(1), Semaphore(1))
end

function start_broker(port::Integer=2000)
    mapping = Dict{UInt32,BrokeredNode}()

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


        println("Awaiting outbound data from $sock_id")
        while !eof(sock)
            println("resuming $(object_id(sock))")
            src = mapping[sock_id]
            println("New data from $sock_id ($(object_id(src.sock)))")

            acquire(src.read_access)
            src_id, dest_id, message = decode(src.sock)
            release(src.read_access)
            println("$src_id, $dest_id, $message")

            # assert(src_id == sock_id)


            dest = mapping[dest_id]
            if isopen(dest.sock)
                println("Passing message along to $dest_id ($(object_id(dest.sock)))")
                acquire(dest.write_access)
                encode(dest.sock, src_id, dest_id, message)
                release(dest.write_access)
                println("Message transferred")
            end
        end

        println("Deregistered: $sock_id")
        delete!(mapping, sock_id)
    end

    initializing = true
    server = listen(port)
    try
        while initializing || !isempty(mapping)
            if initializing && !isempty(mapping)
                initializing = false
            end

            # TODO: Find way of timing out the broker if there are no sockets connecting to it.
            sock = accept(server)

            # Note: Using a function here instead of a block as it seems to solve the issue
            # with duplicate sockets.
            @async process(sock)
        end
        println("Shutting broker down")
    finally
        close(server)
    end
end

function process(sock::TCPSocket)

end