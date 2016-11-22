module Manager

import AWSClusterManagers.ZeroMQ.Common: ZMQManager, Node, recv

# MASTER
function start_master(np)
    node = Node(0)
    @schedule begin
        try
            while true
                (from_zid, data) = recv(node)

                #println("master recv data from $from_zid")

                (r_s, w_s, t_r) = node.mapping[from_zid]
                unsafe_write(r_s, pointer(data), length(data))
            end
        catch e
            Base.show_backtrace(STDOUT,catch_backtrace())
            println(e)
            rethrow(e)
        end
    end

    manager = ZMQManager(node)
    addprocs(manager; np=np)
end


end
