module Worker

import AWSClusterManagers.ZeroMQ.Common: Node, recv, ZMQManager
import AWSClusterManagers.ZeroMQ.Common: setup_connection, REMOTE_INITIATED

# WORKER
function start_worker(zid::Integer, cookie::AbstractString)
    #println("start_worker")
    node = Node(zid)
    Base.init_worker(cookie, ZMQManager(node))


    while true
        (from_zid, data) = recv(node)

        #println("worker recv data from $from_zid")

        streams = get(node.mapping, from_zid, nothing)
        if streams === nothing
            # First time..
            (r_s, w_s) = setup_connection(node, from_zid, REMOTE_INITIATED)
            Base.process_messages(r_s, w_s)
        else
            (r_s, w_s, t_r) = streams
        end

        unsafe_write(r_s, pointer(data), length(data))
    end
end

function start_worker(zid::AbstractString, cookie::AbstractString)
    start_worker(parse(Int, zid), cookie)
end

end