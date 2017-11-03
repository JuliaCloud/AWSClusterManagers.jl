using Mocking
Mocking.enable()

using AWSClusterManagers
using Base.Test

import Base: AbstractCmd
import AWSClusterManagers: launch_timeout, num_workers, AWSBatchJob

const ONLINE = get(ENV, "LIVE", "") in ("true", "1")

const PKG_DIR = abspath(dirname(@__FILE__), "..")

const REV = cd(() -> readchomp(`git rev-parse HEAD`), PKG_DIR)
# const PUSHED = !isempty(cd(() -> readchomp(`git branch -r --contains $REV`), PKG_DIR))
#
# const DIRTY = let
#     difference = cd(() -> readchomp(`git diff --name-only`), PKG_DIR)
#     dirty_files = filter!(!isempty, split(difference, "\n"))
#     !isempty(filter(p -> !startswith(p, "test"), dirty_files))
# end

# Load the TestUtils.jl module
include("testutils.jl")
using Main.TestUtils

const REPO_URI = "292522074875.dkr.ecr.us-east-1.amazonaws.com"
const ECR_IMAGE = "$REPO_URI/$IMAGE_DEFINITION:$REV"

"""
    online(f::Function)

Simply takes a function of test code to run if we are able to run things on AWS otherwise
prints some warnings about the tests being skipped.
"""
function online(f::Function)
    if ONLINE
        # Report the AWS CLI version as API changes could be the cause of exceptions here.
        # Note: `aws --version` prints to STDERR instead of STDOUT.
        info(readstring(pipeline(`aws --version`, stderr=`cat`)))
        # Build the docker image for live tests and push it to ecr
        cd(PKG_DIR) do
            # Runs `aws ecr get-login`, then extracts and runs the returned `docker login`
            # command (or `$(aws ecr get-login --region us-east-1)` in bash).
            output = readchomp(`aws ecr get-login --region us-east-1 --no-include-email`)
            run(Cmd(map(String, split(output))))

            # Pull the latest "julia-baked:0.6" on the local system
            run(`docker pull $REPO_URI/julia-baked:0.6`)
            run(`docker tag $REPO_URI/julia-baked:0.6 julia-baked:0.6`)

            # Build and push the AWSClusterManagers docker image
            run(`docker build -t $ECR_IMAGE .`)
            run(`docker push $ECR_IMAGE`)
        end
        # Run our live tests code
        f()
    else
        warn("Environment variable \"LIVE\" is not set. Skipping online tests.")
    end
end

@testset "AWSClusterManagers" begin
    include("docker.jl")
    include("batch.jl")
end
