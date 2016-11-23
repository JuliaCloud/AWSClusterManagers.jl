import AWSClusterManagers.Brokered: encode, decode, Broker, start_broker

io = IOBuffer()
encode(io, 1, 2, "hello")
seekstart(io)
src_id, dest_id, message = decode(io)

@test src_id == 1
@test dest_id == 2
@test message == "hello"

broker_task = @schedule start_broker()
yield()
sleep(5)

# Send a message to yourself
# broker = Broker(1)
# encode(broker.sock, 1, 1, "helloworld!")
# src_id, dest_id, message = decode(broker.sock)

# @test src_id == 1
# @test dest_id == 1
# @test message == "helloworld!"

# echo a single query then terminates
echo_task = @schedule begin
    broker = Broker(2)
    src_id, dest_id, msg = decode(broker.sock)
    println("BROKER 2: $src_id, $dest_id, $message")
    encode(broker.sock, 2, src_id, "REPLY: $msg")
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
