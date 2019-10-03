# Worst case 15 minute timeout. If the compute environment has just scaled it will wait
# 8 minutes before scaling again. Spot instance requests can take some time to be fufilled
# but are usually instant and instances take around 4 minutes before they are ready.
const TIMEOUT = Minute(15)

const BATCH_SPAWN_REGEX = r"Spawning (array )?job: (?<id>[0-9a-f\-]+)(?(1) \(n=(?<n>\d+)\))"

# Gets the logs messages associated with a AWSBatch BatchJob as a single string
function log_messages(job::BatchJob)
    events = log_events(job)
    return join([event.message for event in events], '\n')
end

function time_str(secs::Real)
    @sprintf("%02d:%02d:%02d", div(secs, 3600), rem(div(secs, 60), 60), rem(secs, 60))
end

# Scrapes the log output to determine the worker job IDs as stated by the manager
function scrape_worker_job_ids(output::AbstractString)
    m = match(BATCH_SPAWN_REGEX, output)

    if m !== nothing
        worker_job = m[:id]

        if m[:n] !== nothing
            num_workers = parse(Int, m[:n])
            return String["$worker_job:$i" for i in 0:(num_workers - 1)]
        else
            return String["$worker_job"]
        end
    else
        return String[]
    end
end

function run_batch_job(image_name::AbstractString, num_workers::Integer; timeout::Period=TIMEOUT, should_fail::Bool=false)
    # TODO: Use AWS Batch job parameters to avoid re-registering the job

    timeout_secs = Dates.value(Second(timeout))

    # Will be running the HEAD revision of the code remotely
    # Note: Pkg.checkout doesn't work on untracked branches / SHAs with Julia 0.5.1
    code = """
        using AWSClusterManagers: AWSClusterManagers, AWSBatchManager
        using Dates: Second
        using Distributed
        using Memento

        Memento.config!("debug"; fmt="{msg}")
        setlevel!(getlogger(AWSClusterManagers), "debug")

        addprocs(
            AWSBatchManager(
                $num_workers;
                queue="$(STACK["WorkerJobQueueArn"])",
                memory=512,
                timeout=Second($(timeout_secs - 15))
            )
        )
        println("NumProcs: ", nprocs())

        @everywhere using AWSClusterManagers: container_id
        for i in workers()
            println("Worker container \$i: ", remotecall_fetch(container_id, i))
            println("Worker job \$i: ", remotecall_fetch(() -> ENV["AWS_BATCH_JOB_ID"], i))
        end
        """

    # Note: The manager can run out of memory with enough workers:
    # - 64 workers with a manager with 1024 MB of memory
    info(logger, "Submitting AWS Batch job with $num_workers workers")
    job = run_batch(;
        name = STACK["JobName"] * "-n$num_workers",
        queue = STACK["ManagerJobQueueArn"],
        definition = STACK["JobDefinitionName"],
        image = image_name,
        role = STACK["JobRoleArn"],
        vcpus = 1,
        memory = 2048,
        cmd = Cmd(["julia", "-e", code]),
    )

    # If no compute environment resources are available it could take around
    # 5 minutes before the manager job is running
    info(logger, "Waiting for AWS Batch manager job $(job.id) to run (~5 minutes)")
    start_time = time()
    @test wait(state -> state < AWSBatch.RUNNING, job, timeout=timeout_secs) == true
    info(logger, "Manager spawning duration: $(time_str(time() - start_time))")

    # Once the manager job is running it will spawn additional AWS Batch jobs as
    # the workers.
    #
    # Since compute environments only scale every 5 minutes we will definitely have
    # to wait if we scaled up for the mananager job. To reduce this wait time make
    # sure you have one VCPU available for the manager to start right away.
    info(logger, "Waiting for AWS Batch workers and manager job to complete (~5 minutes)")
    start_time = time()
    if should_fail
        @test wait(job, [AWSBatch.FAILED], [AWSBatch.SUCCEEDED], timeout=timeout_secs) == true
    else
        @test wait(job, [AWSBatch.SUCCEEDED], timeout=timeout_secs) == true
    end
    info(logger, "Worker spawning duration: $(time_str(time() - start_time))")

    # Remove the job definition as it is specific to a revision
    job_definition = JobDefinition(job)
    deregister(job_definition)

    return job
