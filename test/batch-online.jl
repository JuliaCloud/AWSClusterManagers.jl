using JSON

@enum JobState Submitted Pending Runnable Starting Running Failed Succeeded

function Base.parse(::Type{JobState}, s::AbstractString)
    for state in instances(JobState)
        if uppercase(string(state)) == s
            return state
        end
    end
    throw(ArgumentError("Invalid JobState given: \"$s\""))
end

immutable AWSBatchJobDefinition
    name::AbstractString
    revision::Nullable{Int}
end

AWSBatchJobDefinition(name::AbstractString) = AWSBatchJobDefinition(name, Nullable{Int}())
AWSBatchJobDefinition(name::AbstractString, rev::Int) = AWSBatchJobDefinition(name, Nullable{Int}(rev))

Base.string(d::AWSBatchJobDefinition) = isnull(d.revision) ? d.name : "$(d.name):$(get(d.revision))"

function isregistered(job_definition::AWSBatchJobDefinition)
    j = JSON.parse(readstring(`aws batch describe-job-definitions --job-definition-name $(job_definition.name)`))
    active_definitions = filter!(d -> d["status"] == "ACTIVE", get(j, "jobDefinitions", []))
    return !isempty(active_definitions)
end

function register(job_definition::AWSBatchJobDefinition, json::Dict)
    j = JSON.parse(readstring(`
    aws batch register-job-definition
        --job-definition-name $(job_definition.name)
        --type container
        --container-properties $(JSON.json(json))
    `))
    return AWSBatchJobDefinition(j["jobDefinitionName"], j["revision"])
end

function deregister(job_definition::AWSBatchJobDefinition)
    isnull(job_definition.revision) && error("Unable to deregister job definition without revision")
    # deregister has no output and the status appears to always be 0
    run(`aws batch deregister-job-definition --job-definition $job_definition`)
end

immutable AWSBatchJob
    id::AbstractString
end

function submit(job_definition::AWSBatchJobDefinition, job_name::AbstractString, job_queue::AbstractString)
    j = JSON.parse(readstring(`
    aws batch submit-job
        --job-definition $job_definition
        --job-name $job_name
        --job-queue $job_queue
    `))
    return AWSBatchJob(j["jobId"])
end

function details(job::AWSBatchJob)
    j = JSON.parse(readstring(`aws batch describe-jobs --jobs $(job.id)`))
    return j["jobs"][1]
end

function status(job::AWSBatchJob)
    d = details(job)
    return parse(JobState, d["status"])
end

function log(job::AWSBatchJob)
    j = JSON.parse(readstring(`aws batch describe-jobs --jobs $(job.id)`))
    task_id = last(rsplit(j["jobs"][1]["container"]["taskArn"], '/', limit=2))
    job_name = j["jobs"][1]["jobName"]

    log_stream_name = "$job_name/$(job.id)/$task_id"
    j = JSON.parse(readstring(`aws logs get-log-events --log-group-name "/aws/batch/job" --log-stream-name $log_stream_name`))
    return join([event["message"] for event in j["events"]], '\n')
end

function time_str(secs::Integer)
    @sprintf("%02d:%02d:%02d", div(secs, 3600), rem(div(secs, 60), 60), rem(secs, 60))
end

job_def = AWSBatchJobDefinition("aws-batch-cluster-test", 3)


const IMAGE_DEFINITION = "aws-cluster-managers-test"
const JOB_DEFINITION = AWSBatchJobDefinition("aws-cluster-managers-test")
const JOB_NAME = JOB_DEFINITION.name
const MANAGER_JOB_QUEUE = "Replatforming-Manager"
const WORKER_JOB_QUEUE = "Replatforming-Worker"
const NUM_WORKERS = 3

rev = readchomp(`git rev-parse HEAD`)
pushed = !isempty(readchomp(`git branch -r --contains $rev`))
dirty = !isempty(readchomp(`git diff --name-only`))

if pushed && !dirty
    info("Registering AWS batch job definition: $(JOB_DEFINITION.name)")

    # Will be running the HEAD revision of the code remotely
    # Note: Pkg.checkout doesn't work on untracked branches / SHAs with Julia 0.5.1
    code = """
    Pkg.update()
    Pkg.clone("git@gitlab.invenia.ca:invenia/AWSClusterManagers.jl")
    run(`git -C \$(Pkg.dir("AWSClusterManagers")) checkout --detach $rev`)
    Pkg.resolve()
    Pkg.build("AWSClusterManagers")

    using Memento
    Memento.config("debug"; fmt="{msg}")
    import AWSClusterManagers: AWSBatchManager
    addprocs(AWSBatchManager($NUM_WORKERS, queue="$WORKER_JOB_QUEUE"))
    println("NumProcs: ", nprocs())
    for i in workers()
        println("Worker \$i: ", remotecall_fetch(() -> ENV["AWS_BATCH_JOB_ID"], i))
    end
    """

    json = Dict(
        "image" => "292522074875.dkr.ecr.us-east-1.amazonaws.com/$IMAGE_DEFINITION:latest",
        "jobRoleArn" => "arn:aws:iam::292522074875:role/AWSBatchClusterManagerJobRole",
        "vcpus" => 1,
        "memory" => 1024,
        "command" => [
            "julia", "-e", replace(code, r"\n+", "; ")
        ]
    )

    job_def = register(JOB_DEFINITION, json)

    info("Submitting AWS Batch job")
    job = submit(job_def, JOB_NAME, MANAGER_JOB_QUEUE)

    # If no resources are available it could take around 5 minutes before the job is running
    info("Waiting for AWS Batch job $(job.id) to complete (~5 minutes)")
    while status(job) <= Running
        sleep(30)
    end

    # Remove the job definition as it is specific to a revision
    deregister(job_def)

    @test status(job) == Succeeded

    output = log(job)
    num_procs = parse(Int, match(r"(?<=NumProcs: )\d+", output).match)
    spawned_jobs = Set(matchall(r"(?<=Spawning job: )[0-9a-f\-]+", output))
    reported_jobs = Set(matchall(r"(?<=Worker \d: )[0-9a-f\-]+", output))

    @test num_procs == NUM_WORKERS + 1
    @test length(reported_jobs) == NUM_WORKERS
    @test spawned_jobs == reported_jobs

    # Report some details about the job
    d = details(job)
    created_at = Dates.unix2datetime(d["createdAt"] / 1000)
    started_at = Dates.unix2datetime(d["startedAt"] / 1000)
    stopped_at = Dates.unix2datetime(d["stoppedAt"] / 1000)

    # TODO: Unless I'm forgetting something just extrating the seconds from the milliseconds
    # is awkward
    launch_duration = div(Dates.value(started_at - created_at), 1000)
    run_duration = div(Dates.value(stopped_at - started_at), 1000)

    info("Job launch duration: $(time_str(launch_duration))")
    info("Job run duration:    $(time_str(run_duration))")
elseif dirty
    warn("Skipping online tests working directory is dirty")
else
    warn("Skipping online tests as commit $rev has not been pushed")
end
