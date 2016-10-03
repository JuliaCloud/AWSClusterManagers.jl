@test ECSManager(2, "def") == ECSManager(2, 2, "def", "def", "", "")
@test ECSManager(2, 4, "def") == ECSManager(2, 4, "def", "def", "", "")
@test ECSManager(2:4, "def") == ECSManager(2, 4, "def", "def", "", "")

# Test expect to run within an ECS container
if success(`curl --silent --connect-timeout 5 http://169.254.169.254`)
    ecs = ECSManager(2, "julia-baked", cluster="ETS", region="us-east-1", task_name="julia")

    addprocs(ecs)
    manager_ip = getipaddr()
    worker_ip_a = remotecall_fetch(getipaddr, 1)
    worker_ip_b = remotecall_fetch(getipaddr, 2)

    @test manager_ip != worker_ip_a
    @test manager_ip != worker_ip_b
else
    info("Skipping ECS container test")
end
