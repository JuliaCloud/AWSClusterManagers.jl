"""
    Mock

The Mock modules provides some basic mock methods for aws related commands.
"""
module Mock

import Base: AbstractCmd, CmdRedirect
import JSON

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

"""
    Mock.readstring(cmd::AbstractCmd, pass::Bool=true)

Simple readstring wrapper for `AbstractCmd` types which aren't being actively mocked.
"""
readstring(cmd::AbstractCmd, pass::Bool=true) = readstring(cmd)

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
            @spawn run(Cmd(["julia", "-e", "println(\"Failed to come online\")"]))
        end
        return submit_job_resp
    else
        return readstring(cmd)
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
        return readstring(cmd)
    end
end

end  # module
