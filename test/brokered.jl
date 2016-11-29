import AWSClusterManagers.Brokered: encode, decode, Node, start_broker, BrokeredManager, reset_broker_id, OverlayMessage, DATA
import Lumberjack: remove_truck

remove_truck("console")  # Disable logging

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


@testset "encode/decode" begin
    io = IOBuffer()
    write(io, OverlayMessage(1, 2, DATA, "hello"))
    seekstart(io)
    msg = read(io, OverlayMessage)

    @test msg.src == 1
    @test msg.dest == 2
    @test msg.typ == DATA
    @test String(msg.body) == "hello"
end

@testset "send to self" begin
    broker = spawn_broker()

    node = Node(1)
    msg = OverlayMessage(1, 1, DATA, "helloworld!")
    write(node.sock, msg)
    result = read(node.sock, OverlayMessage)

    @test result == msg

    close(node.sock)
    kill(broker)
end

@testset "echo" begin
    broker = spawn_broker()

    @schedule begin
        node_b = Node(2)
        incoming = read(node_b.sock, OverlayMessage)
        outgoing = OverlayMessage(2, incoming.src, DATA, "REPLY: $(String(incoming.body))")
        write(node_b.sock, outgoing)
        close(node_b.sock)
    end
    yield()

    node_a = Node(1)
    msg = OverlayMessage(1, 2, DATA, "helloworld!")
    write(node_a.sock, msg)
    result = read(node_a.sock, OverlayMessage)

    @test result.src == 2
    @test result.dest == 1
    @test String(result.body) == "REPLY: helloworld!"

    close(node_a.sock)
    kill(broker)
end


@testset "all-to-all" begin
    reset_next_pid()
    broker = spawn_broker()

    # Add two workers which will connect to each other
    @test workers() == [1]
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
    rmprocs(added...)
    @test workers() == [1]

    kill(broker)
end

@testset "broker shutdown" begin
    reset_next_pid()
    broker = spawn_broker()

    mgr = BrokeredManager(2, launcher=(id, cookie) -> nothing)

    # Add workers manually so that we have access to their processes
    launch = @schedule addprocs(mgr)
    worker_a = spawn_worker(2, Base.cluster_cookie())
    worker_b = spawn_worker(3, Base.cluster_cookie())
    wait(launch)  # will complete once the workers have connected to the manager

    @test workers() == [2, 3]

    # Cause an abrupt shutdown of the broker. Will cause the following error(s) to occur:
    # "ERROR (unhandled task failure): EOFError: read end of file"
    assert(process_running(broker))  # Ensure we can actually kill the broker
    kill(broker)

    wait(worker_a)
    wait(worker_b)
    @test process_exited(worker_a)
    @test process_exited(worker_b)
    @test workers() == [1]
end

# During development there were issues with empty messages causing infinite loops. This test
# should reproduce the problem but hasn't demonstrated the issue yet.
# @testset "empty" begin
#     reset_next_pid()
#     broker = spawn_broker()

#     # Add two workers which will connect to each other
#     mgr = BrokeredManager(1, launcher=spawn_worker)
#     addprocs(mgr)

#     r_s, w_s = first(values(mgr.node.streams))  # Access the read/write streams for the added worker
#     write(w_s, UInt8[])
#     yield()

#     kill(broker)
# end

@testset "add/remove" begin
    reset_next_pid()
    broker = spawn_broker()

    added = addprocs(BrokeredManager(2, launcher=spawn_worker))
    @test workers() == [2, 3]

    rmprocs(3); yield()
    @test workers() == [2]

    added = addprocs(BrokeredManager(1, launcher=spawn_worker))
    @test workers() == [2, 4]

    rmprocs(2, 4)
    kill(broker)
end

# @testset "brokerless" begin
#     reset_next_pid()
#     added = addprocs(BrokeredManager(1, launcher=spawn_worker))
# end
