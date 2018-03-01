using Mocking
Mocking.enable(force=true)

using AWSClusterManagers
using AWSTools
using Base.Test

import Base: AbstractCmd
import AWSClusterManagers: launch_timeout, num_workers

include("testutils.jl")
using .TestUtils

const AWS_STACKNAME = get(ENV, "AWS_STACKNAME", "")
const ONLINE = strip.(split(get(ENV, "ONLINE", ""), r"\s*,\s*"))

const GIT_DIR = joinpath(@__DIR__, "..", ".git")
const REV = try
    readchomp(`git --git-dir $GIT_DIR rev-parse --short HEAD`)
catch
    "latest"  # Only needed as a fallback for when git isn't installed
end

const STACK = isempty(AWS_STACKNAME) ? LEGACY_STACK : stack_outputs(AWS_STACKNAME)
const ECR_IMAGE = "$(STACK["RepositoryURI"]):$REV"



"""
Build the Docker image used for AWSDockerManager tests.
"""
function docker_manager_build(image=ECR_IMAGE)
    # If this code is being executed from within a Docker container assume that the current
    # image can be used as the image for the manager.
    if !isempty(AWSClusterManagers.container_id())
        return AWSClusterManagers.image_id()
    end

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
    include("container.jl")
    include("docker.jl")
    include("batch.jl")
end
