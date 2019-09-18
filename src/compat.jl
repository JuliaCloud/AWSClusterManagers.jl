# https://github.com/JuliaLang/julia/pull/30349
if VERSION < v"1.2.0-DEV.56"
    using Base: uv_error
    using Sockets: _sizeof_uv_interface_address, IPv4

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
