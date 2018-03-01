module TestUtils

using AWSSDK
using AWSTools
using IterTools
using JSON
using Memento
using XMLDict

import Base: AbstractCmd, CmdRedirect
import AWSSDK.CloudFormation: describe_stacks
import AWSSDK.ECR: get_authorization_token

export LEGACY_STACK, docker_login, docker_pull, docker_push, docker_build, stack_outputs,
    log_messages, time_str, ignore_stderr

const PKG_DIR = abspath(@__DIR__, "..")

const LEGACY_STACK = Dict(
    "ManagerJobQueue"   => "Replatforming-Manager",     # Can be the name or ARN
    "WorkerJobQueue"    => "Replatforming-Worker",      # Can be the name or ARN
    "JobDefinitionName" => "aws-cluster-managers-test",
    "JobName"           => "aws-cluster-managers-test",
    "JobRoleArn"        => "arn:aws:iam::292522074875:role/AWSBatchClusterManagerJobRole",
    "RepositoryURI"     => "292522074875.dkr.ecr.us-east-1.amazonaws.com/aws-cluster-managers-test",
)

logger = Memento.config("info"; fmt="[{level} | {name}]: {msg}")


function docker_login(registry_ids::Vector{<:Integer}=Int[])
    # Gets the AWS ECR authorization token and runs the docker login command
    # Note: using `registryIds` doesn't cause a login to fail if you don't have access.
    resp = get_authorization_token()
    authorization_data = first(resp["authorizationData"])
    token = String(base64decode(authorization_data["authorizationToken"]))
    username, password = split(token, ':')
    endpoint = authorization_data["proxyEndpoint"]

    login = `docker login -u $username -p $password $endpoint`
    success(pipeline(login, stdout=STDOUT, stderr=STDERR))
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
    output = describe_stacks(Dict("StackName" => stack_name))
    stack = xml_dict(output["DescribeStacksResult"])["Stacks"]["member"]

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

"""
    log_messages(job::BatchJob) -> String

Gets the logs associated with an AWSTools BatchJob and converts them to a String for regex
matching.
"""
function log_messages(job::BatchJob)
    events = AWSTools.logs(job)
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

Mocks the `AWSSDK.describe_jobs` call in AWSTools.
"""
function describe_jobs(dict::Dict)
    return JSON.parse(DESCRIBE_JOBS_RESP)
end

"""
    Mock.submit(job::BatchJob, pass::Bool=true)

Mocks the `AWSTools.submit(job)` call. When `pass` is false the command will return valid
output, but the spawned job will not bring up a worker process.
"""
function submit(job::BatchJob, pass::Bool=true)
    if pass
        @spawn run(job.cmd)
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
