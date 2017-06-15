import AWSClusterManagers: launch_timeout, num_workers, AWSBatchJob

const describe_jobs_resp = """
{
    "jobs": [
        {
            "status": "SUBMITTED",
            "container": {
                "mountPoints": [],
                "image": "myproject",
                "environment": [],
                "vcpus": 1,
                "command": [
                    "sleep",
                    "60"
                ],
                "volumes": [],
                "memory": 128,
                "ulimits": []
            },
            "parameters": {},
            "jobDefinition": "sleep60",
            "jobQueue": "arn:aws:batch:us-east-1:012345678910:job-queue/HighPriority",
            "jobId": "bcf0b186-a532-4122-842e-2ccab8d54efb",
            "dependsOn": [],
            "jobName": "example",
            "createdAt": 1480483387803
        }
    ]
}
"""

const submit_job_resp = """
{
    "jobName": "example",
    "jobId": "876da822-4198-45f2-a252-6cea32512ea8"
}
"""

patch = @patch function readstring(cmd::Base.AbstractCmd)
    if isa(cmd, Cmd)
        if "describe-jobs" in cmd.exec
            return describe_jobs_resp
        elseif "submit-job" in cmd.exec
            overrides = JSON.parse(cmd.exec[end])
            script = join(overrides["command"][3:end], " ")
            println(script)
            @spawn run(Cmd(["julia", "-e", "$script"]))
            return submit_job_resp
        else
            throw(ArgumentError("Failed to patch readstring($cmd)"))
        end
    elseif isa(cmd, Base.CmdRedirect)
        cmd_exec = cmd.cmd.exec
        if cmd_exec[1] == "curl" && contains(cmd_exec[2], "availability-zone")
            return "us-east-1"
        else
            throw(ArgumentError("Failed to patch readstring($cmd)"))
        end
    else
        throw(ArgumentError("Failed to patch readstring($cmd)"))
    end
end

test_container = Dict("vcpus" => 2, "memory" => 4000)

# Test inner constructor
mgr = AWSBatchManager(1, 2, "job-definition", "job-name", "job-queue", 1000, "us-east-1", 600)

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

# Test keyword support
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

# Define the keywords definition, name, queue, and region to avoid calling AWSBatchJob which
# only works inside of batch jobs.
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

# Running outside of the environment of a AWS batch job
if !haskey(ENV, "AWS_BATCH_JOB_ID")
    @test_throws KeyError AWSBatchManager(3)  # TODO: Custom error?
end

try
    ENV["AWS_BATCH_JOB_ID"] = "bcf0b186-a532-4122-842e-2ccab8d54efb"
    ENV["AWS_BATCH_JQ_NAME"] = "HighPriority"

    apply(patch) do
        info("Mocked area.")
        job = AWSBatchJob()
        mgr = AWSBatchManager(3)

        @test mgr.min_workers == 3
        @test mgr.max_workers == 3
        @test mgr.job_definition == job.definition
        @test mgr.job_name == job.name
        @test mgr.job_queue == job.queue
        @test mgr.region == job.region
        @test mgr.timeout == AWSClusterManagers.DEFAULT_TIMEOUT

        @test mgr == AWSBatchManager(3)

        # Bring up a single "worker"
        procs = addprocs(AWSBatchManager(1))
        @test length(procs) == 1
        rmprocs(procs; waitfor=5.0)
    end
finally
    delete!(ENV, "AWS_BATCH_JOB_ID")
    delete!(ENV, "AWS_BATCH_JQ_NAME")
end
