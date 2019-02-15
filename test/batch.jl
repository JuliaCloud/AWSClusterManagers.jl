using AWSCore: AWSConfig

const BATCH_ENVS = (
    "AWS_BATCH_JOB_ID" => "bcf0b186-a532-4122-842e-2ccab8d54efb",
    "AWS_BATCH_JQ_NAME" => "HighPriority"
)

# Worst case 15 minute timeout. If the compute environment has just scaled it will wait
# 8 minutes before scaling again. Spot instance requests can take some time to be fufilled
# but are usually instant and instances take around 4 minutes before they are ready.
const TIMEOUT = Minute(15)

# Scrapes the log output to determine the worker job IDs as stated by the manager
function scrape_worker_job_ids(output::AbstractString)
    m = match(r"Spawning (array )?job: (?<id>[0-9a-f\-]+)(?(1) \(n=(?<n>\d+)\))", output)

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
    @testset "Constructors" begin
        @testset "Inner" begin
            mgr = AWSBatchManager(
                1,
                2,
                "job-definition",
                "job-name",
                "job-queue",
                1000,
                "us-east-1",
                Minute(10),
            )

            @test mgr.min_workers == 1
            @test mgr.max_workers == 2
            @test mgr.job_definition == "job-definition"
            @test mgr.job_name == "job-name"
            @test mgr.job_queue == "job-queue"
            @test mgr.job_memory == 1000
            @test mgr.region == "us-east-1"
            @test mgr.timeout == Minute(10)

            @test launch_timeout(mgr) == Minute(10)
            @test desired_workers(mgr) == (1, 2)
        end

        @testset "Keyword" begin
            mgr = AWSBatchManager(
                3,
                4,
                definition="d",
                name="n",
                queue="q",
                memory=1000,
                region="us-west-1",
                timeout=Second(5)
            )

            @test mgr.min_workers == 3
            @test mgr.max_workers == 4
            @test mgr.job_definition == "d"
            @test mgr.job_name == "n"
            @test mgr.job_queue == "q"
            @test mgr.job_memory == 1000
            @test mgr.region == "us-west-1"
            @test mgr.timeout == Second(5)
        end

        @testset "Zero Workers" begin
            mgr = AWSBatchManager(
                0,
                0,
                definition="d",
                name="n",
                queue="q",
                memory=1000,
                region="us-west-1",
                timeout=Second(5)
            )

            @test mgr.min_workers == 0
            @test mgr.max_workers == 0
        end

        @testset "Kwargs" begin
            # Define the keywords definition, name, queue, and region to avoid
            # calling BatchJob.
            kwargs = Dict(
                :definition => "d",
                :name => "n",
                :queue => "q",
                :memory => 1000,
                :region => "ca-central-1"
            )
            @test desired_workers(AWSBatchManager(3:4; kwargs...)) == (3, 4)
            @test_throws MethodError AWSBatchManager(3:1:4; kwargs...)
            @test_throws MethodError AWSBatchManager(3:2:4; kwargs...)
            @test desired_workers(AWSBatchManager(5; kwargs...)) == (5, 5)
        end

        @testset "Defaults" begin
            # Running outside of the environment of an AWS batch job
            withenv("AWS_BATCH_JOB_ID" => nothing) do
                 patches = [
                    @patch JobQueue(queue::AbstractString) = JobQueue("arn:aws:batch:us-east-1:000000000000:job-queue/queue")
                    @patch max_vcpus(::JobQueue) = 3
                ]

                apply(patches) do
                    mgr = AWSBatchManager(3)
                    @test_throws AWSBatch.BatchEnvironmentError AWSClusterManagers.spawn_containers(mgr, ``)
                end
            end

            # Mock being run on an AWS batch job
            withenv(BATCH_ENVS...) do
                mgr = AWSBatchManager(3)

                @test mgr.min_workers == 3
                @test mgr.max_workers == 3
                @test mgr.timeout == AWSClusterManagers.BATCH_TIMEOUT

                @test mgr.job_definition == ""
                @test mgr.job_name == ""
                @test mgr.job_queue == ""
                @test mgr.job_memory == -1
                @test mgr.region == "us-east-1"

                @test launch_timeout(mgr) == AWSClusterManagers.BATCH_TIMEOUT
                @test desired_workers(mgr) == (3, 3)

                @test mgr == AWSBatchManager(3)
            end
        end

        @testset "Queue environmental variable" begin
            # Mock being run on an AWS batch job
            withenv("WORKER_JOB_QUEUE" => "worker", BATCH_ENVS...) do
                # Fall back to using the WORKER_JOB_QUEUE environmental variable
                mgr = AWSBatchManager(3)
                @test mgr.job_queue == "worker"

                # Use the queue passed in
                mgr = AWSBatchManager(3, queue="special")
                @test mgr.job_queue == "special"
            end
        end
    end

    @testset "Adding procs" begin
        @testset "Worker Succeeds" begin
            withenv(BATCH_ENVS...) do
                patches = [
                    @patch read(cmd::AbstractCmd, ::Type{String}) = TestUtils.read(cmd, String)
                    @patch describe_jobs(dict::Dict) = TestUtils.describe_jobs(dict)
                    @patch describe_job_definitions(dict::Dict) = TestUtils.describe_job_definitions(dict)
                    @patch submit_job(c::AWSConfig, d::AbstractArray) = TestUtils.submit_job(c, d)
                    @patch JobQueue(queue::AbstractString) = JobQueue("arn:aws:batch:us-east-1:000000000000:job-queue/queue")
                    @patch max_vcpus(::JobQueue) = 1
                ]

                apply(patches) do
                    # Get an initial list of processes
                    init_procs = procs()
                    # Add a single AWSBatchManager worker
                    added_procs = addprocs(AWSBatchManager(1))
                    # Check that the workers are available
                    @test length(added_procs) == 1
                    @test procs() == vcat(init_procs, added_procs)
                    # Remove the added workers
                    rmprocs(added_procs; waitfor=5.0)
                    # Double check that rmprocs worked
                    @test init_procs == procs()
                end
            end
        end

        @testset "Worker Timeout" begin
            withenv(BATCH_ENVS...) do
                patches = [
                    @patch read(cmd::AbstractCmd, ::Type{String}) = TestUtils.read(cmd, String, false)
                    @patch describe_jobs(dict::Dict) = TestUtils.describe_jobs(dict)
                    @patch describe_job_definitions(dict::Dict) = TestUtils.describe_job_definitions(dict)
                    @patch submit_job(c::AWSConfig, d::AbstractArray) = TestUtils.submit_job(() -> sleep(3), c, d)
                    @patch JobQueue(queue::AbstractString) = JobQueue("arn:aws:batch:us-east-1:000000000000:job-queue/queue")
                    @patch max_vcpus(::JobQueue) = 1
                ]

                @test_throws ErrorException apply(patches) do
                    # Suppress "unhandled task error" message
                    # https://github.com/JuliaLang/julia/issues/12403
                    ignore_stderr() do
                        addprocs(AWSBatchManager(1; timeout=Second(1)))
                    end
                end
            end
        end

        @testset "Max Tasks" begin
            withenv(BATCH_ENVS...) do
                patches = [
                    @patch read(cmd::AbstractCmd, ::Type{String}) = TestUtils.read(cmd, String)
                    @patch describe_jobs(dict::Dict) = TestUtils.describe_jobs(dict)
                    @patch describe_job_definitions(dict::Dict) = TestUtils.describe_job_definitions(dict)
                    @patch submit_job(c::AWSConfig, d::AbstractArray) = TestUtils.submit_job(c, d)
                    @patch JobQueue(queue::AbstractString) = JobQueue("arn:aws:batch:us-east-1:000000000000:job-queue/queue")
                    @patch max_vcpus(::JobQueue) = 3
                ]

                @test_throws ErrorException apply(patches) do
                    ignore_stderr() do
                        addprocs(AWSBatchManager(4, timeout=Second(5)))
                        @test nprocs() == 1
                    end
                end

                patches = [
                    @patch read(cmd::AbstractCmd, ::Type{String}) = TestUtils.read(cmd, String)
                    @patch describe_jobs(dict::Dict) = TestUtils.describe_jobs(dict)
                    @patch describe_job_definitions(dict::Dict) = TestUtils.describe_job_definitions(dict)
                    @patch submit_job(c::AWSConfig, d::AbstractArray) = TestUtils.submit_job(c, d)
                    @patch JobQueue(queue::AbstractString) = JobQueue("arn:aws:batch:us-east-1:000000000000:job-queue/queue")
                    @patch max_vcpus(::JobQueue) = 1
                ]
                msg = string(
                    "Due to the max VCPU limit (1) most likely only a partial amount ",
                    "of the requested workers (2) will be spawned.",
                )
                apply(patches) do
                    added_procs = Memento.Test.@test_log(logger, "warn", msg, addprocs(AWSBatchManager(0:2, timeout=Second(5))))
                    # Check that the workers are available
                    @test length(added_procs) == 1
                    # Remove the added workers
                    rmprocs(added_procs; waitfor=5.0)
                end
            end
        end
    end

    if "batch" in ONLINE && !isempty(AWS_STACKNAME)
        image_name = batch_manager_build()

        # Note: Start with the largest number of workers so the remaining tests don't have
        # to wait for the cluster to scale up on subsequent tests.
        @testset "Online (n=$num_workers)" for num_workers in [10, 1, 0]
            job = run_batch_job(image_name, num_workers)

            # Retry getting the logs for the batch job because it can take several seconds
            # for cloudwatch to ingest the log records
            get_logs = retry(delays=rand(5:10, 2)) do
                output = TestUtils.log_messages(job)
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

            @test image_name == job_image_name(job)  # Manager's image
            @test all(image_name .== job_image_name.(spawned_jobs))

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

        @testset "Exceed worker limit" begin
            num_workers = typemax(Int64)
            job = run_batch_job(image_name, num_workers; should_fail=true)
            output = TestUtils.log_messages(job)

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
