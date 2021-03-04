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
        job_id = "69d95a04d3134530bee5a65def33a303"
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

    @testset "GitHub Actions regex" begin
        container_id = "cf0888f8246174f11a08a07911abd5993da1e2f7b0e28103cc5799fe486debee"
        cgroup = """
            12:hugetlb:/actions_job/$container_id
            11:blkio:/actions_job/$container_id
            10:rdma:/
            9:perf_event:/actions_job/$container_id
            8:freezer:/actions_job/$container_id
            7:devices:/actions_job/$container_id
            6:net_cls,net_prio:/actions_job/$container_id
            5:memory:/actions_job/$container_id
            4:pids:/actions_job/$container_id
            3:cpu,cpuacct:/actions_job/$container_id
            2:cpuset:/actions_job/$container_id
            1:name=systemd:/actions_job/$container_id
            0::/system.slice/containerd.service
            """

        m = match(AWSClusterManagers.CGROUP_REGEX, cgroup)
        @test m !== nothing
        @test m["container_id"] == container_id
    end
end
