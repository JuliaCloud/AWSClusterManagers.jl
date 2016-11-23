function start_worker(id::Integer, cookie::AbstractString)
    #println("start_worker")
    node = Node(id)
    Base.init_worker(cookie, BrokeredManager(node))

    while true
        from, data = recv(node)

        (read_stream, write_stream) = get!(node.streams, from) do
            # Setup I/O streams which will process cluster communications
            (r_s, w_s) = setup_connection(node, from)
            Base.process_messages(r_s, w_s)
            (r_s, w_s)
        end

        unsafe_write(read_stream, pointer(data), length(data))
    end
end
