# Ideally we would register a single job definition as part of the CloudFormation template
# and use overrides to change the image used. Unfortunately, this is not a supported
# override so we're left with a dilemma:
#
# 1. Define the job definition in CFN and change the image referenced by uploading a new
#    Docker image with the same name.
# 2. Create a new job definition for each Docker image

# The first option is problematic when executing tests in parallel using the same stack. If
# two CI pipelines are running concurrently then the last Docker image to be pushed will be
# the one used by both pipelines (assumes the push completes before the batch job starts).
#
# We went with the second option as it is safer for parallel pipelines and allows us to
# still use overrides to modify other parts of the job definition.
function batch_node_job_definition(;
    job_definition_name::AbstractString="$(STACK_NAME)-node",
    image::AbstractString=TEST_IMAGE,
    job_role_arn::AbstractString=STACK["TestBatchNodeJobRoleArn"],
)
    manager_code = """
        using AWSClusterManagers, Distributed, Memento
        setlevel!(getlogger("root"), "debug", recursive=true)

        addprocs(AWSBatchNodeManager())

        println("NumProcs: ", nprocs())
        for i in workers()
            println("Worker job \$i: ", remotecall_fetch(() -> ENV["AWS_BATCH_JOB_NODE_INDEX"], i))
        end
        """

    bind_to = "--bind-to \$(ip -o -4 addr list eth0 | awk '{print \$4}' | cut -d/ -f1)"
    worker_code = """
        using AWSClusterManagers
        start_batch_node_worker()
        """

    return Dict(
        "jobDefinitionName" => job_definition_name,
        "type" => "multinode",
        "nodeProperties" => Dict(
            "numNodes" => 3,
            "mainNode" => 0,
            "nodeRangeProperties" => [
                Dict(
                    "targetNodes" => "0",
                    "container" => Dict(
                        "image" => image,
                        "jobRoleArn" => job_role_arn,
                        "vcpus" => 1,
                        "memory" => 1024,  # MiB
                        "command" => ["julia", "-e", manager_code],
                    ),
                ),
                Dict(
                    "targetNodes" => "1:",
                    "container" => Dict(
                        "image" => image,
                        "jobRoleArn" => job_role_arn,
                        "vcpus" => 1,
                        "memory" => 1024,  # MiB
                        "command" => [
                            "bash",
                            "-c",
                            "julia $bind_to -e $(bash_quote(worker_code))",
                        ],
                    ),
                ),
            ],
        ),
        # Retrying to handle EC2 instance failures and internal AWS issues:
        # https://docs.aws.amazon.com/batch/latest/userguide/job_retries.html
        "retryStrategy" => Dict("attempts" => 3),
    )
end

# Use single quotes so that no shell interpolation occurs.
bash_quote(str::AbstractString) = string("'", replace(str, "'" => "'\\''"), "'")

# AWS Batch parallel multi-node jobs will only run on on-demand clusters. When running
# on spot the jobs will remain stuck in the RUNNABLE state
let ce = describe_compute_environment(STACK["ComputeEnvironmentArn"])
    if ce["computeResources"]["type"] != "EC2"  # on-demand
        error(
            "Aborting as compute environment $(STACK["ComputeEnvironmentArn"]) is not " *
            "using on-demand instances which are required for AWS Batch multi-node " *
            "parallel jobs.",
        )
    end
end

const BATCH_NODE_INDEX_REGEX = r"Worker job (?<worker_id>\d+): (?<node_index>\d+)"
const BATCH_NODE_JOB_DEF = register_job_definition(batch_node_job_definition())  # ARN

# Spawn all of the AWS Batch jobs at once in order to make online tests run faster. Each
# job spawned below has a corresponding testset. Ideally, the job spawning would be
# contained within the testset bun unfortunately that doesn't seem possible as `@sync` and
# `@testset` currently do not work together.
const BATCH_NODE_JOBS = Dict{String,BatchJob}()

let job_name = "test-worker-spawn-success"
    BATCH_NODE_JOBS[job_name] = submit_job(;
        job_name=job_name, job_definition=BATCH_NODE_JOB_DEF
    )
end

let job_name = "test-worker-spawn-failure"
    overrides = Dict(
        "numNodes" => 2,
        "nodePropertyOverrides" => [
            Dict(
                "targetNodes" => "1:",
                "containerOverrides" => Dict("command" => ["bash", "-c", "exit 0"]),
            ),
        ],
    )

    BATCH_NODE_JOBS[job_name] = submit_job(;
        job_name=job_name, job_definition=BATCH_NODE_JOB_DEF, node_overrides=overrides
    )
end

