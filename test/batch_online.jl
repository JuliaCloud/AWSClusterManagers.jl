# Worst case 15 minute timeout. If the compute environment has just scaled it will wait
# 8 minutes before scaling again. Spot instance requests can take some time to be fufilled
# but are usually instant and instances take around 4 minutes before they are ready.
const TIMEOUT = Minute(15)

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

function run_batch_job(
    image_name::AbstractString,
    num_workers::Integer;
    timeout::Period=TIMEOUT,
    should_fail::Bool=false,
)
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

        println("Manager Complete")
        """

    # Note: The manager can run out of memory with enough workers:
    # - 64 workers with a manager with 1024 MB of memory
    info(LOGGER, "Submitting AWS Batch job with $num_workers workers")
    job = run_batch(;
        name=STACK["JobName"] * "-n$num_workers",
        queue=STACK["ManagerJobQueueArn"],
        definition=STACK["JobDefinitionName"],
        image=image_name,
        role=STACK["JobRoleArn"],
        vcpus=1,
        memory=2048,
        cmd=Cmd(["julia", "-e", code]),
    )

    # If no compute environment resources are available it could take around
    # 5 minutes before the manager job is running
    info(LOGGER, "Waiting for AWS Batch manager job $(job.id) to run (~5 minutes)")
    start_time = time()
    @test wait(state -> state < AWSBatch.RUNNING, job; timeout=timeout_secs) == true
    info(LOGGER, "Manager spawning duration: $(time_str(time() - start_time))")

    # Once the manager job is running it will spawn additional AWS Batch jobs as
    # the workers.
    #
    # Since compute environments only scale every 5 minutes we will definitely have
    # to wait if we scaled up for the mananager job. To reduce this wait time make
    # sure you have one VCPU available for the manager to start right away.
    info(LOGGER, "Waiting for AWS Batch workers and manager job to complete (~5 minutes)")
    start_time = time()
    if should_fail
        @test wait(job, [AWSBatch.FAILED], [AWSBatch.SUCCEEDED]; timeout=timeout_secs) ==
              true
    else
        @test wait(job, [AWSBatch.SUCCEEDED]; timeout=timeout_secs) == true
    end
    info(LOGGER, "Worker spawning duration: $(time_str(time() - start_time))")

    # Remove the job definition as it is specific to a revision
    job_definition = JobDefinition(job)
    deregister(job_definition)

    # CloudWatch can take several seconds to ingest the log record so we'll wait until we
    # find the end-of-log message.
    # Note: Do not assume that the "Manager Complete" message will be the last thing written
    # to the log as busy worker may cause additional warnings messages.
    # https://github.com/JuliaCloud/AWSClusterManagers.jl/issues/10
    output = ""
    if status(job) == AWSBatch.SUCCEEDED
        log_wait_start = time()

        while true
            events = log_events(job)
            if events !== nothing &&
               !isempty(events) &&
               any(e -> e.message == "Manager Complete", events)
                output = join(
                    [string(event.timestamp, "  ", event.message) for event in events], '\n'
                )
                break
            elseif time() - log_wait_start > 60
                error("CloudWatch logs have not completed ingestion within 1 minute")
            end

            sleep(5)
        end
    end

    return job, output
end

@testset "AWSBatchManager (online)" begin
    # Note: Start with the largest number of workers so the remaining tests don't have
    # to wait for the cluster to scale up on subsequent tests.
    @testset "Num workers ($num_workers)" for num_workers in [10, 1, 0]
        job, output = run_batch_job(TEST_IMAGE, num_workers)

        m = match(r"(?<=NumProcs: )\d+", output)
        if m !== nothing
            num_procs = parse(Int, m.match)
        else
            error("The logs do not contain the `NumProcs` for job \"$(job.id)\".")
        end

        # Spawned are the AWS Batch job IDs reported upon job submission at launch
        # while reported is the self-reported job ID of each worker.
        spawned_jobs = scrape_worker_job_ids(output)
        reported_jobs = [
            m[1] for m in eachmatch(r"Worker job \d+: ([0-9a-f\-]+(?:\:\d+)?)", output)
        ]
        reported_containers = [
            m[1] for m in eachmatch(r"Worker container \d+: ([0-9a-f]*)", output)
        ]

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

        info(LOGGER, "Job launch duration: $(time_str(launch_duration))")
        info(LOGGER, "Job run duration:    $(time_str(run_duration))")
    end

    @testset "exceed worker limit" begin
        num_workers = typemax(Int64)
        job, output = run_batch_job(TEST_IMAGE, num_workers; should_fail=true)

        # Spawned are the AWS Batch job IDs reported upon job submission at launch
        # while reported is the self-reported job ID of each worker.
        spawned_jobs = scrape_worker_job_ids(output)

        @test match(r"(?<=NumProcs: )\d+", output) === nothing
        @test isempty(spawned_jobs)
    end
end
