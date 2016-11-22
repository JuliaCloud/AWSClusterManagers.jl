module Broker

using ZMQ

const BROKER_SUB_PORT = 8100
const BROKER_PUB_PORT = 8101

# BROKER
function start_broker()
    ctx=Context()
    xpub=Socket(ctx, XPUB)
    xsub=Socket(ctx, XSUB)

    ZMQ.bind(xsub, "tcp://127.0.0.1:$(BROKER_SUB_PORT)")
    ZMQ.bind(xpub, "tcp://127.0.0.1:$(BROKER_PUB_PORT)")

    ccall((:zmq_proxy, :libzmq), Cint,  (Ptr{Void}, Ptr{Void}, Ptr{Void}), xsub.data, xpub.data, C_NULL)
#    proxy(xsub, xpub)

    # control never comes here
    ZMQ.close(xpub)
    ZMQ.close(xsub)
    ZMQ.close(ctx)
end

end
