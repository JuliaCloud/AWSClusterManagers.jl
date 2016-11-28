import AWSClusterManagers.Brokered: encode, decode, Node, start_broker, BrokeredManager, reset_broker_id

# Override the `get_next_pid` function such that we can reset the PID to appear that we're
# running in a new Julia session. Assists in test case maintainence as without this we would
# have to keep incrementing worker ID values.
let next_pid = 2    # 1 is reserved for the client (always)
    global get_next_pid
    function get_next_pid()
        pid = next_pid
        next_pid += 1
        pid
    end

    global reset_next_pid
    function reset_next_pid()
        next_pid = 2
        empty!(Base.map_del_wrkr)
        nothing
    end
end
Base.get_next_pid() = get_next_pid()

@testset "encoding" begin
    io = IOBuffer()
    encode(io, 1, 2, "hello")
    seekstart(io)
    src_id, dest_id, message = decode(io, String)

    @test src_id == 1
    @test dest_id == 2
    @test message == "hello"
end

# @testset "send to self" begin
#     broker_task = @schedule start_broker()
#     yield()

#     node = Node(1)
#     encode(node.sock, 1, 1, "helloworld!")
#     src_id, dest_id, message = decode(node.sock, String)

#     @test src_id == 1
#     @test dest_id == 1
#     @test message == "helloworld!"

#     close(node.sock)
#     wait(broker_task)
# end

# @testset "echo" begin
#     broker_task = @schedule start_broker()
#     yield()

#     @schedule begin
#         node_b = Node(2)
#         src_id, dest_id, msg = decode(node_b.sock, String)
#         encode(node_b.sock, 2, src_id, "REPLY: $msg")
#         close(node_b.sock)
#     end
#     yield()

#     node_a = Node(1)
#     encode(node_a.sock, 1, 2, "helloworld!")
#     src_id, dest_id, message = decode(node_a.sock, String)

#     @test src_id == 2
#     @test dest_id == 1
#     @test message == "REPLY: helloworld!"

#     close(node_a.sock)
#     wait(broker_task)
# end

function spawn_broker(; self_terminate=true)
    broker = spawn(`$(Base.julia_cmd()) -e "using AWSClusterManagers; AWSClusterManagers.Brokered.start_broker(self_terminate=$self_terminate)"`)

    # Wait until the broker is ready
    # TODO: Find better way of waiting for broker to be connectable
    while true
        try
            sock = connect(2000)
            close(sock)
            break
        catch
            sleep(0.2)
        end
    end

    return broker
end

function spawn_worker(id, cookie=Base.cluster_cookie())
    spawn(`$(Base.julia_cmd()) -e "using AWSClusterManagers; AWSClusterManagers.Brokered.start_worker($id, \"$cookie\")"`)
end


@testset "all-to-all" begin
    broker = spawn_broker()

    # Add two workers which will connect to each other
    added = addprocs(BrokeredManager(2, launcher=spawn_worker))
    @test added == [2, 3]

    # Each node can talk to each other node
    @test remotecall_fetch(myid, 2) == 2
    @test remotecall_fetch(myid, 3) == 3
    @test remotecall_fetch(() -> remotecall_fetch(myid, 1), 2) == 1
    @test remotecall_fetch(() -> remotecall_fetch(myid, 3), 2) == 3
    @test remotecall_fetch(() -> remotecall_fetch(myid, 1), 3) == 1
    @test remotecall_fetch(() -> remotecall_fetch(myid, 2), 3) == 2

    # Remove the two workers
    map(rmprocs, added)
    @test workers() == [1]  # TODO: Wrong?

    kill(broker)
end

# @testset "empty" begin
#     broker = spawn_broker()

#     # Add two workers which will connect to each other
#     mgr = BrokeredManager(1, launcher=spawn_worker)
#     addprocs(mgr)

#     r_s, w_s = mgr.node.streams[2]  # Access the read/write streams for node 2
#     write(w_s, UInt8[])
#     yield()

#     sleep(5)

#     kill(broker)
# end

@testset "add and remove" begin
    reset_next_pid()
    broker = spawn_broker(self_terminate=false)

    added = addprocs(BrokeredManager(2, launcher=spawn_worker))
    @test workers() == [2, 3]

    rmprocs(3)
    sleep(2)
    @test workers() == [2]

    added = addprocs(BrokeredManager(1, launcher=spawn_worker))
    @test workers() == [2, 4]

    kill(broker)
end


# Tests to make
# - `addprocs(BrokeredManager(2))`
#   Multiple workers start in an all-to-all
# - `rmprocs`
#   Sends an empty message which has been problematic in the past
# - `rmprocs(X); addprocs(1)`
#   Remove the last worker then add a worker. Could cause issues on the other remaining workers
# - launch without the broker
# - clean shutdown
