const BATCH_SPAWN_REGEX = r"Spawning (array )?job: (?<id>[0-9a-f\-]+)(?(1) \(n=(?<n>\d+)\))"

# Test inner constructor
@testset "AWSBatchManager" begin
    @testset "constructors" begin
        @testset "inner" begin
            mgr = AWSBatchManager(
                1,
                2,
                "job-definition",
                "job-name",
                "job-queue",
                1000,
                "us-east-2",
                Minute(10),
                ip"1.0.0.0",
                ip"2.0.0.0",
            )

            # Validate that no additional fields were added without the tests being updated
            @test fieldcount(AWSBatchManager) == 10

            @test mgr.min_workers == 1
            @test mgr.max_workers == 2
            @test mgr.job_definition == "job-definition"
            @test mgr.job_name == "job-name"
            @test mgr.job_queue == "job-queue"
            @test mgr.job_memory == 1000
            @test mgr.region == "us-east-2"
            @test mgr.timeout == Minute(10)
            @test mgr.min_ip == ip"1.0.0.0"
            @test mgr.max_ip == ip"2.0.0.0"

            @test launch_timeout(mgr) == Minute(10)
            @test desired_workers(mgr) == (1, 2)
        end

        @testset "keywords" begin
            mgr = AWSBatchManager(
                3,
                4;
                definition="keyword-def",
                name="keyword-name",
                queue="keyword-queue",
                memory=1000,
                region="us-west-1",
                timeout=Second(5),
                min_ip=ip"3.0.0.0",
                max_ip=ip"4.0.0.0",
            )

            @test mgr.min_workers == 3
            @test mgr.max_workers == 4
            @test mgr.job_definition == "keyword-def"
            @test mgr.job_name == "keyword-name"
            @test mgr.job_queue == "keyword-queue"
            @test mgr.job_memory == 1000
            @test mgr.region == "us-west-1"
            @test mgr.timeout == Second(5)
            @test mgr.min_ip == ip"3.0.0.0"
            @test mgr.max_ip == ip"4.0.0.0"
        end

        @testset "defaults" begin
            mgr = AWSBatchManager(0)

            @test mgr.min_workers == 0
            @test mgr.max_workers == 0
            @test isempty(mgr.job_definition)
            @test isempty(mgr.job_name)
            @test isempty(mgr.job_queue)
            @test mgr.job_memory == -1
            @test mgr.region == "us-east-1"
            @test mgr.timeout == AWSClusterManagers.BATCH_TIMEOUT
            @test mgr.min_ip == ip"0.0.0.0"
            @test mgr.max_ip == ip"255.255.255.255"

            @test launch_timeout(mgr) == AWSClusterManagers.BATCH_TIMEOUT
            @test desired_workers(mgr) == (0, 0)
        end

        @testset "num workers" begin
            @test_throws ArgumentError AWSBatchManager(-1)
            @test_throws ArgumentError AWSBatchManager(2, 1)
            @test desired_workers(AWSBatchManager(0, 0)) == (0, 0)
            @test desired_workers(AWSBatchManager(2)) == (2, 2)
            @test desired_workers(AWSBatchManager(3:4)) == (3, 4)
            @test_throws MethodError AWSBatchManager(3:1:4)
            @test_throws MethodError AWSBatchManager(3:2:4)
        end

        @testset "queue env variable" begin
            # Mock being run on an AWS batch job
            withenv("WORKER_JOB_QUEUE" => "worker") do
                # Fall back to using the WORKER_JOB_QUEUE environmental variable
                mgr = AWSBatchManager(3)
                @test mgr.job_queue == "worker"

                # Use the queue passed in
                mgr = AWSBatchManager(3; queue="special")
                @test mgr.job_queue == "special"
            end
        end
    end

    @testset "equality" begin
        @test AWSBatchManager(3) == AWSBatchManager(3)
    end

    @testset "addprocs" begin
        mock_queue_arn = "arn:aws:batch:us-east-1:000000000000:job-queue/queue"

        # Note: due to the `addprocs` running our code with @async it can be difficult to
        # debug failures in these tests. If a failure does occur it is recommended you run
        # the code with `launch(AWSBatchManager(...), Dict(), [], Condition())` to get a
        # useful stacktrace.

        @testset "success" begin
            patches = [
                @patch AWSBatch.JobQueue(queue::AbstractString) = JobQueue(mock_queue_arn)
                @patch AWSBatch.max_vcpus(::JobQueue) = 1
                @patch function AWSBatch.run_batch(; kwargs...)
                    @async run(kwargs[:cmd])
                    return BatchJob("00000000-0000-0000-0000-000000000001")
                end
            ]

            apply(patches) do
                # Get an initial list of processes
                init_procs = procs()
                # Add a single AWSBatchManager worker
                added_procs = @test_log LOGGER "notice" BATCH_SPAWN_REGEX begin
                    addprocs(AWSBatchManager(1))
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
            patches = [
                @patch AWSBatch.JobQueue(queue::AbstractString) = JobQueue(mock_queue_arn)
                @patch AWSBatch.max_vcpus(::JobQueue) = 1
                @patch function AWSBatch.run_batch(; kwargs...)
                    # Avoiding spawning a worker process
                    return BatchJob("00000000-0000-0000-0000-000000000002")
                end
            ]

            @test_throws TaskFailedException apply(patches) do
                @test_log LOGGER "notice" BATCH_SPAWN_REGEX begin
                    addprocs(AWSBatchManager(1; timeout=Second(1)))
                end
            end
        end

        @testset "VCPU limit" begin
            @testset "minimum exceeds" begin
                patches = [
                    @patch function AWSBatch.JobQueue(queue::AbstractString)
                        return JobQueue(mock_queue_arn)
                    end
                    @patch AWSBatch.max_vcpus(::JobQueue) = 3
                ]

                apply(patches) do
                    @test_throws TaskFailedException addprocs(
                        AWSBatchManager(4; timeout=Second(5))
                    )
                    @test nprocs() == 1
                end
            end

            @testset "maximum exceeds" begin
                patches = [
                    @patch function AWSBatch.JobQueue(queue::AbstractString)
                        return JobQueue(mock_queue_arn)
                    end
                    @patch AWSBatch.max_vcpus(::JobQueue) = 1
                    @patch function AWSBatch.run_batch(; kwargs...)
                        for _ in 1:kwargs[:num_jobs]
                            @async run(kwargs[:cmd])
                        end
                        return BatchJob("00000000-0000-0000-0000-000000000004")
                    end
                ]
                msg = string(
                    "Due to the max VCPU limit (1) most likely only a partial amount ",
                    "of the requested workers (2) will be spawned.",
                )
                apply(patches) do
                    added_procs = @test_log LOGGER "warn" msg begin
                        addprocs(AWSBatchManager(0:2; timeout=Second(5)))
                    end
                    @test length(added_procs) > 0
                    rmprocs(added_procs; waitfor=5.0)
                end
            end
        end
    end
end