end

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
                4,
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
                mgr = AWSBatchManager(3, queue="special")
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
                    BatchJob("00000000-0000-0000-0000-000000000001")
                end
            ]

            apply(patches) do
                # Get an initial list of processes
                init_procs = procs()
                # Add a single AWSBatchManager worker
                added_procs = @test_log logger "notice" BATCH_SPAWN_REGEX begin
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
                    BatchJob("00000000-0000-0000-0000-000000000002")
                end
            ]

            @test_throws TaskFailedException apply(patches) do
                @test_log logger "notice" BATCH_SPAWN_REGEX begin
                    addprocs(AWSBatchManager(1; timeout=Second(1)))
                end
            end
        end

        @testset "VCPU limit" begin
            @testset "minimum exceeds" begin
                patches = [
                    @patch AWSBatch.JobQueue(queue::AbstractString) = JobQueue(mock_queue_arn)
                    @patch AWSBatch.max_vcpus(::JobQueue) = 3
                ]

                apply(patches) do
                    @test_throws TaskFailedException addprocs(AWSBatchManager(4, timeout=Second(5)))
                    @test nprocs() == 1
                end
            end

            @testset "maximum exceeds" begin
                patches = [
                    @patch AWSBatch.JobQueue(queue::AbstractString) = JobQueue(mock_queue_arn)
                    @patch AWSBatch.max_vcpus(::JobQueue) = 1
                    @patch function AWSBatch.run_batch(; kwargs...)
                        for _ in 1:kwargs[:num_jobs]
                            @async run(kwargs[:cmd])
                        end
                        BatchJob("00000000-0000-0000-0000-000000000004")
                    end
                ]
                msg = string(
                    "Due to the max VCPU limit (1) most likely only a partial amount ",
                    "of the requested workers (2) will be spawned.",
                )
                apply(patches) do
                    added_procs = @test_log logger "warn" msg begin
                        addprocs(AWSBatchManager(0:2, timeout=Second(5)))
                    end
                    @test length(added_procs) > 0
                    rmprocs(added_procs; waitfor=5.0)
                end
            end
        end
    end

    if "batch" in ONLINE && !isempty(AWS_STACKNAME)

        # Note: Start with the largest number of workers so the remaining tests don't have
        # to wait for the cluster to scale up on subsequent tests.
        @testset "online (n=$num_workers)" for num_workers in [10, 1, 0]
            job = run_batch_job(TEST_IMAGE, num_workers)

            # Retry getting the logs for the batch job because it can take several seconds
            # for cloudwatch to ingest the log records
            get_logs = retry(delays=rand(5:10, 2)) do
                output = log_messages(job)
                m = match(r"(?<=NumProcs: )\d+", output)
                if m === nothing
                    error("The logs do not contain the `NumProcs` for job \"$(job.id)\".")
                end
                num_procs = parse(Int, m.match)
                return (output, num_procs)
            end
            output, num_procs = get_logs()

            # Spawned are the AWS Batch job IDs reported upon job submission at launch
            # while reported is the self-reported job ID of each worker.
            spawned_jobs = scrape_worker_job_ids(output)
            reported_jobs = [m[1] for m in eachmatch(r"Worker job \d+: ([0-9a-f\-]+(?:\:\d+)?)", output)]
            reported_containers = [m[1] for m in eachmatch(r"Worker container \d+: ([0-9a-f]*)", output)]

            @test num_procs == num_workers + 1
            if num_workers > 0
                @test length(reported_jobs) == num_workers
                @test Set(reported_jobs) == Set(spawned_jobs)
            else
                # When we request no workers the manager job will be treated as the worker
                @test length(reported_jobs) == 1
                @test reported_jobs == [job.id]
            end

            # Ensure that the container IDs were found
            @test all(.!isempty.(reported_containers))

            # Determine the image name from an AWS Batch job ID.
            job_image_name(job_id::AbstractString) = job_image_name(BatchJob(job_id))
            job_image_name(job::BatchJob) = describe(job)["container"]["image"]

            @test TEST_IMAGE == job_image_name(job)  # Manager's image
            @test all(TEST_IMAGE .== job_image_name.(spawned_jobs))

            # Report some details about the job
            d = describe(job)
            created_at = Dates.unix2datetime(d["createdAt"] / 1000)
            started_at = Dates.unix2datetime(d["startedAt"] / 1000)
            stopped_at = Dates.unix2datetime(d["stoppedAt"] / 1000)

            # TODO: Unless I'm forgetting something just extracting the seconds from the
            # milliseconds is awkward
            launch_duration = Dates.value(started_at - created_at) / 1000
            run_duration = Dates.value(stopped_at - started_at) / 1000

            info(logger, "Job launch duration: $(time_str(launch_duration))")
            info(logger, "Job run duration:    $(time_str(run_duration))")
        end

        @testset "exceed worker limit" begin
            num_workers = typemax(Int64)
            job = run_batch_job(TEST_IMAGE, num_workers; should_fail=true)
            output = log_messages(job)

            m = match(r"(?<=NumProcs: )\d+", output)
            num_procs = m !== nothing ? parse(Int, m.match) : -1

            # Spawned are the AWS Batch job IDs reported upon job submission at launch
            # while reported is the self-reported job ID of each worker.
            spawned_jobs = scrape_worker_job_ids(output)

            @test num_procs == -1
            @test isempty(spawned_jobs)
        end
    else
        warn(
            logger,
            "Environment variable \"ONLINE\" does not contain \"batch\". " *
            "Skipping online AWS Batch tests."
        )
    end
end
