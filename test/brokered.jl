import AWSClusterManagers.Brokered: encode, decode, Broker, start_broker

io = IOBuffer()
encode(io, 1, 2, "hello")
seekstart(io)
src_id, dest_id, message = decode(io)

@test src_id == 1
@test dest_id == 2
@test message == "hello"

@schedule start_broker()
yield()

# Send a message to yourself
broker = Broker(1)
encode(broker.sock, 1, 1, "helloworld!")
src_id, dest_id, message = decode(broker.sock)

@test src_id == 1
@test dest_id == 1
@test message == "helloworld!"

# echo a single query then terminates
@schedule begin
    broker = Broker(2)
    src_id, dest_id, msg = decode(broker.sock)
    encode(broker.sock, 2, src_id, "REPLY: $msg")
end
yield()

encode(broker.sock, 1, 2, "helloworld!")
# println("Awaiting decode")
src_id, dest_id, message = decode(broker.sock)

@test src_id == 2
@test dest_id == 1
@test message == "REPLY: helloworld!"
