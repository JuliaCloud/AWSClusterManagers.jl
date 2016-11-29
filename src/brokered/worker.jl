function start_worker(id::Integer, cookie::AbstractString)
    #println("start_worker")
    node = Node(id)
    dummy = BrokeredManager(node)  # Needed for use in `connect`
    Base.init_worker(cookie, dummy)

    # Inform the manager that the worker is ready
    send(node, 1, HELLO_TYPE)

    while !eof(node.sock)
        msg = recv(node)
        from = msg.src

        if msg == UNREACHABLE_TYPE
            debug("Receive UNREACHABLE from $from")
            (r_s, w_s) = pop!(node.streams, from)
            close(r_s)
            close(w_s)
        elseif msg.typ == DATA_TYPE
            debug("Receive DATA from $from")

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

            unsafe_write(read_stream, pointer(msg.payload), length(msg.payload))
        elseif msg.typ == KILL_TYPE
            debug("Receive KILL from $from")
            break
        else
            error("Unhandled message type: $(msg.typ)")
        end
    end
end
