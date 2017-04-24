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
end

function isregistered(job_definition::AWSBatchJobDefinition)
    j = JSON.parse(readstring(`aws batch describe-job-definitions --job-definition-name $(job_definition.name)`))
    return !isempty(get(j, "jobDefinitions", []))
end

function register(job_definition::AWSBatchJobDefinition, json::Dict)
    return success(`
    aws batch register-job-definition
        --job-definition-name $(job_definition.name)
        --type container
        --container-properties $(JSON.json(json))
    `)
end

immutable AWSBatchJob
    id::AbstractString
end

function submit(job_definition::AWSBatchJobDefinition, job_name::AbstractString, job_queue::AbstractString)
    j = JSON.parse(readstring(`
    aws batch submit-job
        --job-definition $(job_definition.name)
        --job-name $job_name
        --job-queue $job_queue
    `))
    return AWSBatchJob(j["jobId"])
end

function status(job::AWSBatchJob)
    j = JSON.parse(readstring(`aws batch describe-jobs --jobs $(job.id)`))
    return parse(JobState, j["jobs"][1]["status"])
end

function log(job::AWSBatchJob)
    j = JSON.parse(readstring(`aws batch describe-jobs --jobs $(job.id)`))
    task_id = last(rsplit(j["jobs"][1]["container"]["taskArn"], '/', limit=2))
    job_name = j["jobs"][1]["jobName"]

    log_stream_name = "$job_name/$(job.id)/$task_id"
    j = JSON.parse(readstring(`aws logs get-log-events --log-group-name "/aws/batch/job" --log-stream-name $log_stream_name`))
    return join([event["message"] for event in j["events"]], '\n')
end


const IMAGE_DEFINITION = "aws-batch-cluster-test"
const JOB_DEFINITION = AWSBatchJobDefinition("aws-batch-cluster-test")
const JOB_NAME = JOB_DEFINITION.name
const MANAGER_JOB_QUEUE = "Replatforming-Manager"
const WORKER_JOB_QUEUE = "Replatforming-Worker"
const NUM_WORKERS = 3

if !isregistered(JOB_DEFINITION)
    info("Registering AWS batch job definition: $JOB_DEFINITION")

    code = """
    using Memento
    logger = Memento.config("debug"; fmt="{msg}")
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
            "julia", "-e", replace(code, '\n', "; ")
        ]
    )

    register(JOB_DEFINITION, json) || error("Unable to register $JOB_DEFINITION")
end

info("Submitting AWS Batch job")
job = submit(JOB_DEFINITION, JOB_NAME, MANAGER_JOB_QUEUE)

# If no resources are available it could take around 5 minutes before the job is running
info("Waiting for AWS Batch job $(job.id) to complete")
while status(job) <= Running
    sleep(30)
end

@test status(job) == Succeeded

output = log(job)
num_procs = parse(Int, match(r"(?<=NumProcs: )\d+", output).match)
spawned_jobs = Set(matchall(r"(?<=Spawning job: )[0-9a-f\-]+", output))
reported_jobs = Set(matchall(r"(?<=Worker \d: )[0-9a-f\-]+", output))

@test num_procs == NUM_WORKERS + 1
@test spawned_jobs == reported_jobs
