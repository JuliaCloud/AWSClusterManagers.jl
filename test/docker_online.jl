@testset "DockerManager (online)" begin
    @testset "docker.sock" begin
        # Make sure that the UNIX socket that the Docker daemon listens to exists.
        # Without this we will be unable to spawn worker containers.
        @test ispath("/var/run/docker.sock")
    end

    @testset "container_id" begin
        container_id = read(```
            docker run
            -i $TEST_IMAGE
            julia -e "using AWSClusterManagers: container_id; print(container_id())"
            ```,
            String
        )

        test_result = @test !isempty(container_id)

        # Display the contents of /proc/self/cgroup from within the Docker container for
        # easy debugging.
        if !(test_result isa Test.Pass)
            cgroup = read(`docker run -i $TEST_IMAGE cat /proc/self/cgroup`, String)
            @info "Contents of /proc/self/cgroup in Docker container environment:\n\n$(cgroup)"
        end
    end

    @testset "image_id" begin
        image_id = read(```
            docker run
            -v /var/run/docker.sock:/var/run/docker.sock
            -i $TEST_IMAGE
            julia -e "using AWSClusterManagers: image_id; print(image_id())"
            ```,
            String
        )

        @test !isempty(image_id)
    end

    @testset "DockerManager" begin
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

        # Run the code in a docker container, but replace the newlines with semi-colons.
        output = read(```
            docker run
            --network=host
            -v /var/run/docker.sock:/var/run/docker.sock
            -i $TEST_IMAGE
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
        @test all(full_image_sha(TEST_IMAGE) .== reported_images)
    end
end
