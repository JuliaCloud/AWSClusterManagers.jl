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
    try
        while true
            # TODO: Find way of timing out the broker if there are no sockets connecting to it.
            sock = accept(server)

            @async begin
                # Registration should happen before the async block otherwise we could associate
                # an ID with the wrong socket.
                sock_id = read(sock, UInt32)
                println("Registered: $sock_id")
                mapping[sock_id] = BrokeredNode(sock)

                k = collect(keys(mapping))
                println("KEYS: $k")
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

                    assert(src_id == sock_id)

                    println("Passing message along to $dest_id")
                    dest = mapping[dest_id]
                    acquire(dest.write_access)
                    encode(dest.sock, src_id, dest_id, message)
                    release(dest.write_access)
                    println("Message transferred")
                end

                println("Deregistered: $sock_id")
                delete!(mapping, sock_id)
            end
        end
    finally
        close(server)
    end
end
