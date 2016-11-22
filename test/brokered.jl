import AWSClusterManagers.Brokered: encode, decode, Broker, start_broker

io = IOBuffer()
encode(io, 1, 2, "hello")
seekstart(io)
src_id, dest_id, message = decode(io)

@test src_id == 1
@test dest_id == 2
@test message == "hello"


broker_process = spawn(pipeline(`$(Base.julia_cmd()) -e "using AWSClusterManagers; AWSClusterManagers.Brokered.start_broker()"`, stdout=STDOUT))


# Send a message to yourself
broker = Broker(1)
encode(broker.sock, 1, 1, "helloworld!")
src_id, dest_id, message = decode(broker.sock)

@test src_id == 1
@test dest_id == 1
@test message == "helloworld!"

println("echo server")

echo_process = spawn(`$(Base.julia_cmd()) -e "import AWSClusterManagers.Brokered: Broker, decode, encode; broker = Broker(2); while true; src_id, dest_id, msg = decode(broker.sock), encode(broker.sock, 2, src_id, \"REPLY:\" * msg); end"`)

# echo_process = @schedule begin
#     broker = Broker(2)
#     src_id, dest_id, msg = decode(broker.sock)
#     encode(broker.sock, 2, src_id, "REPLY: $msg")
# end

encode(broker.sock, 1, 2, "helloworld!")
# println("Awaiting decode")
src_id, dest_id, message = decode(broker.sock)

@test src_id == 1
@test dest_id == 2
@test message == "REPLY: helloworld!"
