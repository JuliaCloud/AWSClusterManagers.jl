using Sockets: IPAddr, IPv4, IPv6

# Copy of `Sockets._sizeof_uv_interface_address`
const _sizeof_uv_interface_address = ccall(:jl_uv_sizeof_interface_address,Int32,())

# https://github.com/JuliaLang/julia/pull/30349
if VERSION < v"1.2.0-DEV.56"
    using Base: uv_error

    function getipaddrs()
        addresses = IPv4[]
        addr_ref = Ref{Ptr{UInt8}}(C_NULL)
        count_ref = Ref{Int32}(1)
        lo_present = false
        err = ccall(:jl_uv_interface_addresses, Int32, (Ref{Ptr{UInt8}}, Ref{Int32}), addr_ref, count_ref)
        uv_error("getlocalip", err)
        addr, count = addr_ref[], count_ref[]
        for i = 0:(count-1)
            current_addr = addr + i*_sizeof_uv_interface_address
            if 1 == ccall(:jl_uv_interface_address_is_internal, Int32, (Ptr{UInt8},), current_addr)
                lo_present = true
                continue
            end
            sockaddr = ccall(:jl_uv_interface_address_sockaddr, Ptr{Cvoid}, (Ptr{UInt8},), current_addr)
            if ccall(:jl_sockaddr_in_is_ip4, Int32, (Ptr{Cvoid},), sockaddr) == 1
                push!(addresses, IPv4(ntoh(ccall(:jl_sockaddr_host4, UInt32, (Ptr{Cvoid},), sockaddr))))
            end
        end
        ccall(:uv_free_interface_addresses, Cvoid, (Ptr{UInt8}, Int32), addr, count)
        return addresses
    end
else
    using Sockets: getipaddrs
end


"""
    is_link_local(ip::IPv4) -> Bool

Determine if the IP address is within the [link-local address]
(https://en.wikipedia.org/wiki/Link-local_address) block 169.254.0.0/16.
"""
is_link_local(ip::IPv4) = ip"169.254.0.0" <= ip <= ip"169.254.255.255"


# Julia structure mirroring `uv_interface_address_t`
# http://docs.libuv.org/en/v1.x/misc.html#c.uv_interface_address_t
struct InterfaceAddress{T<:IPAddr}
    name::String       # Name of the network interface
    is_internal::Bool  # Interface is a loopback device
    address::T
    # netmask::T  # No accessors available currently
end

# Based upon `getipaddrs` in "stdlib/Sockets/src/addrinfo.jl"
function get_interface_addrs()
    addresses = InterfaceAddress[]
    addr_ref = Ref{Ptr{UInt8}}(C_NULL)
    count_ref = Ref{Int32}(1)
    lo_present = false
    err = ccall(:jl_uv_interface_addresses, Int32, (Ref{Ptr{UInt8}}, Ref{Int32}), addr_ref, count_ref)
    Base.uv_error("getlocalip", err)
    addr, count = addr_ref[], count_ref[]
    for i = 0:(count - 1)
        current_addr = addr + i * _sizeof_uv_interface_address
        # Note: Extracting interface name without a proper accessor
        name = unsafe_string(unsafe_load(Ptr{Cstring}(current_addr)))
        is_internal = ccall(:jl_uv_interface_address_is_internal, Int32, (Ptr{UInt8},), current_addr) == 1
        sockaddr = ccall(:jl_uv_interface_address_sockaddr, Ptr{Cvoid}, (Ptr{UInt8},), current_addr)
        ip = if ccall(:jl_sockaddr_in_is_ip4, Int32, (Ptr{Cvoid},), sockaddr) == 1
            IPv4(ntoh(ccall(:jl_sockaddr_host4, UInt32, (Ptr{Cvoid},), sockaddr)))
        elseif ccall(:jl_sockaddr_in_is_ip6, Int32, (Ptr{Cvoid},), sockaddr) == 1
            addr6 = Ref{UInt128}()
            scope_id = ccall(:jl_sockaddr_host6, UInt32, (Ptr{Cvoid}, Ref{UInt128},), sockaddr, addr6)
            IPv6(ntoh(addr6[]))
        end
        push!(addresses, InterfaceAddress(name, is_internal, ip))
    end
    ccall(:uv_free_interface_addresses, Cvoid, (Ptr{UInt8}, Int32), addr, count)
    return addresses
end


