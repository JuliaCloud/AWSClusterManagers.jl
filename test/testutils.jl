module TestUtils

using JSON
using IterTools
import Base: AbstractCmd, CmdRedirect

export LEGACY_STACK, docker_login, docker_pull, docker_push, docker_build, stack_outputs,
    AWSBatchJobDefinition, register, deregister, submit, status, log_messages, details,
    time_str, Running, Succeeded, ignore_stderr

const PKG_DIR = abspath(@__DIR__, "..")

const LEGACY_STACK = Dict(
    "ManagerJobQueue"   => "Replatforming-Manager",     # Can be the name or ARN
    "WorkerJobQueue"    => "Replatforming-Worker",      # Can be the name or ARN
    "JobDefinitionName" => "aws-cluster-managers-test",
    "JobName"           => "aws-cluster-managers-test",
    "JobRoleArn"        => "arn:aws:iam::292522074875:role/AWSBatchClusterManagerJobRole",
    "RepositoryURI"     => "292522074875.dkr.ecr.us-east-1.amazonaws.com/aws-cluster-managers-test",
)


function docker_login(registry_ids::Vector{<:Integer}=Int[])
    # Runs `aws ecr get-login`, then extracts and runs the returned `docker login`
    # command (or `$(aws ecr get-login --region us-east-1)` in bash).
    # Note: using `--registry-ids` doesn't cause a login to fail if you don't have access.
    output = readchomp(`aws ecr get-login --no-include-email`)
    docker_login = Cmd(map(String, split(output)))
    success(pipeline(docker_login, stdout=STDOUT, stderr=STDERR))
end

function docker_pull(image::AbstractString, tags::Vector{<:AbstractString}=String[])
    run(`docker pull $image`)
    for tag in tags
        run(`docker tag $image $tag`)
    end
end

function docker_push(image::AbstractString)
    run(`docker push $image`)
end

function docker_build(tag::AbstractString="")
    opts = isempty(tag) ? `` : `-t $tag`
    run(`docker build $opts $PKG_DIR`)
end

function stack_outputs(stack_name::AbstractString)
    output = readchomp(```
        aws cloudformation describe-stacks
            --stack-name $stack_name
            --query 'Stacks[].Outputs[]'
            --output text
        ```)
    stack = Dict(partition(split(output, r"[\n\t]"), 2))

    # Copy specific keys into a more generic name
    for k in ("ManagerJobQueue", "WorkerJobQueue")
        if haskey(stack, "$(k)Arn")
            stack[k] = stack["$(k)Arn"]
        elseif haskey(stack, "$(k)Name")
            stack[k] = stack["$(k)Name"]
        end
    end

    return stack
end


#####


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

struct AWSBatchJobDefinition
    name::AbstractString
    revision::Nullable{Int}
end

# Note: you can either use the job definition name or the ARN
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
    cmd = ```
        aws batch register-job-definition
            --job-definition-name $(job_definition.name)
            --type container
            --container-properties $(JSON.json(json))
        ```
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

struct AWSBatchJob
    id::AbstractString
end

function submit(job_definition::AWSBatchJobDefinition, job_name::AbstractString, job_queue::AbstractString)
    cmd = ```
        aws batch submit-job
            --job-definition $job_definition
            --job-name $job_name
            --job-queue $job_queue
        ```
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

function log_messages(job::AWSBatchJob)
    cmd = `aws batch describe-jobs --jobs $(job.id)`
    task_id, job_name = readstring(cmd) do output
        j = JSON.parse(output)
        task_id = last(rsplit(j["jobs"][1]["container"]["taskArn"], '/', limit=2))
        job_name = j["jobs"][1]["jobName"]
        (task_id, job_name)
    end

    # CloudWatch log stream name format:
    # http://docs.aws.amazon.com/batch/latest/userguide/job_states.html
    log_stream_name = "$job_name/default/$task_id"
    cmd = ```
        aws logs get-log-events
            --log-group-name "/aws/batch/job"
            --log-stream-name $log_stream_name
        ```
    return readstring(cmd) do output
        j = JSON.parse(output)
        join([event["message"] for event in j["events"]], '\n')
    end
end

function time_str(secs::Integer)
    @sprintf("%02d:%02d:%02d", div(secs, 3600), rem(div(secs, 60), 60), rem(secs, 60))
end

const describe_jobs_resp = """
{
    "jobs": [
        {
            "status": "SUBMITTED",
            "container": {
                "mountPoints": [],
                "image": "myproject",
                "environment": [],
                "vcpus": 2,
                "command": [
                    "sleep",
                    "60"
                ],
                "volumes": [],
                "memory": 1024,
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

"""
    Mock.readstring(cmd::AbstractCmd, pass::Bool=true)

Simple readstring wrapper for `AbstractCmd` types which aren't being actively mocked.
"""
readstring(cmd::AbstractCmd, pass::Bool=true) = Base.readstring(cmd)

"""
    Mock.readstring(cmd::Cmd, pass::Bool=true)

Currently, we mock the `aws batch describe-jobs` and `aws batch submit-job` commands.
When `pass` is false the `submit-job` command will return valid output, but the spawned job
will not bring up a worker process.
"""
function readstring(cmd::Cmd, pass::Bool=true)
    if "describe-jobs" in cmd.exec
        return describe_jobs_resp
    elseif "submit-job" in cmd.exec
        if pass
            overrides = JSON.parse(cmd.exec[end])
            script = join(overrides["command"][3:end], " ")
            @spawn run(Cmd(["julia", "-e", "$script"]))
        else
            @spawn run(Cmd(["julia", "-e", "println(STDERR, \"Failed to come online\")"]))
        end
        return submit_job_resp
    elseif "docker" in cmd.exec
        if pass
            @spawn run(Cmd(["julia", "-e", "$(cmd.exec[end])"]))
        else
            @spawn run(Cmd(["julia", "-e", "println(STDERR, \"Failed to come online\")"]))
        end
        return lowercase(randstring(12))
    else
        return Base.readstring(cmd)
    end
end

"""
    Mock.readstring(cmd::CmdRedirect, pass::Bool=true)

Mocks the CmdRedirect produced from ``pipeline(`curl http://169.254.169.254/latest/meta-data/placement/availability-zone`)``
to just return "us-east-1".
"""
function readstring(cmd::CmdRedirect, pass::Bool=true)
    cmd_exec = cmd.cmd.exec
    result = if cmd_exec[1] == "curl" && contains(cmd_exec[2], "availability-zone")
        return "us-east-1"
    else
        return Base.readstring(cmd)
    end
end

function ignore_stderr(body::Function)
    # Note: we could use /dev/null on linux systems
    stderr = Base.STDERR
    path, io = mktemp()
    redirect_stderr(io)
    try
        return body()
    finally
        redirect_stderr(stderr)
        rm(path)
    end
end

end  # module
