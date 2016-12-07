import AWSClusterManagers.OverlayManagers: spawn_local_worker, overlay_id, get_next_overlay_id
import AWSClusterManagers.OverlayManagers.Transport: DEFAULT_HOST, DEFAULT_PORT

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

function spawn_broker(; self_terminate=true)
    # Ensure that broker port is free. Faster than waiting for the spawned process to fail.
    try
        server = listen(DEFAULT_PORT)
        close(server)
    catch
        error("Unable to spawn broker: port $DEFAULT_PORT already in use")
    end

    broker = Base.spawn(`$(Base.julia_cmd()) -e "using AWSClusterManagers.OverlayManagers; start_broker(self_terminate=$self_terminate)"`)

    # Wait until the broker is ready
    # TODO: Find better way of waiting for broker to be connectable
    while process_running(broker)
        try
            sock = connect(DEFAULT_PORT)
            close(sock)
            break
        catch
            sleep(POLL_INTERVAL)
        end
    end

    return broker
end

function spawn_local_worker()
    cookie = Base.cluster_cookie()
    spawn_local_worker(
        overlay_id(get_next_overlay_id(), cookie),
        cookie,
        DEFAULT_HOST,
        DEFAULT_PORT,
    )
end
