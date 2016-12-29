import AWSClusterManagers.OverlayManagers: spawn_local_worker, overlay_id, get_next_overlay_id
import AWSClusterManagers.OverlayManagers.Transport: DEFAULT_HOST

const POLL_INTERVAL = 0.2

# Override the `get_next_pid` function such that we can reset the PID to appear that we're
# running in a new Julia session. Assists in test case maintainence as without this we would
# have to keep incrementing worker ID values.
let next_pid = 2    # 1 is reserved for the client (always)
    global get_next_pid
    function get_next_pid()
        pid = next_pid
        next_pid += 1
        pid
    end

    global reset_next_pid
    function reset_next_pid()
        next_pid = 2
        empty!(Base.map_del_wrkr)
        nothing
    end
end
Base.get_next_pid() = get_next_pid()

type Broker
    process::Base.Process
    host::IPAddr
    port::Integer
end

Base.kill(b::Broker) = kill(b.process)
Base.wait(b::Broker) = wait(b.process)
Base.process_running(b::Broker) = process_running(b.process)
address(b::Broker) = (b.host, b.port)

function spawn_broker(port=-1; self_terminate=true)
    host = ip"127.0.0.1"

    # Ensure that broker port is free. Faster than waiting for the spawned process to fail.
    if port >= 0
        try
            server = listen(port)
            close(server)
        catch
            error("Unable to spawn broker: port $port already in use")
        end
    end

    code = """
    using AWSClusterManagers.OverlayManagers
    start_broker(ip\"$host\", $port, self_terminate=$self_terminate)
    """

    io, process = open(pipeline(detach(`$(Base.julia_cmd()) -e $code`), stderr=DevNull))
    line = readline(io)

    # Determine the host and port from the broker logs. Note: we need to specify a hostname
    # otherwise we could get a generic address like "[::]".
    m = match(r"(?<host>\S+):(?<port>\d+)$", line)
    broker = Broker(process, IPv4(m[:host]), parse(Int, m[:port]))

    # Wait until the broker is ready
    # TODO: Find better way of waiting for broker to be connectable
    while process_running(broker.process)
        info("waiting")
        try
            sock = connect(broker.host, broker.port)
            close(sock)
            break
        catch
            sleep(POLL_INTERVAL)
        end
    end

    return broker
end

function spawn_local_worker(broker::Broker)
    cookie = Base.cluster_cookie()
    spawn_local_worker(
        overlay_id(get_next_overlay_id(), cookie),
        cookie,
        broker.host,
        broker.port,
    )
end
