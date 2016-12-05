type LocalOverlayManager <: OverlayClusterManager
    np::Int
    network::OverlayNetwork
    manual_spawn::Bool
end

function LocalOverlayManager(np::Integer; broker::Tuple{Any,Integer}=(DEFAULT_HOST, DEFAULT_PORT), manual_spawn::Bool=false)
    host, port = isa(broker, AbstractString) ? (broker, DEFAULT_PORT) : broker
    LocalOverlayManager(Int(np), OverlayNetwork(1, host, port), manual_spawn)
end

num_processes(mgr::LocalOverlayManager) = mgr.np

function spawn(mgr::LocalOverlayManager, id::Integer)
    if !mgr.manual_spawn
        cookie = Base.cluster_cookie()
        host = mgr.network.broker_host
        port = mgr.network.broker_port
        spawn_local_worker(id, cookie, host, port)
    end
end

function spawn_local_worker(id, cookie, host=DEFAULT_HOST, port=DEFAULT_PORT)
    Base.spawn(`$(Base.julia_cmd()) -e "using AWSClusterManagers.OverlayManagers; start_worker($id, \"$cookie\", \"$host\", $port)"`)
end
