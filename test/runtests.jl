using Mocking
Mocking.enable()

using AWSClusterManagers
using Base.Test

import Base: AbstractCmd
import AWSClusterManagers: launch_timeout, num_workers, AWSBatchJob

const ONLINE = get(ENV, "LIVE", "") in ("true", "1")

const PKG_DIR = abspath(dirname(@__FILE__), "..")

const REV = cd(() -> readchomp(`git rev-parse HEAD`), PKG_DIR)
const PUSHED = !isempty(cd(() -> readchomp(`git branch -r --contains $REV`), PKG_DIR))

const DIRTY = let
    difference = cd(() -> readchomp(`git diff --name-only`), PKG_DIR)
    dirty_files = filter!(!isempty, split(difference, "\n"))
    !isempty(filter(p -> !startswith(p, "test"), dirty_files))
end

"""
    online(f::Function)

Simply takes a function of test code to run if we are able to run things on AWS otherwise
prints some warnings about the tests being skipped.
"""
function online(f::Function)
    if ONLINE && PUSHED && !DIRTY
        # Report the AWS CLI version as API changes could be the cause of exceptions here.
        # Note: `aws --version` prints to STDERR instead of STDOUT.
        info(readstring(pipeline(`aws --version`, stderr=`cat`)))
        f()
    elseif !ONLINE
        warn("Environment variable \"LIVE\" is not set. Skipping online tests.")
    elseif !PUSHED
        warn("Commit $REV has not been pushed. Skipping online tests.")
    else
        warn("Working directory outside of \"test\" directory is dirty. Skipping online tests.")
    end
end

# Load the TestUtils.jl module
include("testutils.jl")

import TestUtils: IMAGE_DEFINITION, MANAGER_JOB_QUEUE, WORKER_JOB_QUEUE, JOB_DEFINITION, JOB_NAME
import TestUtils: register, deregister, submit, status, log, details, time_str, Running, Succeeded

@testset "AWSClusterManagers" begin
    # include("ecs.jl")
    include("docker.jl")
    include("batch.jl")
end
