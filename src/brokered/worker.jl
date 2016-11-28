function start_worker(id::Integer, cookie::AbstractString)
    #println("start_worker")
    node = Node(id)
    dummy = BrokeredManager(node)  # Needed for use in `connect`
    Base.init_worker(cookie, dummy)

    # Inform the manager that the worker is ready
    send(node, 1, encode(Message(HELLO_MSG, UInt8[])))

    while !eof(node.sock)
        from, data = recv(node)
        msg = decode(data)
        println("WORKER")

        if msg.typ == DATA_MSG
            # Note: To keep compatibility with the underlying ClusterManager implementation we
            # need to have incoming/outgoing streams. Typically these streams are created in
            # `connect` when initiating a connection to a worker but it also needs to be done
            # on the receiving side.
            (read_stream, write_stream) = get!(node.streams, from) do
                println("Establish connection worker $(node.id) -> $from")
                (r_s, w_s) = setup_connection(node, from)
                Base.process_messages(r_s, w_s)
                (r_s, w_s)
            end

            unsafe_write(read_stream, pointer(msg.data), length(msg.data))
        elseif msg.typ == KILL_MSG
            break
        else
            error("Unhandled message type: $(msg.typ)")
        end
    end
end
