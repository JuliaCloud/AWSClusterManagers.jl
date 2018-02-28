@testset "container_id" begin
    @testset "docker regex" begin
        container_id = "26c927d78b3a0ac080354a74649d61cec26c3064426f6173b242356e75a324e3"
        cgroup = """
            13:name=systemd:/docker-ce/docker/$container_id
            12:pids:/docker-ce/docker/$container_id
            11:hugetlb:/docker-ce/docker/$container_id
            10:net_prio:/docker-ce/docker/$container_id
            9:perf_event:/docker-ce/docker/$container_id
            8:net_cls:/docker-ce/docker/$container_id
            7:freezer:/docker-ce/docker/$container_id
            6:devices:/docker-ce/docker/$container_id
            5:memory:/docker-ce/docker/$container_id
            4:blkio:/docker-ce/docker/$container_id
            3:cpuacct:/docker-ce/docker/$container_id
            2:cpu:/docker-ce/docker/$container_id
            1:cpuset:/docker-ce/docker/$container_id
            """

        m = match(AWSClusterManagers.CGROUP_REGEX, cgroup)
        @test m !== nothing
        @test m["container_id"] == container_id
    end

    @testset "batch regex" begin
        job_id = "69d95a04-d313-4530-bee5-a65def33a303"
        container_id = "e799b9182976f8298065419945d32a4398f1280e616199448729f5b72b8e81ef"
        cgroup = """
            9:perf_event:/ecs/$job_id/$container_id
            8:memory:/ecs/$job_id/$container_id
            7:hugetlb:/ecs/$job_id/$container_id
            6:freezer:/ecs/$job_id/$container_id
            5:devices:/ecs/$job_id/$container_id
            4:cpuset:/ecs/$job_id/$container_id
            3:cpuacct:/ecs/$job_id/$container_id
            2:cpu:/ecs/$job_id/$container_id
            1:blkio:/ecs/$job_id/$container_id
            """

        m = match(AWSClusterManagers.CGROUP_REGEX, cgroup)
        @test m !== nothing
        @test m["container_id"] == container_id
    end
end