let job_name = "test-worker-link-local"
    overrides = Dict(
        "numNodes" => 2,
        "nodePropertyOverrides" => [
            Dict(
                "targetNodes" => "1:",
                "containerOverrides" => Dict(
                    "command" => [
                        "julia",
                        "-e",
                        """
                        using AWSClusterManagers, Memento
                        setlevel!(getlogger(), "debug", recursive=true)
                        try
                            start_batch_node_worker()
                        catch e   # Prevents the job from failing so we can retry AWS errors
                            showerror(stderr, e, catch_backtrace())
                        end
                        """,
                    ],
                ),
            ),
        ],
    )

    BATCH_NODE_JOBS[job_name] = submit_job(;
        job_name=job_name, job_definition=BATCH_NODE_JOB_DEF, node_overrides=overrides
    )
end

let job_name = "test-worker-link-local-bind-to"
    bind_to = "--bind-to \$(ip -o -4 addr list ecs-eth0 | awk '{print \$4}' | cut -d/ -f1)"
    worker_code = """
        using AWSClusterManagers, Memento
        setlevel!(getlogger("root"), "debug", recursive=true)
        try
            start_batch_node_worker()
        catch e   # Prevents the job from failing so we can retry AWS errors
            showerror(stderr, e, catch_backtrace())
        end
        """

    overrides = Dict(
        "numNodes" => 2,
        "nodePropertyOverrides" => [
            Dict(
                "targetNodes" => "1:",
                "containerOverrides" => Dict(
                    "command" => [
                        "bash",
                        "-c",
                        "julia $bind_to -e $(bash_quote(worker_code))",
                    ],
                ),
            ),
        ],
    )

    BATCH_NODE_JOBS[job_name] = submit_job(;
        job_name=job_name, job_definition=BATCH_NODE_JOB_DEF, node_overrides=overrides
    )
end

let job_name = "test-slow-manager"
    # Should match code in `batch_node_job_definition` but with an added delay
    manager_code = """
        using AWSClusterManagers, Distributed, Memento
        setlevel!(getlogger("root"), "debug", recursive=true)

        sleep(120)
        addprocs(AWSBatchNodeManager())

        println("NumProcs: ", nprocs())
        for i in workers()
            println("Worker job \$i: ", remotecall_fetch(() -> ENV["AWS_BATCH_JOB_NODE_INDEX"], i))
        end
        """

    overrides = Dict(
        "numNodes" => 2,
        "nodePropertyOverrides" => [
            Dict(
                "targetNodes" => "0",
                "containerOverrides" =>
                    Dict("command" => ["julia", "-e", manager_code]),
            ),
        ],
    )

    BATCH_NODE_JOBS[job_name] = submit_job(;
        job_name=job_name, job_definition=BATCH_NODE_JOB_DEF, node_overrides=overrides
    )
end

let job_name = "test-worker-timeout"
    # The default duration a worker process will wait for the manager to connect. For this
    # test this is also the amount of time between when the early worker checks in with the
    # manager and the late worker checks in.
    #
    # Note: Make sure to ignore any modification made on the local system that will not be
    # present for the batch job.
    worker_timeout = withenv("JULIA_WORKER_TIMEOUT" => nothing) do
        Distributed.worker_timeout()  # In seconds
    end

    # Amount of time it from the job start to executing `start_worker` (when the worker
    # timeout timer starts).
    start_delay = 10  # In seconds

    # Modify the manager to extend the worker check-in time. Ensures that the worker doesn't
    # timeout before the late worker checks in.
    manager_code = """
        using AWSClusterManagers, Dates, Distributed, Memento
        using AWSClusterManagers: AWS_BATCH_NODE_TIMEOUT
        setlevel!(getlogger(), "debug", recursive=true)

        check_in_timeout = Second(AWS_BATCH_NODE_TIMEOUT) + Second($(worker_timeout + start_delay))
        addprocs(AWSBatchNodeManager(timeout=check_in_timeout))

        println("NumProcs: ", nprocs())
        for i in workers()
            println("Worker job \$i: ", remotecall_fetch(() -> ENV["AWS_BATCH_JOB_NODE_INDEX"], i))
        end

        # Failure to launch all workers should trigger a retry via a non-zero exit code
        nworkers() == 2 || exit(2)
        """

    bind_to = "--bind-to \$(ip -o -4 addr list eth0 | awk '{print \$4}' | cut -d/ -f1)"

    # Note: The worker code logic tries to ensure that the execution of
    # `start_batch_node_worker` occurs around the same time for all workers.
    #
    # Requires that worker jobs have external network access and have permissions for IAM
    # access `batch:DescribeJobs`.
    worker_code = """
        using AWSBatch, AWSClusterManagers, Memento
        setlevel!(getlogger(), "debug")
        setlevel!(getlogger("AWSClusterManager"), "debug")
        node_index = parse(Int, ENV["AWS_BATCH_JOB_NODE_INDEX"])
        sibling_index = node_index % 2 + 1  # Assumes only 2 workers

        function wait_job_start(job::BatchJob)
            started_at = nothing
            while started_at === nothing
                started_at = get(describe(job), "startedAt", nothing)
                sleep(10)
            end
        end

        sibling_job_id = replace(
            ENV["AWS_BATCH_JOB_ID"],
            "#\$node_index" => "#\$sibling_index",
        )
        @info "Waiting for sibling job: \$sibling_job_id"
        wait_job_start(BatchJob(sibling_job_id))

        # Delaying a worker from reporting to the manager will delay the manager and cause
        # the workers that did report in to encounter the worker timeout. The delay here
        # should be less than the manager timeout to allow the delayed worker to still
        # report in.
        if node_index == 2  # The late worker will
            @info "Sleeping"
            sleep($(worker_timeout + start_delay))
        end

        start_batch_node_worker()
        """

    overrides = Dict(
        "numNodes" => 3,
        "nodePropertyOverrides" => [
            Dict(
                "targetNodes" => "0",
                "containerOverrides" =>
                    Dict("command" => ["julia", "-e", manager_code]),
            ),
            Dict(
                "targetNodes" => "1:",
                "containerOverrides" => Dict(
                    "command" => [
                        "bash",
                        "-c",
                        "julia $bind_to -e $(bash_quote(worker_code))",
                    ],
                ),
            ),
        ],
    )

    BATCH_NODE_JOBS[job_name] = submit_job(;
        job_name=job_name, job_definition=BATCH_NODE_JOB_DEF, node_overrides=overrides
    )
