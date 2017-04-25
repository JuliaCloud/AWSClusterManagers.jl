module TestHelpers

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

const IMAGE_DEFINITION = "aws-cluster-managers-test"
const JOB_DEFINITION = AWSBatchJobDefinition("aws-cluster-managers-test")
const JOB_NAME = JOB_DEFINITION.name
const MANAGER_JOB_QUEUE = "Replatforming-Manager"
const WORKER_JOB_QUEUE = "Replatforming-Worker"

end
