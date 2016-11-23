import AWSClusterManagers.Brokered: encode, decode, Broker, start_broker

@testset "encoding" begin
    io = IOBuffer()
    encode(io, 1, 2, "hello")
    seekstart(io)
    src_id, dest_id, message = decode(io)

    @test src_id == 1
    @test dest_id == 2
    @test message == "hello"
end

# @testset "send to self" begin
#     broker_task = @schedule start_broker()
#     yield()

#     broker = Broker(1)
#     encode(broker.sock, 1, 1, "helloworld!")
#     src_id, dest_id, message = decode(broker.sock)

#     @test src_id == 1
#     @test dest_id == 1
#     @test message == "helloworld!"

#     close(broker.sock)
#     wait(broker_task)
# end

@testset "echo" begin
    broker_task = @schedule start_broker()
    yield()

    @schedule begin
        broker = Broker(2)
        src_id, dest_id, msg = decode(broker.sock)
        encode(broker.sock, 2, src_id, "REPLY: $msg")
        # close(broker.sock)
        sleep(5)
    end
    yield()

    broker = Broker(1)

    println("TEST: Sending message")
    encode(broker.sock, 1, 2, "helloworld!")
    println("TEST: Awaiting response")
    src_id, dest_id, message = decode(broker.sock)
    println("BROKER 1: $src_id, $dest_id, $message")

    @test src_id == 2
    @test dest_id == 1
    @test message == "REPLY: helloworld!"

    # close(broker.sock)
    # wait(broker_task)
end
