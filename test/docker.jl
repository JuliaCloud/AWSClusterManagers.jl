using JSON
# Return the long image SHA256 identifier using various ways of referencing images
function full_image_sha(image::AbstractString)
    json = JSON.parse(read(`docker inspect $image`, String))
    return last(split(json[1]["Id"], ':'))
end

@testset "DockerManager" begin
    # A docker image name which is expected to not exist on the local system.
    mock_image = "x5cn2a7hzq4k"

    @testset "Constructors" begin
        @testset "Inner" begin
            mgr = DockerManager(2, mock_image, Minute(10))

            @test mgr.num_workers == 2
            @test mgr.image == mock_image
            @test mgr.timeout == Minute(10)

            @test launch_timeout(mgr) == Minute(10)
            @test desired_workers(mgr) == (2, 2)
        end

        @testset "Keywords" begin
            mgr = DockerManager(2, image=mock_image, timeout=Minute(10))

            @test mgr.num_workers == 2
            @test mgr.image == mock_image
            @test mgr.timeout == Minute(10)
        end

        @testset "Zero Workers" begin
            mgr = DockerManager(0, image=mock_image, timeout=Minute(10))
            @test mgr.num_workers == 0
        end

        @testset "Defaults" begin
            patch = @patch image_id() = mock_image

            apply(patch) do
                mgr = DockerManager(3)

                @test mgr.num_workers == 3
                @test mgr.image == mock_image
                @test mgr.timeout == AWSClusterManagers.DOCKER_TIMEOUT

                @test launch_timeout(mgr) == AWSClusterManagers.DOCKER_TIMEOUT
                @test desired_workers(mgr) == (3, 3)

                @test mgr == DockerManager(3)
            end
        end

        # TODO: mock `container_id` and `image_id`
    end
    @testset "Adding procs" begin
        @testset "Worker Succeeds" begin
            patch = @patch read(cmd::AbstractCmd, String) = TestUtils.read(cmd, String)

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
            patch = @patch read(cmd::AbstractCmd, String) = TestUtils.read(cmd, String, false)

            @test_throws ErrorException apply(patch) do
                # Suppress "unhandled task error" message
                # https://github.com/JuliaLang/julia/issues/12403
                ignore_stderr() do
                    addprocs(DockerManager(1, mock_image, Second(1)))
                end
            end
        end
    end
    if "docker" in ONLINE
        @testset "Online" begin
            image_name = docker_manager_build()

            # Note: Julia packages used here must be explicitly added to the environment
            # within the Dockerfile.
            num_workers = 3
            code = """
                using AWSClusterManagers: AWSClusterManagers, DockerManager
                using Distributed
                using Memento

                Memento.config!("debug"; fmt="{msg}")
                setlevel!(getlogger(AWSClusterManagers), "debug")

                addprocs(DockerManager($num_workers))
                println("NumProcs: ", nprocs())

                @everywhere using AWSClusterManagers: container_id
                for i in workers()
                    container = remotecall_fetch(container_id, i)
                    println("Worker container \$i: \$container")
                    println("Worker image \$i: \$(AWSClusterManagers.image_id(container))")
                end
                """

            # Make sure that the UNIX socket that the Docker daemon listens to exists.
            # Without this we will be unable to spawn worker containers.
            @test ispath("/var/run/docker.sock")

            # Run the code in a docker container, but replace the newlines with semi-colons.
            output = read(```
                docker run
                --network=host
                -v /var/run/docker.sock:/var/run/docker.sock
                -i $image_name
                julia -e $(replace(code, r"\n+" => "; "))
                ```,
                String
            )

            m = match(r"(?<=NumProcs: )\d+", output)
            num_procs = m !== nothing ? parse(Int, m.match) : -1

            # Spawned is the list container IDs reported by the manager upon launch while
            # reported is the self-reported container ID of each worker.
            spawned_containers = map(m -> m.match, eachmatch(r"(?<=Spawning container: )[0-9a-f\-]+", output))
            reported_containers = map(m -> m.match, eachmatch(r"(?<=Worker container \d: )[0-9a-f\-]+", output))
            reported_images = map(m -> m.match, eachmatch(r"(?<=Worker image \d: )[0-9a-f\-]+", output))

            @test num_procs == num_workers + 1
            @test length(reported_containers) == num_workers
            @test Set(spawned_containers) == Set(reported_containers)
            @test all(full_image_sha(image_name) .== reported_images)
        end
    else
        warn(logger, "Environment variable \"ONLINE\" does not contain \"docker\". Skipping online Docker tests.")
    end
end
