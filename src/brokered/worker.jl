function start_worker(id::Integer, cookie::AbstractString)
    #println("start_worker")
    node = Node(id)
    dummy = BrokeredManager(id, node)  # Needed for use in `connect`
    Base.init_worker(cookie, dummy)

    while true
        from, data = recv(node)
        println("WORKER")

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

        unsafe_write(read_stream, pointer(data), length(data))
    end
end
