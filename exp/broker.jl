import AWSClusterManagers.OverlayManagers: start_broker
start_broker()

# julia -e "println(Base.cluster_cookie()); using AWSClusterManagers.Brokered; addprocs(BrokeredManager(2, launcher=(i,c) -> nothing))"
