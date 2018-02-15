@testset "DockerManager" begin
    # A docker image name which is expected to not exist on the local system.
    mock_image = "x5cn2a7hzq4k"

    @testset "Constructors" begin
        @testset "Inner" begin
            mgr = DockerManager(2, mock_image, 600)

            @test mgr.num_workers == 2
            @test mgr.image == mock_image
            @test mgr.timeout == 600

            @test launch_timeout(mgr) == 600
            @test num_workers(mgr) == (2, 2)
        end
        @testset "Keywords" begin
            mgr = DockerManager(2, image=mock_image, timeout=600)

            @test mgr.num_workers == 2
            @test mgr.image == mock_image
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
                added_procs = addprocs(DockerManager(1, mock_image))
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

            @test_throws ErrorException apply(patch) do
                # Suppress "unhandled task error" message
                # https://github.com/JuliaLang/julia/issues/12403
                ignore_stderr() do
                    addprocs(DockerManager(1, mock_image, 1.0))
                end
            end
        end
    end
    @testset "Online" begin
        online() do
            docker_build(ECR_IMAGE)

            num_workers = 3
            code = """
            using Memento
            Memento.config("debug"; fmt="{msg}")
            using AWSClusterManagers: DockerManager
            setlevel!(getlogger(AWSClusterManagers), "debug")
            addprocs(DockerManager($num_workers))
            println("NumProcs: ", nprocs())
            @everywhere using AWSClusterManagers: container_id
            for i in workers()
                println("Worker \$i: ", remotecall_fetch(() -> container_id(), i))
            end
            """

            # Run the code in a docker container, but
            output = readstring(`
                docker run
                --network=host
                -v /var/run/docker.sock:/var/run/docker.sock
                -i $ECR_IMAGE
                julia -e $(replace(code, r"\n+", "; "))
                `
            )

            m = match(r"(?<=NumProcs: )\d+", output)
            num_procs = m !== nothing ? parse(Int, m.match) : -1

            # Spawned is the list container IDs reported by the manager upon launch while
            # reported is the self-reported container ID of each worker.
            spawned_ids = Set(matchall(r"(?<=Spawning container: )[0-9a-f\-]+", output))
            reported_ids = Set(matchall(r"(?<=Worker \d: )[0-9a-f\-]+", output))

            @test num_procs == num_workers + 1
            @test length(reported_ids) == num_workers
            @test spawned_ids == reported_ids
        end
    end
end
