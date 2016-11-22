import Base: Semaphore, acquire, release

type BrokeredNode
    sock::TCPSocket
    semaphore::Semaphore
    BrokeredNode(sock::TCPSocket) = new(sock, Semaphore(1))
end

function start_broker(port::Integer=2000)
    mapping = Dict{UInt32,BrokeredNode}()
    server = listen(port)
    while true
        # TODO: Find way of timing out the broker if there are no sockets connecting to it.
        sock = accept(server)

        # Initial connection map the ID to the socket
        src_id = read(sock, UInt32)
        println("Registered: $src_id")
        mapping[src_id] = BrokeredNode(sock)

        @async begin
            println("Awaiting incoming data from $src_id")
            while isopen(sock) && !eof(sock)
                node = mapping[src_id]
                println("New data from $src_id")

                acquire(node.semaphore)
                src_id, dest_id, message = decode(sock)
                release(node.semaphore)
                println("$src_id, $dest_id, $message")

                println("Sending message to $dest_id")
                node = mapping[dest_id]
                acquire(node.semaphore)
                encode(node.sock, src_id, dest_id, message)
                release(node.semaphore)
                println("Message transferred")
            end

            println("Deregistered: $src_id")
            delete!(mapping, src_id)
        end
    end
end
