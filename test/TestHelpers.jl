module TestHelpers

# Note: When support for Julia 0.5 is dropped the multiline single-backticks (`) should be
# replaced by triple-backticks (```).

using JSON

"""
    readstring(f::Function, cmd::Cmd) -> Any

Read the entire STDOUT stream from the command object and passes it to a function for
processing. If any exception occurs within the given function the raw STDOUT will be dumped
before reporting the exception.
"""
function readstring(f::Function, cmd::Cmd)
    output = Base.readstring(cmd)
    return try
        f(output)
    catch
        warn("Command output could not be processed:\n$output")
        rethrow()
    end
end

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
    cmd = `aws batch describe-job-definitions --job-definition-name $(job_definition.name)`
    return readstring(cmd) do output
        j = JSON.parse(cmd)
        active_definitions = filter!(d -> d["status"] == "ACTIVE", get(j, "jobDefinitions", []))
        !isempty(active_definitions)
    end
end

function register(job_definition::AWSBatchJobDefinition, json::Dict)
    cmd = `
        aws batch register-job-definition
            --job-definition-name $(job_definition.name)
            --type container
            --container-properties $(JSON.json(json))
        `
    return readstring(cmd) do output
        j = JSON.parse(output)
        AWSBatchJobDefinition(j["jobDefinitionName"], j["revision"])
    end
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
    cmd = `
        aws batch submit-job
            --job-definition $job_definition
            --job-name $job_name
            --job-queue $job_queue
        `
    return readstring(cmd) do output
        j = JSON.parse(output)
        AWSBatchJob(j["jobId"])
    end
end

function details(job::AWSBatchJob)
    return readstring(`aws batch describe-jobs --jobs $(job.id)`) do output
        j = JSON.parse(output)
        j["jobs"][1]
    end
end

function status(job::AWSBatchJob)
    d = details(job)
    return parse(JobState, d["status"])
end

function log(job::AWSBatchJob)
    cmd = `aws batch describe-jobs --jobs $(job.id)`
    task_id, job_name = readstring(cmd) do output
        j = JSON.parse(output)
        task_id = last(rsplit(j["jobs"][1]["container"]["taskArn"], '/', limit=2))
        job_name = j["jobs"][1]["jobName"]
        (task_id, job_name)
    end

    log_stream_name = "$job_name/$(job.id)/$task_id"
    cmd = `
        aws logs get-log-events
            --log-group-name "/aws/batch/job"
            --log-stream-name $log_stream_name
        `
    return readstring(cmd) do output
        j = JSON.parse(output)
        join([event["message"] for event in j["events"]], '\n')
    end
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
