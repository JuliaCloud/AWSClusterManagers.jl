import AWSClusterManagers.OverlayManagers: LocalOverlayManager, worker_launched

@testset "all-to-all" begin
    reset_next_pid()
    broker = spawn_broker()

    # Add two workers which will connect to each other
    @test workers() == [1]
    added = addprocs(LocalOverlayManager(2))
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

    mgr = LocalOverlayManager(2, manual_spawn=true)

    # Add workers manually so that we have access to their processes
    launch = @schedule addprocs(mgr)
    worker_a = spawn_local_worker()
    worker_b = spawn_local_worker()
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

    mgr = LocalOverlayManager(2, manual_spawn=true)

    # Add workers manually so that we have access to their processes
    launch = @schedule addprocs(mgr)

    # Manually launch workers individually to ensure they start with the expected pid.
    worker_a = spawn_local_worker()  # Needs to launch with pid 2
    wait(worker_launched)
    worker_b = spawn_local_worker()  # Needs to launch with pid 3
    wait(launch)  # will complete once the workers have connected to the manager

    @test workers() == [2, 3]

    # Cause an abrupt shutdown of a worker. Will cause the following error(s) to occur:
    # "ERROR (unhandled task failure): EOFError: read end of file"
    assert(process_running(worker_a))  # Ensure we can actually kill the worker
    kill(worker_a)
    wait(worker_a)

    # When a node abruptly shuts down the broker informs all nodes of the deregistration.
    # An asynchronous task on the manager will receive this message and cleanup the killed
    # worker. It could take a little bit of time for the broker to send this message and
    # for the manager to receive it.
    slept = 0.0
    while length(workers()) > 1 && slept < 10
        sleep(POLL_INTERVAL)
        slept += POLL_INTERVAL
    end

    @test workers() == [3]
    @test remotecall_fetch(myid, 3) == 3
    @test_throws ProcessExitedException remotecall_fetch(myid, 2) == 2

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
    manager = spawn(`$(Base.julia_cmd()) -e "Base.cluster_cookie(\"$cookie\"); using AWSClusterManagers; mgr = LocalOverlayManager(2, manual_spawn=true); addprocs(mgr); close(mgr.network.sock)"`)

    # TODO: Test that workers are running

    # Add workers manually so that we have access to their processes
    worker_a = spawn_local_worker(2, cookie)
    worker_b = spawn_local_worker(3, cookie)
    wait(manager)  # manager process has terminated

    # TODO: A failure will cause use to wait indefinitely...
    wait(worker_a)
    wait(worker_b)

    kill(broker); wait(broker)
end

@testset "multiple clusters" begin
    reset_next_pid()
    broker = spawn_broker()

    # Ensure that the two clusters use seperate cookies
    primary_cookie = Base.cluster_cookie()
    secondary_cookie = randstring(16)
    @test primary_cookie != secondary_cookie

    # Spawn a secondary Julia cluster in a seperate process which uses the same broker.
    # We'll second messages continuously in this cluster to simulate real work.
    code = """
    Base.cluster_cookie("$secondary_cookie")
    using AWSClusterManagers
    addprocs(LocalOverlayManager(1))
    @everywhere secondary() = Base.cluster_cookie()
    while true
        assert(remotecall_fetch(secondary, 2) == Base.cluster_cookie())
        sleep(0.1)
    end
    """
    secondary_cluster = spawn(`$(Base.julia_cmd()) -e $code`)

    # TODO: It would be best if we could talk to the broker to see if the second cluster
    # is up and running
    sleep(2)
    @test process_running(secondary_cluster)

    # Spawn the primary cluster
    added = addprocs(LocalOverlayManager(1))
    @everywhere primary() = Base.cluster_cookie()

    @test workers() == [2]
    @test remotecall_fetch(primary, 2) == primary_cookie

    rmprocs(added...)
    @test workers() == [1]


    @test process_running(secondary_cluster)
    kill(secondary_cluster)

    kill(broker); wait(broker)
end
