# Overview of how the ContainerManagers work:
#
# 1. Start a TCP server on the manager using a random port within the ephemeral range
# 2. Spawn additional jobs/tasks using definition overrides to spawn identical versions of
#    Julia which will connect to the manager over TCP. The Julia function `start_worker` is
#    run which sends the worker address and port to the manager via the TCP socket.
# 3. The manager receives all of the the workers addresses and stops the TCP server.
# 4. Using the reported addresses the manager connects to each of the worker like a typical
#    cluster manager.

# Determine the start of the ephemeral port range on this system. Used in `listenany` calls.
const PORT_HINT = if Sys.islinux()
    parse(Int, first(split(readchomp("/proc/sys/net/ipv4/ip_local_port_range"), '\t')))
elseif Sys.isapple()
    parse(Int, readchomp(`sysctl -n net.inet.ip.portrange.first`))
else
    49152  # IANA dynamic and/or private port range start (https://en.wikipedia.org/wiki/Ephemeral_port)
end

abstract type ContainerManager <: ClusterManager end

"""
    launch_timeout(mgr::ContainerManager) -> Int

The maximum duration (in seconds) a manager will wait for a worker to connect since the
manager initiated the spawning of the worker.
"""
launch_timeout(::ContainerManager)

"""
    desired_workers(mgr::ContainerManager) -> Tuple{Int, Int}

The minimum and maximum number of workers wanted by the manager.
"""
desired_workers(::ContainerManager)

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
end

function launch(manager::ContainerManager, params::Dict, launched::Array, c::Condition)
    min_workers, max_workers = desired_workers(manager)
    launch_tasks = Vector{Task}(undef, max_workers)

    # Determine the IP address of the current host within the specified range
    ips = filter!(getipaddrs()) do ip
        typeof(ip) === typeof(manager.min_ip) &&
        manager.min_ip <= ip <= manager.max_ip
    end
    valid_ip = first(ips)

    # Only listen to the single IP address which the workers attempt to connect to.
    # TODO: Ideally should be using TLS connections.
    port, server = listenany(valid_ip, PORT_HINT)
    debug(logger, "Manager accepting worker connections via: $valid_ip:$port")

    for i in 1:max_workers
        launch_tasks[i] = @async begin
            sock = accept(server)

            # The worker will report it's own address through the socket. Eventually the
            # built in Julia cluster manager code will parse the stream and record the
            # address and port.
            config = WorkerConfig()
            config.io = sock

            # Note: `launched` is treated as a queue and will have elements removed from it
            # periodically.
            push!(launched, config)
            notify(c)
        end
    end

    # Generate command which starts a Julia worker and reports its information back to the
    # manager
    #
    # Typically Julia workers are started using the hidden `julia` flags `--bind-to` and
    # `--worker`. We won't use the `--bind-to` flag as we do not know where the container
    # will be started and what ports will be available. We don't want to use
    # `--worker COOKIE` as this essentially runs `start_worker(STDOUT, COOKIE)` which
    # reports the worker address and port to STDOUT. Instead we'll run the code ourselves
    # and report the connection information back to the manager over a socket.
    exec = """
        using Distributed
        using Sockets
        sock = connect(ip\"$valid_ip\", $port)
        start_worker(sock, \"$(cluster_cookie())\")
        """
    override_cmd = `julia -e $exec`

    # Non-blocking spawn of N-containers where N is equal to `max_workers`. Workers will
    # report back to the manager via the open port we just opened.
    spawn_containers(manager, override_cmd)

    function callback(num_failed)
        num_launched = max_workers - num_failed
        if num_launched >= min_workers
            warn(logger, "Only managed to launch $num_launched/$max_workers workers")
        else
            error("Unable to launch the minimum number of workers")
        end
    end

    # Wait for workers to inform the manager of their address. If all of the spawned
    # containers are not launched by the timeout the `callback` will be executed.
    wait(launch_tasks, launch_timeout(manager), callback)

    # TODO: Does stopping listening terminate the sockets from `accept`? If so, we could
    # potentially close the socket before we know the name of the connected worker. During
    # prototyping this has not been an issue.
    close(server)
    notify(c)
end

function manage(manager::ContainerManager, id::Integer, config::WorkerConfig, op::Symbol)
    # Note: Terminating the TCP connection from the master to the worker will cause the
    # worker to shutdown automatically.
end

# Waits for all of the `tasks` to complete. If we wait longer than the `timeout` the wait is
# aborted and the `timeout_callback` is called with number of unfinished tasks.
function Base.wait(tasks::AbstractArray{Task}, timeout::Period, timeout_callback::Function=n -> nothing)
    timeout_secs = Dates.value(Second(timeout))
    start = time()
    unfinished = 0
    for t in tasks
        while true
            task_done = istaskdone(t)
            timed_out = (time() - start) >= timeout_secs

            if timed_out || task_done
                if timed_out && !task_done
                    unfinished += 1
                end
                break
            end

            sleep(1)
        end
    end
    if unfinished > 0
        timeout_callback(unfinished)
    end
end

# https://github.com/aws/amazon-ecs-agent/issues/1119
# Note: For AWS Batch array jobs the "ecs/<job_id>" does not include the array index
const CGROUP_REGEX = r"/(?:docker|ecs/[0-9a-f\-]{36})/(?<container_id>[0-9a-f]{64})\b"

# Determine the container ID of the currently running container
function container_id()
    id = ""
    isfile("/proc/self/cgroup") || return id
    open("/proc/self/cgroup") do fp
        while !eof(fp)
            line = chomp(readline(fp))
            value = split(line, ':')[3]
            m = match(CGROUP_REGEX, value)
            if m !== nothing
                id = m[:container_id]
                break
            end
        end
    end
    return String(id)
end
