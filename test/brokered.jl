import AWSClusterManagers.Brokered: encode, decode, Node, start_broker

@testset "encoding" begin
    io = IOBuffer()
    encode(io, 1, 2, "hello")
    seekstart(io)
    src_id, dest_id, message = decode(io)

    @test src_id == 1
    @test dest_id == 2
    @test message == "hello"
end

@testset "send to self" begin
    broker_task = @schedule start_broker()
    yield()

    node = Node(1)
    encode(node.sock, 1, 1, "helloworld!")
    src_id, dest_id, message = decode(node.sock)

    @test src_id == 1
    @test dest_id == 1
    @test message == "helloworld!"

    close(node.sock)
    wait(broker_task)
end

@testset "echo" begin
    broker_task = @schedule start_broker()
    yield()

    @schedule begin
        node_b = Node(2)
        src_id, dest_id, msg = decode(node_b.sock)
        encode(node_b.sock, 2, src_id, "REPLY: $msg")
        close(node_b.sock)
    end
    yield()

    node_a = Node(1)

    println("TEST: Sending message")
    encode(node_a.sock, 1, 2, "helloworld!")
    println("TEST: Awaiting response")
    src_id, dest_id, message = decode(node_a.sock)
    println("BROKER 1: $src_id, $dest_id, $message")

    @test src_id == 2
    @test dest_id == 1
    @test message == "REPLY: helloworld!"

    close(node_a.sock)
    wait(broker_task)
end
