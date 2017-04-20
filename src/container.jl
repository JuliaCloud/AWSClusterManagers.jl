import Base: wait

# Determine the start of the ephemeral port range on this system. Used in `listenany` calls.
const PORT_HINT = if is_linux()
    parse(Int, first(split(readchomp("/proc/sys/net/ipv4/ip_local_port_range"), '\t')))
elseif is_apple()
    parse(Int, readstring(`sysctl -n net.inet.ip.portrange.first`))
else
    49152  # IANA dynamic or private port range start
end

const DEFAULT_TIMEOUT = 300

abstract ContainerManager <: ClusterManager

launch_timeout(manager::ContainerManager) = DEFAULT_TIMEOUT

function launch(manager::ContainerManager, params::Dict, launched::Array, c::Condition)
    min_workers, max_workers = num_workers(manager)
    launch_tasks = Vector{Task}(max_workers)

    # TODO: Should be using TLS connections.
    port, server = listenany(ip"::", PORT_HINT)  # Listen on all IPv4 and IPv6 interfaces
    for i in 1:max_workers
        launch_tasks[i] = @schedule begin
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
    exec = "sock = connect(ip\"$(getipaddr())\", $port); Base.start_worker(sock, \"$(cluster_cookie())\")"
    override_cmd = `julia -e $exec`

    # Starts "max_workers" containers. Non-blocking.
    start_containers(manager, override_cmd)

    function callback(num_failed)
        num_launched = max_workers - num_failed
        if num_launched >= min_workers
            warn("Only managed to launch $num_launched/$max_workers workers")
        else
            error("Unable to launch the minimum number of workers")
        end
    end

    # Await for workers to inform the manager of their address.
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

function wait(tasks::AbstractArray{Task}, timeout::Real, timed_out_cb::Function=(n)->nothing)
    start = time()
    unfinished = 0
    for t in tasks
        while true
            task_done = istaskdone(t)
            timed_out = (time() - start) >= timeout

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
        timed_out_cb(unfinished)
    end
end
