module TestUtils

using AWSBatch
using Compat.Distributed
using Compat.Printf
using Compat.Random
using IterTools
using JSON
using Memento

using AWSCore: AWSConfig
using Compat: occursin
using DataStructures: OrderedDict

import Base: AbstractCmd, CmdRedirect

export time_str, ignore_stderr

logger = Memento.config!("info"; fmt="[{level} | {name}]: {msg}")


"""
    read(f::Function, cmd::Cmd, String) -> Any

Read the entire STDOUT stream from the command object and passes it to a function for
processing. If any exception occurs within the given function the raw STDOUT will be dumped
before reporting the exception.
"""
function read(f::Function, cmd::Cmd, ::Type{String})
    output = Base.read(cmd, String)
    return try
        f(output)
    catch
        warn(logger, "Command output could not be processed:\n$output")
        rethrow()
    end
end

"""
    log_messages(job::BatchJob) -> String

Gets the logs associated with an AWSBatch BatchJob and converts them to a String for regex
matching.
"""
function log_messages(job::BatchJob)
    events = log_events(job)
    return join([event.message for event in events], '\n')
end

function time_str(secs::Real)
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

const DESCRIBE_JOBS_DEF_RESP = """
{
    "jobDefinitions" : [
        {
            "type": "container",
            "containerProperties": {
                "command": [
                    "sleep",
                    "60"
                ],
                "environment": [],
                "image": "myproject",
                "memory": 128,
                "mountPoints": [],
                "ulimits": [],
                "vcpus": 1,
                "volumes": [],
                "jobRoleArn": "arn:aws:iam::012345678910:role/sleep60"
            },
            "jobDefinitionArn": "arn:aws:batch:us-east-1:012345678910:job-definition/sleep60:1",
            "jobDefinitionName": "sleep60",
            "revision": 1,
            "status": "ACTIVE"
        }
    ]
}
"""

const SUBMIT_JOB_RESP = OrderedDict(
    "jobName" => "example",
    "jobId" => "876da822-4198-45f2-a252-6cea32512ea8",
)

"""
    Mock.read(cmd::AbstractCmd, String, pass::Bool=true)

Simple `read` wrapper for `AbstractCmd` types which aren't being actively mocked.
"""
read(cmd::AbstractCmd, ::Type{String}, pass::Bool=true) = Base.read(cmd, String)

"""
    Mock.read(cmd::Cmd, String, pass::Bool=true)

Mocks `read` for docker commands. When `pass` is false the command will return valid
output, but the command will not actually be executed.
"""
function read(cmd::Cmd, ::Type{String}, pass::Bool=true)
    if "docker" in cmd.exec
        if pass
            @spawn run(Cmd(["julia", "-e", "$(cmd.exec[end])"]))
        else
            code = """
                println(stderr, "Failed to come online")
                """
            @spawn run(Cmd(["julia", "-e", code]))
        end
        return lowercase(randstring(12))
    else
        return Base.read(cmd, String)
    end
end

"""
    Mock.read(cmd::CmdRedirect, String, pass::Bool=true)

Mocks the CmdRedirect produced from
``pipeline(`curl http://169.254.169.254/latest/meta-data/placement/availability-zone`)``
to just return "us-east-1a".
"""
function read(cmd::CmdRedirect, ::Type{String}, pass::Bool=true)
    cmd_exec = cmd.cmd.exec
    result = if cmd_exec[1] == "curl" && occursin("availability-zone", cmd_exec[2])
        return "us-east-1a"
    else
        return Base.read(cmd, String)
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
    Mock.describe_job_definitions(dict::Dict)

Mocks the `AWSSDK.describe_job_definitions` call in AWSBatch.
"""
function describe_job_definitions(dict::Dict)
    return JSON.parse(DESCRIBE_JOBS_DEF_RESP)
end

"""
    Mock.submit_job([f::Function], config::AWSConfig, d::AbstractArray)

Mocks the `AWSSDK.Batch.submit_job` call.
"""
submit_job

function submit_job(f::Function, config::AWSConfig, d::AbstractArray)
    @spawn f()
    return SUBMIT_JOB_RESP
end

function submit_job(config::AWSConfig, d::AbstractArray)
    # AWSSDK uses an Dict-like array
    cmd = Cmd(Dict(Dict(d)["containerOverrides"])["command"])
    @spawn run(cmd)
    return SUBMIT_JOB_RESP
end

function ignore_stderr(body::Function)
    # Note: we could use /dev/null on linux systems
    path, io = mktemp()
    try
        redirect_stderr(body, io)
    finally
        close(io)
        rm(path)
    end
end

end  # module
