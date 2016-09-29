module AWSClusterManagers

export launch, manage
import Base: launch, manage, cluster_cookie

const PORT_HINT = if is_linux()
    parse(Int, first(split(readchomp("/proc/sys/net/ipv4/ip_local_port_range"), '\t')))
elseif is_apple()
    parse(Int, readstring(`sysctl -n net.inet.ip.portrange.first`))
else
    49152  # IANA dynamic or private port range start
end

include("ecs.jl")

end # module
