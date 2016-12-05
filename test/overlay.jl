import AWSClusterManagers.OverlayNetwork: OverlaySocket, OverlayMessage, DEFAULT_HOST, DEFAULT_PORT
import AWSClusterManagers.OverlayCluster: start_broker, OverlayClusterManager, reset_broker_id
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
    broker = spawn(`$(Base.julia_cmd()) -e "using AWSClusterManagers; AWSClusterManagers.OverlayNetwork.start_broker(self_terminate=$self_terminate)"`)

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

function spawn_worker(id, cookie, host=DEFAULT_HOST, port=DEFAULT_PORT)
    spawn(`$(Base.julia_cmd()) -e "using AWSClusterManagers; AWSClusterManagers.OverlayCluster.start_worker($id, \"$cookie\", \"$host\", $port)"`)
end

null_launcher(id, cookie, host, port) = nothing



@testset "encode/decode" begin
    io = IOBuffer()
    write(io, OverlayMessage(1, 2, "hello"))
    seekstart(io)
    msg = read(io, OverlayMessage)

    @test msg.src == 1
    @test msg.dest == 2
    @test String(msg.payload) == "hello"
end

@testset "send to self" begin
    broker = spawn_broker()

    net = OverlaySocket(1)
    msg = OverlayMessage(1, 1, "helloworld!")
    write(net.sock, msg)
    result = read(net.sock, OverlayMessage)

    @test result == msg

    close(net.sock)
    kill(broker); wait(broker)
end

@testset "echo" begin
    broker = spawn_broker()

    @schedule begin
        _net = OverlaySocket(2)
        incoming = read(_net.sock, OverlayMessage)
        outgoing = OverlayMessage(2, incoming.src, "REPLY: $(String(incoming.payload))")
        write(_net.sock, outgoing)
        close(_net.sock)
    end
    yield()

    net = OverlaySocket(1)
    msg = OverlayMessage(1, 2, "helloworld!")
    write(net.sock, msg)
    result = read(net.sock, OverlayMessage)

    @test result.src == 2
    @test result.dest == 1
    @test String(result.payload) == "REPLY: helloworld!"

    close(net.sock)
    kill(broker); wait(broker)
end


@testset "all-to-all" begin
    reset_next_pid()
    broker = spawn_broker()

    # Add two workers which will connect to each other
    @test workers() == [1]
    added = addprocs(OverlayClusterManager(2, launcher=spawn_worker))
    @test added == [2, 3]

    # Each worker can talk to each other worker
    @test remotecall_fetch(myid, 2) == 2
    @test remotecall_fetch(myid, 3) == 3
    @test remotecall_fetch(() -> remotecall_fetch(myid, 1), 2) == 1
    @test remotecall_fetch(() -> remotecall_fetch(myid, 3), 2) == 3
    @test remotecall_fetch(() -> remotecall_fetch(myid, 1), 3) == 1
    @test remotecall_fetch(() -> remotecall_fetch(myid, 2), 3) == 2

    # Remove the two workers
    rmprocs(added...)
    @test workers() == [1]

    kill(broker); wait(broker)
end

@testset "broker abrupt shutdown" begin
    reset_next_pid()
    broker = spawn_broker()

    mgr = OverlayClusterManager(2, launcher=null_launcher)

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

    wait(broker)
    wait(worker_a)
    wait(worker_b)

    @test process_exited(worker_a)
    @test process_exited(worker_b)
    @test workers() == [1]
end

@testset "worker abrupt shutdown" begin
    reset_next_pid()
    broker = spawn_broker()

    mgr = OverlayClusterManager(2, launcher=null_launcher)

    # Add workers manually so that we have access to their processes
    launch = @schedule addprocs(mgr)
    worker_a = spawn_worker(2, Base.cluster_cookie())
    worker_b = spawn_worker(3, Base.cluster_cookie())
    wait(launch)  # will complete once the workers have connected to the manager

    @test workers() == [2, 3]

    # Cause an abrupt shutdown of a worker. Will cause the following error(s) to occur:
    # "ERROR (unhandled task failure): EOFError: read end of file"
    assert(process_running(worker_a))  # Ensure we can actually kill the worker
    kill(worker_a)
    wait(worker_a)
    yield()

    # Broker informs all nodes of the deregistration which the manager uses to get notified
    # @test workers() == [3]
    @test remotecall_fetch(myid, 3) == 3
    @test_throws ProcessExitedException remotecall_fetch(myid, 2)
    @test workers() == [3]

    kill(broker); wait(broker)
end

# TODO: Determine why this test is stalling
@testset "manager abrupt shutdown" begin
    reset_next_pid()
    broker = spawn_broker()
    cookie = Base.cluster_cookie()

    # Spawn a manager which will wait for workers then terminate without having the chance
    # to send the KILL message to workers. Note: We need to set the cluster_cookie on the
    # manager process so that it accepts our workers.
    manager = spawn(`$(Base.julia_cmd()) -e "Base.cluster_cookie(\"$cookie\"); using AWSClusterManagers; mgr = OverlayClusterManager(2, launcher=(id, cookie, host, port) -> nothing); addprocs(mgr); close(mgr.network.sock)"`)

    # TODO: Test that workers are running

    # Add workers manually so that we have access to their processes
    worker_a = spawn_worker(2, cookie)
    worker_b = spawn_worker(3, cookie)
    wait(manager)  # manager process has terminated

    # TODO: A failure will cause use to wait indefinitely...
    wait(worker_a)
    wait(worker_b)

    kill(broker); wait(broker)
end

# During development there were issues with empty messages causing infinite loops. This test
# should reproduce the problem but hasn't demonstrated the issue yet.
# @testset "empty" begin
#     reset_next_pid()
#     broker = spawn_broker()

#     # Add two workers which will connect to each other
#     mgr = OverlayClusterManager(1, launcher=spawn_worker)
#     addprocs(mgr)

#     r_s, w_s = first(values(mgr.network.streams))  # Access the read/write streams for the added worker
#     write(w_s, UInt8[])
#     yield()

#     kill(broker)
# end

@testset "add/remove" begin
    reset_next_pid()
    broker = spawn_broker()

    added = addprocs(OverlayClusterManager(2, launcher=spawn_worker))
    @test workers() == [2, 3]

    rmprocs(3); yield()
    @test workers() == [2]

    added = addprocs(OverlayClusterManager(1, launcher=spawn_worker))
    @test workers() == [2, 4]

    rmprocs(2, 4)
    kill(broker); wait(broker)
end

# @testset "brokerless" begin
#     reset_next_pid()
#     added = addprocs(OverlayClusterManager(1, launcher=spawn_worker))
# end
