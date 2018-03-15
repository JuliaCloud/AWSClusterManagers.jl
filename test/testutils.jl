module TestUtils

using AWSBatch
using IterTools
using JSON
using Memento

import Base: AbstractCmd, CmdRedirect

export LEGACY_STACK, log_messages, time_str, ignore_stderr

const LEGACY_STACK = Dict(
    "ManagerJobQueue"   => "Replatforming-Manager",     # Can be the name or ARN
    "WorkerJobQueue"    => "Replatforming-Worker",      # Can be the name or ARN
    "JobDefinitionName" => "aws-cluster-managers-test",
    "JobName"           => "aws-cluster-managers-test",
    "JobRoleArn"        => "arn:aws:iam::292522074875:role/AWSBatchClusterManagerJobRole",
    "RepositoryURI"     => "292522074875.dkr.ecr.us-east-1.amazonaws.com/aws-cluster-managers-test",
)

logger = Memento.config("info"; fmt="[{level} | {name}]: {msg}")


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

"""
    log_messages(job::BatchJob) -> String

Gets the logs associated with an AWSBatch BatchJob and converts them to a String for regex
matching.
"""
function log_messages(job::BatchJob)
    events = logs(job)
    return join([event["message"] for event in events], '\n')
end

function time_str(secs::Integer)
    @sprintf("%02d:%02d:%02d", div(secs, 3600), rem(div(secs, 60), 60), rem(secs, 60))
end

const DESCRIBE_JOBS_RESP = """
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
                "ulimits": [],
                "jobRoleArn": "arn:aws:iam::012345678910:role/sleep60"
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

const SUBMIT_JOB_RESP = """
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

Mocks `readstring` for docker commands. When `pass` is false the command will return valid
output, but the command will not actually be executed.
"""
function readstring(cmd::Cmd, pass::Bool=true)
    if "docker" in cmd.exec
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

Mocks the CmdRedirect produced from
``pipeline(`curl http://169.254.169.254/latest/meta-data/placement/availability-zone`)``
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

"""
    Mock.describe_jobs(dict::Dict)

Mocks the `AWSSDK.describe_jobs` call in AWSBatch.
"""
function describe_jobs(dict::Dict)
    return JSON.parse(DESCRIBE_JOBS_RESP)
end

"""
    Mock.submit(job::BatchJob, pass::Bool=true)

Mocks the `AWSBatch.submit!(job)` call. When `pass` is false the command will return valid
output, but the spawned job will not bring up a worker process.
"""
function submit!(job::BatchJob, pass::Bool=true)
    if pass
        @spawn run(job.container.cmd)
        info(logger, "Submitted job $(job.name)::$(job.id).")
    else
        @spawn run(Cmd(["julia", "-e", "println(STDERR, \"Failed to come online\")"]))
    end
    return SUBMIT_JOB_RESP
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
