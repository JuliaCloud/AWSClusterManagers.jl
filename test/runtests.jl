using Mocking
Mocking.enable(force=true)

using AWSClusterManagers
using Base.Test

import Base: AbstractCmd
import AWSClusterManagers: launch_timeout, num_workers, AWSBatchJob

include("testutils.jl")
using .TestUtils

# Report the AWS CLI version as API changes could be the cause of exceptions here.
# Note: `aws --version` prints to STDERR instead of STDOUT.
info(readstring(pipeline(`aws --version`, stderr=`cat`)))

const STACK_NAME = get(ENV, "STACK_NAME", "")
const ONLINE = strip.(split(get(ENV, "ONLINE", "docker"), r"\s*,\s*"))

const PKG_DIR = abspath(@__DIR__, "..")
const REV = cd(() -> readchomp(`git rev-parse --short HEAD`), PKG_DIR)
# const PUSHED = !isempty(cd(() -> readchomp(`git branch -r --contains $REV`), PKG_DIR))
#
# const DIRTY = let
#     difference = cd(() -> readchomp(`git diff --name-only`), PKG_DIR)
#     dirty_files = filter!(!isempty, split(difference, "\n"))
#     !isempty(filter(p -> !startswith(p, "test"), dirty_files))
# end

const STACK = isempty(STACK_NAME) ? LEGACY_STACK : stack_outputs(STACK_NAME)
const ECR_IMAGE = "$(STACK["RepositoryURI"]):$REV"



"""
Build the Docker image used for AWSDockerManager tests.
"""
function docker_manager_build(image=ECR_IMAGE)
    if docker_login()
        # Pull the latest "julia-baked:0.6" on the local system
        # TODO: If pulling fails we should still try and build the image as we may have a
        # local copy of the image.
        docker_pull(
            "292522074875.dkr.ecr.us-east-1.amazonaws.com/julia-baked:0.6",
            ["julia-baked:0.6"],
        )
    end

    docker_build(image)

    return image
end

"""
Build the Docker image used for AWSBatchManager tests and push it to ECR.
"""
function batch_manager_build(image=ECR_IMAGE)
    # Pull in the latest "julia-baked:0.6" for building the AWSClusterManagers Docker image.
    # If we cannot login we'll attempt to use base image that is currently available.
    if docker_login()
        docker_pull(
            "292522074875.dkr.ecr.us-east-1.amazonaws.com/julia-baked:0.6",
            ["julia-baked:0.6"],
        )
    end

    docker_build(image)

    # Push the image to ECR. Note: this step is what requires `image` to be a full URI
    docker_login()
    docker_push(image)

    # Temporary
    # run(`aws batch update-compute-environment --compute-environment Demo --compute-resources desiredvCpus=4`)

    return image
end

@testset "AWSClusterManagers" begin
    include("docker.jl")
    include("batch.jl")
end
