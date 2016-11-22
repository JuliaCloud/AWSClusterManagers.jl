module AWSClusterManagers

export launch, manage
import Base: launch, manage, cluster_cookie

# Determine the start of the ephemeral port range on this system. Used in `listenany` calls.
const PORT_HINT = if is_linux()
    parse(Int, first(split(readchomp("/proc/sys/net/ipv4/ip_local_port_range"), '\t')))
elseif is_apple()
    parse(Int, readstring(`sysctl -n net.inet.ip.portrange.first`))
else
    49152  # IANA dynamic or private port range start
end

# include("container.jl")
# include("ecs.jl")
# include("docker.jl")
# include("zeromq/ZeroMQ.jl")
include("brokered/Brokered.jl")

end # module
