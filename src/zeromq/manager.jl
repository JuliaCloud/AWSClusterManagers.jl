module Manager

import AWSClusterManagers.ZeroMQ.Common: ZMQNode, init_node, recv_data, manager

# MASTER
function start_master(np)
    node = ZMQNode(0)
    init_node(node)
    @schedule begin
        try
            while true
                (from_zid, data) = recv_data()

                #println("master recv data from $from_zid")

                (r_s, w_s, t_r) = manager.map_zmq_julia[from_zid]
                unsafe_write(r_s, pointer(data), length(data))
            end
        catch e
            Base.show_backtrace(STDOUT,catch_backtrace())
            println(e)
            rethrow(e)
        end
    end

    addprocs(manager; np=np)
end


end
