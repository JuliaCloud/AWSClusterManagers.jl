using Mocking
Mocking.enable(force=true)

using AWSBatch
using AWSClusterManagers
using AWSTools
using AWSTools.Docker
using AWSTools.CloudFormation: stack_output
using Base.Test

import Base: AbstractCmd
import AWSClusterManagers: launch_timeout, num_workers

include("testutils.jl")
using .TestUtils

const PKG_DIR = abspath(@__DIR__, "..")

# Run the tests on a stack created with the "test/batch.yml" CloudFormation template
const AWS_STACKNAME = get(ENV, "AWS_STACKNAME", "")

# Enables the running of the "docker" and "batch" online tests. e.g ONLINE=docker,batch
const ONLINE = strip.(split(get(ENV, "ONLINE", ""), r"\s*,\s*"))

const GIT_DIR = joinpath(@__DIR__, "..", ".git")
const REV = try
    readchomp(`git --git-dir $GIT_DIR rev-parse --short HEAD`)
catch
    # Fallback to using the full SHA when git is not installed
    LibGit2.with(LibGit2.GitRepo(GIT_DIR)) do repo
        string(LibGit2.GitHash(LibGit2.GitObject(repo, "HEAD")))
    end
end

const STACK = isempty(AWS_STACKNAME) ? LEGACY_STACK : stack_output(AWS_STACKNAME)
const ECR = first(split(STACK["EcrUri"], ':'))
const ECR_IMAGE = "$ECR:$REV"


"""
Build the Docker image used for AWSDockerManager tests.
"""
function docker_manager_build(image=ECR_IMAGE)
    # If this code is being executed from within a Docker container assume that the current
    # image can be used as the image for the manager.
    if !isempty(AWSClusterManagers.container_id())
        return AWSClusterManagers.image_id()
    end

    if Docker.login()
        # Pull the latest "julia-baked:0.6" on the local system
        # TODO: If pulling fails we should still try and build the image as we may have a
        # local copy of the image.
        Docker.pull(
            "292522074875.dkr.ecr.us-east-1.amazonaws.com/julia-baked:0.6",
            ["julia-baked:0.6"],
        )
    end

    Docker.build(PKG_DIR, image)

    return image
end

"""
Build the Docker image used for AWSBatchManager tests and push it to ECR.
"""
function batch_manager_build(image=ECR_IMAGE)
    # Pull in the latest "julia-baked:0.6" for building the AWSClusterManagers Docker image.
    # If we cannot login we'll attempt to use base image that is currently available.
    if Docker.login()
        Docker.pull(
            "292522074875.dkr.ecr.us-east-1.amazonaws.com/julia-baked:0.6",
            ["julia-baked:0.6"],
        )
    end

    Docker.build(PKG_DIR, image)

    # Push the image to ECR. Note: this step is what requires `image` to be a full URI
    Docker.login()
    Docker.push(image)

    # Temporary
    # run(`aws batch update-compute-environment --compute-environment Demo --compute-resources desiredvCpus=4`)

    return image
end

@testset "AWSClusterManagers" begin
    include("container.jl")
    include("docker.jl")
    include("batch.jl")
end