end

@testset "AWSBatchNodeManager (online)" begin
    # Note: Alternatively we could test report via Mocking but since the function is only
    # used for online testing and this particular test doesn't require an additional AWS
    # Batch job we'll test it here instead
    @testset "Report" begin
        job = BATCH_NODE_JOBS["test-worker-spawn-success"]

        manager_job = BatchJob(job.id * "#0")

        wait_finish(job)

        # Validate the report contains important information
        report_log = report(manager_job)
        test_results = [
            @test occursin(manager_job.id, report_log)
            @test occursin(string(status(manager_job)), report_log)
            @test occursin(status_reason(manager_job), report_log)
        ]

        if any(r -> !(r isa Test.Pass), test_results)
            @info "Details for manager:\n$report_log"
        end
    end

    @testset "Success" begin
        job = BATCH_NODE_JOBS["test-worker-spawn-success"]

        manager_job = BatchJob(job.id * "#0")
        worker_jobs = BatchJob.(job.id .* ("#1", "#2"))

        wait_finish(job)

        @test status(manager_job) == AWSBatch.SUCCEEDED
        @test all(status(w) == AWSBatch.SUCCEEDED for w in worker_jobs)

        # Expect 2 workers to check in and the worker ID order to match the node index order
        manager_log = log_messages(manager_job)
        matches = collect(eachmatch(BATCH_NODE_INDEX_REGEX, manager_log))
        test_results = [
            @test length(matches) == 2
            @test matches[1][:worker_id] == "2"
            @test matches[1][:node_index] == "1"
            @test matches[2][:worker_id] == "3"
            @test matches[2][:node_index] == "2"
        ]

        # Display the logs for all the jobs if any of the log tests fail
        if any(r -> !(r isa Test.Pass), test_results)
            @info "Details for manager:\n$(report(manager_job))"
            @info "Details for worker 1:\n$(report(worker_jobs[1]))"
            @info "Details for worker 2:\n$(report(worker_jobs[2]))"
        end
    end

    @testset "Worker spawn failure" begin
        # Simulate a batch job which failed to start
        job = BATCH_NODE_JOBS["test-worker-spawn-failure"]

        manager_job = BatchJob(job.id * "#0")
        worker_job = BatchJob(job.id * "#1")

        wait_finish(job)

        # Even though the worker failed to spawn the cluster manager continues with the
        # subset of workers that reported in.
        @test status(manager_job) == AWSBatch.SUCCEEDED
        @test status(worker_job) == AWSBatch.SUCCEEDED

        manager_log = log_messages(manager_job)
        worker_log = log_messages(worker_job; retries=0)
        test_results = [
            @test occursin("Only 0 of the 1 workers job have reported in", manager_log)
            @test isempty(worker_log)
        ]

        # Display the logs for all the jobs if any of the log tests fail
        if any(r -> !(r isa Test.Pass), test_results)
            @info "Details for manager:\n$(report(manager_job))"
            @info "Details for worker:\n$(report(worker_job))"
        end
    end

    @testset "Worker using link-local address" begin
        # Failing to specify a `--bind-to` address results in the link-local address being
        # reported from the workers which cannot be used by the manager to connect.
        job = BATCH_NODE_JOBS["test-worker-link-local"]

        manager_job = BatchJob(job.id * "#0")
        worker_job = BatchJob(job.id * "#1")

        wait_finish(job)

        @test status(manager_job) == AWSBatch.SUCCEEDED
        # Note: In practice worker jobs would actually fail but we catch the failure so that
        # we can retry the jobs for other AWS failure cases
        @test status(worker_job) == AWSBatch.SUCCEEDED

        manager_log = log_messages(manager_job)
        worker_log = log_messages(worker_job)
        test_results = [
            @test occursin("Only 0 of the 1 workers job have reported in", manager_log)
            @test occursin("Aborting due to use of link-local address", worker_log)
        ]

        # Display the logs for all the jobs if any of the log tests fail
        if any(r -> !(r isa Test.Pass), test_results)
            @info "Details for manager:\n$(report(manager_job))"
            @info "Details for worker:\n$(report(worker_job))"
        end
    end

    @testset "Worker using link-local bind-to address" begin
        # Accidentially specifying the link-local address in `--bind-to`.
        job = BATCH_NODE_JOBS["test-worker-link-local-bind-to"]

        manager_job = BatchJob(job.id * "#0")
        worker_job = BatchJob(job.id * "#1")

        wait_finish(job)

        @test status(manager_job) == AWSBatch.SUCCEEDED
        # Note: In practice worker jobs would actually fail but we catch the failure so that
        # we can retry the jobs for other AWS failure cases
        @test status(worker_job) == AWSBatch.SUCCEEDED

        manager_log = log_messages(manager_job)
        worker_log = log_messages(worker_job)
        test_results = [
            @test occursin("Only 0 of the 1 workers job have reported in", manager_log)
            @test occursin("Aborting due to use of link-local address", worker_log)
        ]

        # Display the logs for all the jobs if any of the log tests fail
        if any(r -> !(r isa Test.Pass), test_results)
            @info "Details for manager:\n$(report(manager_job))"
            @info "Details for worker:\n$(report(worker_job))"
        end
    end

    @testset "Worker connects before manager is ready" begin
        # If the workers manage to start and attempt to connect to the manager before the
        # manager is listening for connections the worker should attempt to reconnect.
        job = BATCH_NODE_JOBS["test-slow-manager"]

        manager_job = BatchJob(job.id * "#0")
        worker_job = BatchJob(job.id * "#1")

        wait_finish(job)

        @test status(manager_job) == AWSBatch.SUCCEEDED
        @test status(worker_job) == AWSBatch.SUCCEEDED

        manager_log = log_messages(manager_job)
        worker_log = log_messages(worker_job)

        test_results = [
            @test occursin("All workers have successfully reported in", manager_log)
        ]

        # Display the logs for all the jobs if any of the log tests fail
        # When the worker fails to connect the following error will occur:
        # `ERROR: IOError: connect: connection refused (ECONNREFUSED)`
        if any(r -> !(r isa Test.Pass), test_results)
            @info "Details for manager:\n$(report(manager_job))"
            @info "Details for worker:\n$(report(worker_job))"
        end
    end

    @testset "Worker timeout" begin
        # In order to modify the Julia worker ordering the manager needs to wait for all
        # worker to check-in before the manager connects to any worker. Due to this
        # restriction it is possible that worker may wait longer than the
        # `Distributed.worker_timeout()` at which time the worker will self-terminate. If
        # this occurs during the cluster setup the manager node will hang and not proceed
        # past the initial cluster setup.
        #
        # If enough workers exist it is possible that the worker will self-terminate due to
        # hitting a timeout (The issue has been seen with as low as 30 nodes with a timeout
        # of 60 seconds). We typically shouldn't encounter this due to increasing the worker
        # timeout.
        #
        # Log example:
        # ```
        # [debug | AWSClusterManagers]: Worker connected from node B
        # [debug | AWSClusterManagers]: Worker connected from node A
        # ...
        # [debug | AWSClusterManagers]: All workers have successfully reported in
        # Worker X terminated.
        # Worker Y terminated.
        # ...
        # <manager stalled>
        # ```

        job = BATCH_NODE_JOBS["test-worker-timeout"]

        manager_job = BatchJob(job.id * "#0")
        early_worker_job = BatchJob(job.id * "#1")
        late_worker_job = BatchJob(job.id * "#2")

        wait_finish(job)

        test_results = [
            @test status(manager_job) == AWSBatch.SUCCEEDED
            @test status(early_worker_job) == AWSBatch.SUCCEEDED
            @test status(late_worker_job) == AWSBatch.SUCCEEDED
        ]

        if any(r -> !(r isa Test.Pass), test_results)
            @info "Details for manager:\n$(report(manager_job))"
            @info "Details for early worker:\n$(report(early_worker_job))"
            @info "Details for late worker:\n$(report(late_worker_job))"
        end
    end
end
