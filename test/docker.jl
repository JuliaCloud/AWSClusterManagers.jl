using JSON

# Return the long image SHA256 identifier using various ways of referencing images
function full_image_sha(image::AbstractString)
    json = JSON.parse(read(`docker inspect $image`, String))
    return last(split(json[1]["Id"], ':'))
end

const DOCKER_SPAWN_REGEX = r"^Spawning container: [0-9a-z]{12}$"

@testset "DockerManager" begin
    # A docker image name which is expected to not exist on the local system.
    mock_image = "x5cn2a7hzq4k"

    @testset "constructors" begin
        @testset "inner" begin
            mgr = DockerManager(2, mock_image, Minute(10), ip"1.0.0.0", ip"2.0.0.0")

            # Validate that no additional fields were added without the tests being updated
            @test fieldcount(DockerManager) == 5

            @test mgr.num_workers == 2
            @test mgr.image == mock_image
            @test mgr.timeout == Minute(10)
            @test mgr.min_ip == ip"1.0.0.0"
            @test mgr.max_ip == ip"2.0.0.0"

            @test launch_timeout(mgr) == Minute(10)
            @test desired_workers(mgr) == (2, 2)
        end

        @testset "keywords" begin
            mgr = DockerManager(
                3;
                image=mock_image,
                timeout=Minute(12),
                min_ip=ip"3.0.0.0",
                max_ip=ip"4.0.0.0",
            )

            @test mgr.num_workers == 3
            @test mgr.image == mock_image
            @test mgr.timeout == Minute(12)
            @test mgr.min_ip == ip"3.0.0.0"
            @test mgr.max_ip == ip"4.0.0.0"
        end

        @testset "defaults" begin
            patch = @patch AWSClusterManagers.image_id() = mock_image

            apply(patch) do
                mgr = DockerManager(0)

                @test mgr.num_workers == 0
                @test mgr.image == mock_image
                @test mgr.timeout == AWSClusterManagers.DOCKER_TIMEOUT
                @test mgr.min_ip == ip"0.0.0.0"
                @test mgr.max_ip == ip"255.255.255.255"
            end
        end

        @testset "num workers" begin
            # Define keywords which are required to avoid mocking
            kwargs = Dict(:image => mock_image)

            @test_throws ArgumentError DockerManager(-1; kwargs...)
            @test desired_workers(DockerManager(0; kwargs...)) == (0, 0)
            @test desired_workers(DockerManager(2; kwargs...)) == (2, 2)

            # Note: DockerManager does not support ranges
            @test_throws MethodError DockerManager(1, 2; kwargs...)
            @test_throws MethodError DockerManager(3:4; kwargs...)
        end
    end

    @testset "equality" begin
        patch = @patch AWSClusterManagers.image_id() = mock_image

        apply(patch) do
            @test DockerManager(3) == DockerManager(3)
        end
    end

    @testset "addprocs" begin
        @testset "success" begin
            patch = @patch function read(cmd::AbstractCmd, ::Type{String})
                # Extract original `override_command` using image position:
                # "docker run [OPTIONS] IMAGE [COMMAND] [ARG...]"
                i = findfirst(isequal(mock_image), collect(cmd))
                override_cmd = Cmd(cmd[(i + 1):end])
                @async run(override_cmd)
                return "000000000001"
            end

            apply(patch) do
                # Get an initial list of processes
                init_procs = procs()
                # Add a single AWSBatchManager worker
                added_procs = @test_log LOGGER "notice" DOCKER_SPAWN_REGEX begin
                    addprocs(DockerManager(1, mock_image))
                end
                # Check that the workers are available
                @test length(added_procs) == 1
                @test procs() == vcat(init_procs, added_procs)
                # Remove the added workers
                rmprocs(added_procs; waitfor=5.0)
                # Double check that rmprocs worked
                @test init_procs == procs()
            end
        end

        @testset "worker timeout" begin
            patch = @patch function read(cmd::AbstractCmd, ::Type{String})
                # Avoiding spawning a worker process
                return "000000000002"
            end

            @test_throws TaskFailedException apply(patch) do
                @test_log LOGGER "notice" DOCKER_SPAWN_REGEX begin
                    addprocs(DockerManager(1, mock_image, Second(1)))
                end
            end
        end
    end
end
