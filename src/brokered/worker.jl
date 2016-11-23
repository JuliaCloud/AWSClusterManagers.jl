function start_worker(id::Integer, cookie::AbstractString)
    #println("start_worker")
    node = Node(id)
    dummy = BrokeredManager(0, Nullable{Node}())  # Attempting to track how this is used in a worker
    Base.init_worker(cookie, dummy)

    while true
        from, data = recv(node)
        println("WORKER")

        (read_stream, write_stream) = get!(node.streams, from) do
            println("Estabilishing new connection WORKER")
            # Setup I/O streams which will process cluster communications
            (r_s, w_s) = setup_connection(node, from)
            Base.process_messages(r_s, w_s)
            (r_s, w_s)
        end

        unsafe_write(read_stream, pointer(data), length(data))
    end
end
