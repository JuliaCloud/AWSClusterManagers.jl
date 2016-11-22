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
                # Initial connection map the ID to the socket
                src_id = read(sock, UInt32)
                println("Registered: $src_id")
                mapping[src_id] = BrokeredNode(sock)

                println("Awaiting incoming data from $src_id")
                while isopen(sock) && !eof(sock)
                    src = mapping[src_id]
                    println("New data from $src_id")

                    acquire(src.read_access)
                    src_id, dest_id, message = decode(src.sock)
                    release(src.read_access)
                    println("$src_id, $dest_id, $message")

                    println("Sending message to $dest_id")
                    dest = mapping[dest_id]
                    acquire(dest.write_access)
                    encode(dest.sock, src_id, dest_id, message)
                    release(dest.write_access)
                    println("Message transferred")
                end

                println("Deregistered: $src_id")
                delete!(mapping, src_id)
            end
        end
    finally
        close(server)
    end
end
