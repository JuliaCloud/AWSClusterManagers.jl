using Mocking
Mocking.enable(force=true)

using AWSBatch
using AWSClusterManagers
using AWSTools.Docker
using AWSTools.CloudFormation: stack_output
using Dates
using Distributed
using LibGit2
using Memento
using Random
using Sockets
using Test

using Base: AbstractCmd
using AWSClusterManagers: launch_timeout, desired_workers

include("testutils.jl")
using .TestUtils
using .TestUtils: logger

const PKG_DIR = abspath(@__DIR__, "..")

# Enables the running of the "docker" and "batch" online tests. e.g ONLINE=docker,batch
const ONLINE = strip.(split(get(ENV, "ONLINE", ""), r"\s*,\s*"))

# Run the tests on a stack created with the "test/batch.yml" CloudFormation template
const AWS_STACKNAME = get(ENV, "AWS_STACKNAME", "")
const STACK = !isempty(AWS_STACKNAME) ? stack_output(AWS_STACKNAME) : Dict()
const ECR = !isempty(STACK) ? first(split(STACK["EcrUri"], ':')) : "aws-cluster-managers-test"

const GIT_DIR = joinpath(@__DIR__, "..", ".git")
const REV = if isdir(GIT_DIR)
    try
        readchomp(`git --git-dir $GIT_DIR rev-parse --short HEAD`)
    catch
        # Fallback to using the full SHA when git is not installed
        LibGit2.with(LibGit2.GitRepo(GIT_DIR)) do repo
            string(LibGit2.GitHash(LibGit2.GitObject(repo, "HEAD")))
        end
    end
else
    # Fallback when package is not a git repository. Only should occur when running tests
    # from inside a Docker container produced by the Dockerfile for this package.
    "latest"
end

const ECR_IMAGE = "$ECR:$REV"
const JULIA_BAKED_IMAGE = "468665244580.dkr.ecr.us-east-1.amazonaws.com/julia-baked:1.0.3"



function registry_id(image::AbstractString)
    m = match(r"^\d+", image)
    return m.match
end

"""
Build the Docker image used for AWSDockerManager tests.
"""
function docker_manager_build(image=ECR_IMAGE)
    # If this code is being executed from within a Docker container assume that the current
    # image can be used as the image for the manager.
    if !isempty(AWSClusterManagers.container_id())
        return AWSClusterManagers.image_id()
    end

    if Docker.login(registry_id(JULIA_BAKED_IMAGE))
        # Pull the "julia-baked" image onto the local system
        # TODO: If pulling fails we should still try and build the image as we may have a
        # local copy of the image.
        Docker.pull(JULIA_BAKED_IMAGE, [basename(JULIA_BAKED_IMAGE)])
    end

    Docker.build(PKG_DIR, image)

    return image
end

"""
Build the Docker image used for AWSBatchManager tests and push it to ECR.
"""
function batch_manager_build(image=ECR_IMAGE)
    # Pull in the "julia-baked" image for building the AWSClusterManagers Docker image.
    # If we cannot login we'll attempt to use base image that is currently available.
    if Docker.login(registry_id(JULIA_BAKED_IMAGE))
        Docker.pull(JULIA_BAKED_IMAGE, [basename(JULIA_BAKED_IMAGE)])
    end

    Docker.build(PKG_DIR, image)

    # Push the image to ECR. Note: this step is what requires `image` to be a full URI
    Docker.login(registry_id(image))
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
