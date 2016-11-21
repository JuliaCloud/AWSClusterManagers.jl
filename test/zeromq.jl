broker = spawn(`julia -e "using AWSClusterManagers; AWSClusterManagers.start_broker()"`)

try
    AWSClusterManagers.start_master(4)

    # Have worker 2 get information from worker 3
    @test remotecall_fetch(() -> remotecall_fetch(myid, 3), 2) == 3
finally
    rmprocs(workers()...; waitfor=5.0)
    kill(broker)
end
