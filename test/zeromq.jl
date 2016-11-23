broker = spawn(`julia -e "using AWSClusterManagers; AWSClusterManagers.ZeroMQ.Broker.start_broker()"`)
info("Broker started")

try
    AWSClusterManagers.ZeroMQ.Manager.start_master(4)
    info("Workers started")

    # Have worker 2 get information from worker 3
    @test remotecall_fetch(() -> remotecall_fetch(myid, 3), 2) == 3
finally
    rmprocs(workers()...; waitfor=5.0)
    kill(broker)
end