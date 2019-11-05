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
                        "vcpus" => 1,
                        "memory" => 1024,  # MiB
                        "command" => [
                            "julia", "-e", manager_code,
                        ],
                    )
                ),
                Dict(
                    "targetNodes" => "1:",
                    "container" => Dict(
                        "image" => image,
                        "vcpus" => 1,
                        "memory" => 1024,  # MiB
                        "command" => [
                            "bash",
                            "-c",
                            "julia $bind_to -e \"$(escape_quote(worker_code))\"",
                        ],
                    )
                )
            ]
        )
    )
end

escape_quote(str::AbstractString) = replace(str, "\"" => "\\\"")


# AWS Batch parallel multi-node jobs will only run on on-demand clusters. When running
# on spot the jobs will remain stuck in the RUNNABLE state
let ce = describe_compute_environment(STACK["ComputeEnvironmentArn"])
    if ce["computeResources"]["type"] != "EC2"  # on-demand
        error(
            "Aborting as compute environment $(STACK["ComputeEnvironmentArn"]) is not " *
            "using on-demand instances which are required for AWS Batch multi-node " *
            "parallel jobs."
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
    BATCH_NODE_JOBS[job_name] = submit_job(
        job_name=job_name,
        job_definition=BATCH_NODE_JOB_DEF,
    )
end

let job_name = "test-worker-spawn-failure"
    overrides = Dict(
        "numNodes" => 2,
        "nodePropertyOverrides" => [
            Dict(
                "targetNodes" => "1:",
                "containerOverrides" => Dict(
                    "command" => ["bash", "-c", "exit 0"],
                )
            )
        ]
    )

    BATCH_NODE_JOBS[job_name] = submit_job(
        job_name=job_name,
        job_definition=BATCH_NODE_JOB_DEF,
        node_overrides=overrides,
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
                        setlevel!(getlogger("root"), "debug", recursive=true)
                        start_batch_node_worker()
                        """
                    ]
                )
            )
        ]
    )

    BATCH_NODE_JOBS[job_name] = submit_job(
        job_name=job_name,
        job_definition=BATCH_NODE_JOB_DEF,
        node_overrides=overrides,
    )
end

let job_name = "test-worker-link-local-bind-to"
    bind_to = "--bind-to \$(ip -o -4 addr list ecs-eth0 | awk '{print \$4}' | cut -d/ -f1)"
    worker_code = """
        using AWSClusterManagers, Memento
        setlevel!(getlogger("root"), "debug", recursive=true)
        start_batch_node_worker()
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
                        "julia $bind_to -e \"$(escape_quote(worker_code))\"",
                    ]
                )
            )
        ]
    )

    BATCH_NODE_JOBS[job_name] = submit_job(
        job_name=job_name,
        job_definition=BATCH_NODE_JOB_DEF,
        node_overrides=overrides,
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
                "containerOverrides" => Dict(
                    "command" => ["julia", "-e", manager_code]
                )
            )
        ]
    )

    BATCH_NODE_JOBS[job_name] = submit_job(
        job_name=job_name,
        job_definition=BATCH_NODE_JOB_DEF,
        node_overrides=overrides,
    )
end


@testset "AWSBatchNodeManager (online)" begin
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
            worker_logs = log_messages.(worker_jobs)
            @info "Job output for manager ($(manager_job)):\n$manager_log"
            @info "Job output for worker 1 ($(worker_jobs[1])):\n$(worker_logs[1])"
            @info "Job output for worker 2 ($(worker_jobs[1])):\n$(worker_logs[2])"
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
        worker_log = log_messages(worker_job)
        test_results = [
            @test occursin("Only 0 of the 1 workers job have reported in", manager_log)
            @test isempty(worker_log)
        ]

        # Display the logs for all the jobs if any of the log tests fail
        if any(r -> !(r isa Test.Pass), test_results)
            @info "Job output for manager ($(manager_job)):\n$manager_log"
            @info "Job output for worker ($(worker_job)):\n$(worker_log)"
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
        @test status(worker_job) == AWSBatch.FAILED

        manager_log = log_messages(manager_job)
        worker_log = log_messages(worker_job)
        test_results = [
            @test occursin("Only 0 of the 1 workers job have reported in", manager_log)
            @test occursin("Aborting due to use of link-local address", worker_log)
        ]

        # Display the logs for all the jobs if any of the log tests fail
        if any(r -> !(r isa Test.Pass), test_results)
            @info "Job output for manager ($(manager_job)):\n$manager_log"
            @info "Job output for worker ($(worker_job)):\n$(worker_log)"
        end
    end

    @testset "Worker using link-local bind-to address" begin
        # Accidentially specifying the link-local address in `--bind-to`.
        job = BATCH_NODE_JOBS["test-worker-link-local-bind-to"]

        manager_job = BatchJob(job.id * "#0")
        worker_job = BatchJob(job.id * "#1")

        wait_finish(job)

        @test status(manager_job) == AWSBatch.SUCCEEDED
        @test status(worker_job) == AWSBatch.FAILED

        manager_log = log_messages(manager_job)
        worker_log = log_messages(worker_job)
        test_results = [
            @test occursin("Only 0 of the 1 workers job have reported in", manager_log)
            @test occursin("Aborting due to use of link-local address", worker_log)
        ]

        # Display the logs for all the jobs if any of the log tests fail
        if any(r -> !(r isa Test.Pass), test_results)
            @info "Job output for manager ($(manager_job)):\n$manager_log"
            @info "Job output for worker ($(worker_job)):\n$(worker_log)"
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
            @info "Job output for manager ($(manager_job)):\n$manager_log"
            @info "Job output for worker ($(worker_job)):\n$(worker_log)"
        end
    end
end
