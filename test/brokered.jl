import AWSClusterManagers.Brokered: encode, decode, Broker, start_broker

io = IOBuffer()
encode(io, 1, 2, "hello")
seekstart(io)
src_id, dest_id, message = decode(io)

@test src_id == 1
@test dest_id == 2
@test message == "hello"



broker_task = @schedule start_broker()

# worker1_task @schedule begin
#     sleep(2)
#     broker = Broker(1)
#     src_id, dest_id, msg = decode(broker.sock)
#     encode(broker.sock, 1, src_id, "REPLY: $msg")
# end

# sleep(5)

# broker = Broker(2)
# encode(broker.sock, 2, 1, "helloworld!")
# println("Awaiting decode")
# src_id, dest_id, message = decode(broker.sock)

# @test src_id == 1
# @test dest_id == 2
# @test message == "REPLY: helloworld!"


sleep(5)

broker = Broker(1)
encode(broker.sock, 1, 1, "helloworld!")
