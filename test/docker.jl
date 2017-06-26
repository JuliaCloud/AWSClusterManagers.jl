@testset "DockerManager" begin
    @testset "Constructors" begin
        @testset "Inner" begin
            mgr = DockerManager(2, "x5cn2a7hzq4k", 600)

            @test mgr.num_workers == 2
            @test mgr.image == "x5cn2a7hzq4k"
            @test mgr.timeout == 600

            @test launch_timeout(mgr) == 600
            @test num_workers(mgr) == (2, 2)
        end
        @testset "Keywords" begin
            mgr = DockerManager(2, image="x5cn2a7hzq4k", timeout=600)

            @test mgr.num_workers == 2
            @test mgr.image == "x5cn2a7hzq4k"
            @test mgr.timeout == 600
        end
        # TODO: mock `container_id` and `image_id`
    end
    @testset "Adding procs" begin
        @testset "Worker Succeeds" begin
            patch = @patch readstring(cmd::AbstractCmd) = TestUtils.readstring(cmd)

            apply(patch) do
                # Get an initial list of processes
                init_procs = procs()
                # Add a single AWSBatchManager worker
                added_procs = addprocs(DockerManager(1, "x5cn2a7hzq4k"))
                # Check that the workers are available
                @test length(added_procs) == 1
                @test procs() == vcat(init_procs, added_procs)
                # Remove the added workers
                rmprocs(added_procs; waitfor=5.0)
                # Double check that rmprocs worked
                @test init_procs == procs()
            end
        end
        @testset "Worker Timeout" begin
            patch = @patch readstring(cmd::AbstractCmd) = TestUtils.readstring(cmd, false)

            apply(patch) do
                @test_throws ErrorException addprocs(DockerManager(1, "x5cn2a7hzq4k", 1.0))
            end
        end
    end
    @testset "Online" begin
        online() do
            num_workers = 3
            image = "292522074875.dkr.ecr.us-east-1.amazonaws.com/$IMAGE_DEFINITION:$REV"

            # docker pull the latest container
            run(Cmd(map(String, split(readchomp(`aws ecr get-login --region us-east-1`)))))
            run(`docker pull $image`)

            code = """
            using Memento
            Memento.config("debug"; fmt="{msg}")
            import AWSClusterManagers: DockerManager
            addprocs(DockerManager($num_workers, "$image"))
            println("NumProcs: ", nprocs())
            for i in workers()
                println("Worker \$i: ", remotecall_fetch(() -> myid(), i))
            end
            """

            # Run the code in a docker container, but
            output = readstring(Cmd([
                "docker",
                "run",
                "--network=host",
                "-v",
                "/var/run/docker.sock:/var/run/docker.sock",
                "-i",
                image,
                "julia",
                "-e",
                replace(code, r"\n+", "; ")
            ]))

            m = match(r"(?<=NumProcs: )\d+", output)
            num_procs = m !== nothing ? parse(Int, m.match) : -1
            reported_jobs = Set(matchall(r"(?<=Worker \d: )[0-9a-f\-]+", output))

            @test num_procs == num_workers + 1
            @test length(reported_jobs) == num_workers
        end
    end
end
