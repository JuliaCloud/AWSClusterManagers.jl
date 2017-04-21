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
    addprocs(LocalOverlayManager(1, broker=$(address(broker))))
    @everywhere secondary() = Base.cluster_cookie()
    # assert(remotecall_fetch(secondary, 2) == Base.cluster_cookie())
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
    added = addprocs(LocalOverlayManager(1, broker=address(broker)))
    @everywhere primary() = Base.cluster_cookie()

    @test workers() == [2]
    @test remotecall_fetch(primary, 2) == primary_cookie

    rmprocs(added...)
    @test workers() == [1]


    @test process_running(secondary_cluster)
    kill(secondary_cluster)

    kill(broker); wait(broker)
end
