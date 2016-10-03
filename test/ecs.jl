# Test expect to run within an ECS container
ecs = ECSClusterManager(2, "julia-baked", cluster="ETS", region="us-east-1")

addprocs(ecs)
manager_ip = getipaddr()
worker_ip_a = remotecall_fetch(getipaddr, 1)
worker_ip_b = remotecall_fetch(getipaddr, 2)

@test manager_ip != worker_ip_a
@test manager_ip != worker_ip_b
