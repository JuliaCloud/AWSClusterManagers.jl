import AWSClusterManagers.Brokered: encode, decode, Node, start_broker, BrokeredManager

@testset "encoding" begin
    io = IOBuffer()
    encode(io, 1, 2, "hello")
    seekstart(io)
    src_id, dest_id, message = decode(io, String)

    @test src_id == 1
    @test dest_id == 2
    @test message == "hello"
end

@testset "send to self" begin
    broker_task = @schedule start_broker()
    yield()

    node = Node(1)
    encode(node.sock, 1, 1, "helloworld!")
    src_id, dest_id, message = decode(node.sock, String)

    @test src_id == 1
    @test dest_id == 1
    @test message == "helloworld!"

    close(node.sock)
    wait(broker_task)
end

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

spawn_broker() = spawn(`$(Base.julia_cmd()) -e "using AWSClusterManagers; AWSClusterManagers.Brokered.start_broker()"`)
function spawn_worker(id, cookie=Base.cluster_cookie())
    spawn(`$(Base.julia_cmd()) -e "using AWSClusterManagers; AWSClusterManagers.Brokered.start_worker($id, \"$cookie\")"`)
end


# @testset "real" begin
    broker = spawn_broker()
    sleep(5)
    worker_processes = [spawn_worker(2), spawn_worker(3)]
    sleep(5)

    added = addprocs(BrokeredManager(2))
    @test added == [2, 3]

    map(rmprocs, added)

    # sleep(5)

    println("kill processes")
    kill(broker)
    map(kill, worker_processes)
    # sleep(5)

    @test workers() == [1]

    println("Julia shutdown")
# end




# Tests to make
# - `addprocs(BrokeredManager(2))`
#   Multiple workers start in an all-to-all
# - `rmprocs`
#   Sends an empty message which has been problematic in the past
# - `rmprocs(X); addprocs(1)`
#   Remove the last worker then add a worker. Could cause issues on the other remaining workers
