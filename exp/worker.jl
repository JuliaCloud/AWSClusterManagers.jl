import AWSClusterManagers.OverlayManagers: start_worker
import AWSClusterManagers.OverlayManagers.Transport: DEFAULT_HOST, DEFAULT_PORT

start_worker(parse(Int, ARGS[1]), ARGS[2], DEFAULT_HOST, DEFAULT_PORT)

# start_worker(parse(Int, ARGS[1]), ARGS[2], ip"54.174.27.198", DEFAULT_PORT)


# julia -e "println(Base.cluster_cookie()); import AWSClusterManagers.Brokered: BrokeredManager; mgr = BrokeredManager(2, launcher=(i,c) -> nothing); addprocs(mgr)"

#=
julia -e "import AWSClusterManagers.OverlayManagers: start_broker; start_broker()"
julia -e "Base.cluster_cookie(\"demo\"); using AWSClusterManagers; addprocs(LocalOverlayManager(2; broker=(\"127.0.0.1\", 2000), manual_spawn=true))"
julia -e "c = rpad(\"demo\", 16); import AWSClusterManagers.OverlayManagers: start_worker, overlay_id; AWSClusterManagers.start_worker(overlay_id(2, c), c, \"127.0.0.1\", 2000)"
julia -e "c = rpad(\"demo\", 16); import AWSClusterManagers.OverlayManagers: start_worker, overlay_id; AWSClusterManagers.start_worker(overlay_id(3, c), c, \"127.0.0.1\", 2000)"
=#



