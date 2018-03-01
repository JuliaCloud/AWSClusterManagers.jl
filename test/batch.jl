const BATCH_ENVS = (
    "AWS_BATCH_JOB_ID" => "bcf0b186-a532-4122-842e-2ccab8d54efb",
    "AWS_BATCH_JQ_NAME" => "HighPriority"
)

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
                600
            )

            @test mgr.min_workers == 1
            @test mgr.max_workers == 2
            @test mgr.job_definition == "job-definition"
            @test mgr.job_name == "job-name"
            @test mgr.job_queue == "job-queue"
            @test mgr.job_memory == 1000
            @test mgr.region == "us-east-1"
            @test mgr.timeout == 600

            @test launch_timeout(mgr) == 600
            @test num_workers(mgr) == (1, 2)
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
                timeout=5
            )

            @test mgr.min_workers == 3
            @test mgr.max_workers == 4
            @test mgr.job_definition == "d"
            @test mgr.job_name == "n"
            @test mgr.job_queue == "q"
            @test mgr.job_memory == 1000
            @test mgr.region == "us-west-1"
            @test mgr.timeout == 5
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

            @test num_workers(AWSBatchManager(3:4; kwargs...)) == (3, 4)
            @test_throws MethodError AWSBatchManager(3:1:4; kwargs...)
            @test_throws MethodError AWSBatchManager(3:2:4; kwargs...)

            @test num_workers(AWSBatchManager(5; kwargs...)) == (5, 5)
        end
        @testset "AWS Defaults" begin
            # Running outside of the environment of an AWS batch job
            withenv("AWS_BATCH_JOB_ID" => nothing) do
                @test_throws BatchEnvironmentError AWSBatchManager(3)
            end

            # Mock being run on an AWS batch job
            withenv(BATCH_ENVS...) do
                patches = [
                    @patch readstring(cmd::AbstractCmd) = TestUtils.readstring(cmd)
                    @patch describe_jobs(dict::Dict) = TestUtils.describe_jobs(dict)
                ]

                apply(patches) do
                    job = BatchJob()
                    mgr = AWSBatchManager(3)

                    @test mgr.min_workers == 3
                    @test mgr.max_workers == 3
                    @test mgr.job_definition == job.definition
                    @test mgr.job_name == job.name
                    @test mgr.job_queue == job.queue
                    @test mgr.job_memory == 512
                    @test mgr.region == job.region
                    @test mgr.timeout == AWSClusterManagers.DEFAULT_TIMEOUT

                    @test mgr == AWSBatchManager(3)
                end
            end
        end

        @testset "Queue environmental variable" begin
            # Mock being run on an AWS batch job
            withenv("WORKER_JOB_QUEUE" => "worker", BATCH_ENVS...) do
                patches = [
                    @patch readstring(cmd::AbstractCmd) = TestUtils.readstring(cmd)
                    @patch describe_jobs(dict::Dict) = TestUtils.describe_jobs(dict)
                ]

                apply(patches) do
                    # Fall back to using the WORKER_JOB_QUEUE environmental variable
                    job = BatchJob()
                    mgr = AWSBatchManager(3)
                    @test job.queue != "worker"
                    @test mgr.job_queue == "worker"

                    # Use the queue passed in
                    mgr = AWSBatchManager(3, queue="special")
                    @test mgr.job_queue == "special"
                end
            end
        end
    end
    @testset "Adding procs" begin
        @testset "Worker Succeeds" begin
            withenv(BATCH_ENVS...) do
                patches = [
                    @patch readstring(cmd::AbstractCmd) = TestUtils.readstring(cmd)
                    @patch describe_jobs(dict::Dict) = TestUtils.describe_jobs(dict)
                    @patch submit(job::BatchJob) = TestUtils.submit(job, true)
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
                    @patch readstring(cmd::AbstractCmd) = TestUtils.readstring(cmd, false)
                    @patch describe_jobs(dict::Dict) = TestUtils.describe_jobs(dict)
                    @patch submit(job::BatchJob) = TestUtils.submit(job, false)
                ]

                @test_throws ErrorException apply(patches) do
                    # Suppress "unhandled task error" message
                    # https://github.com/JuliaLang/julia/issues/12403
                    ignore_stderr() do
                        addprocs(AWSBatchManager(1; timeout=1.0))
                    end
                end
            end
        end
    end

    if "batch" in ONLINE
        @testset "Online" begin
            image_name = batch_manager_build()
            num_workers = 3

            # Will be running the HEAD revision of the code remotely
            # Note: Pkg.checkout doesn't work on untracked branches / SHAs with Julia 0.5.1
            code = """
            using Memento
            Memento.config("debug"; fmt="{msg}")
            using AWSClusterManagers: AWSBatchManager
            setlevel!(getlogger(AWSClusterManagers), "debug")
            addprocs(AWSBatchManager($num_workers, queue="$(STACK["WorkerJobQueue"])"))
            println("NumProcs: ", nprocs())
            @everywhere using AWSClusterManagers: container_id
            for i in workers()
                println("Worker container \$i: ", remotecall_fetch(container_id, i))
                println("Worker job \$i: ", remotecall_fetch(() -> ENV["AWS_BATCH_JOB_ID"], i))
            end
            """

            info("Creating AWS Batch job")
            job = BatchJob(;
                name = STACK["JobName"],
                queue = STACK["ManagerJobQueue"],
                definition = STACK["JobDefinitionName"],
                image = image_name,
                role = STACK["JobRoleArn"],
                vcpus = 1,
                memory = 1024,
                cmd = Cmd(["julia", "-e", replace(code, r"\n+", "; ")]),
            )

            info("Registering AWS batch job definition: $(STACK["JobDefinitionName"])")
            definition = register(job)
            job.definition = definition

            info("Submitting AWS Batch job")
            submit(job)

            # If no resources are available it could take around 5 minutes before the job is running
            info("Waiting for AWS Batch job $(job.id) to complete (~5 minutes)")
            @test wait(job, [AWSTools.SUCCEEDED]) == true

            # Remove the job definition as it is specific to a revision
            deregister(job)

            output = log_messages(job)

            m = match(r"(?<=NumProcs: )\d+", output)
            num_procs = m !== nothing ? parse(Int, m.match) : -1

            # Spawned are the AWS Batch job IDs reported upon job submission at launch
            # while reported is the self-reported job ID of each worker.
            spawned_jobs = matchall(r"(?<=Spawning job: )[0-9a-f\-]+", output)
            reported_jobs = matchall(r"(?<=Worker job \d: )[0-9a-f\-]+", output)
            reported_containers = matchall(r"(?<=Worker container \d: )[0-9a-f]*", output)

            @test num_procs == num_workers + 1
            @test length(reported_jobs) == num_workers
            @test Set(spawned_jobs) == Set(reported_jobs)

            # Ensure that the container IDs were found
            @test all(.!isempty.(reported_containers))

            # Determine the image name from an AWS Batch job ID.
            job_image_name(job_id::AbstractString) = job_image_name(BatchJob(; id=job_id))
            job_image_name(job::BatchJob) = AWSTools.describe(job)["container"]["image"]

            @test image_name == job_image_name(job)  # Manager's image
            @test all(image_name .== job_image_name.(spawned_jobs))

            # Report some details about the job
            d = AWSTools.describe(job)
            created_at = Dates.unix2datetime(d["createdAt"] / 1000)
            started_at = Dates.unix2datetime(d["startedAt"] / 1000)
            stopped_at = Dates.unix2datetime(d["stoppedAt"] / 1000)

            # TODO: Unless I'm forgetting something just extrating the seconds from the milliseconds
            # is awkward
            launch_duration = div(Dates.value(started_at - created_at), 1000)
            run_duration = div(Dates.value(stopped_at - started_at), 1000)

            info("Job launch duration: $(time_str(launch_duration))")
            info("Job run duration:    $(time_str(run_duration))")
        end
    else
        warn("Environment variable \"ONLINE\" does not contain \"batch\". Skipping online AWS Batch tests.")
    end
end
