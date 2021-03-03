using AWSBatch
using AWSClusterManagers
using AWSClusterManagers: desired_workers, launch_timeout
using AWSCore: AWSCore
using AWSTools.CloudFormation: stack_output
using AWSTools.Docker: Docker
using Base: AbstractCmd
using Dates
using Distributed
using JSON: JSON
using LibGit2
using Memento
using Memento.TestUtils: @test_log
using Mocking
using Printf: @sprintf
using Sockets
using Test

Mocking.activate()
const LOGGER = Memento.config!("info"; fmt="[{date} | {level} | {name}]: {msg}")

 # https://github.com/JuliaLang/julia/pull/32814
if VERSION < v"1.3.0-alpha.110"
    const TaskFailedException = ErrorException
end


const PKG_DIR = abspath(@__DIR__, "..")

# Enables the running of the "docker" and "batch" online tests. e.g ONLINE=docker,batch
const ONLINE = split(strip(get(ENV, "ONLINE", "")), r"\s*,\s*"; keepempty=false)

# Run the tests on a stack created with the "test/batch.yml" CloudFormation template
const STACK_NAME = get(ENV, "STACK_NAME", "")
const STACK = !isempty(STACK_NAME) ? stack_output(STACK_NAME) : Dict()
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

const TEST_IMAGE = "$ECR:$REV"

function registry_id(image::AbstractString)
    m = match(r"^\d+", image)
    return m.match
end

# Note: By building the Docker image prior to running any tests (instead of just before the
# image is required) we avoid having a Docker build log breaking up output from tests.
#
# Note: Users are expected to have Docker credential helpers setup such that images can be
# retrieved automatically. For details see:
# https://gitlab.invenia.ca/invenia/wiki/blob/master/setup/docker.md#repository-access
if !isempty(ONLINE)
    @info("Preparing Docker image for online tests")

    # If the AWSClusterManager tests are being executed from within a container we will
    # assume that the image currently in use should be used for online tests.
    if !isempty(AWSClusterManagers.container_id())
        run(`docker tag $(AWSClusterManagers.image_id()) $TEST_IMAGE`)
    else
        # Build using the system image on the CI
        build_args = if get(ENV, "CI", "false") == "true"
            # `--build-arg PKG_PRECOMPILE=true --build-arg CREATE_SYSIMG=true`
            ``
        else
            ``
        end

        run(`docker build -t $TEST_IMAGE $build_args $PKG_DIR`)
    end

    # Push the image to ECR if the online tests require it. Note: `TEST_IMAGE` is required
    # to be a full URI in order for the push operation to succeed.
    if !isempty(intersect(ONLINE, ["batch", "batch-node"]))
        Docker.push(TEST_IMAGE)
    end
end

include("utils.jl")

@testset "AWSClusterManagers" begin
    include("container.jl")
    include("docker.jl")
    include("batch.jl")
    include("socket.jl")

    if "docker" in ONLINE
        include("docker_online.jl")
    else
        warn(LOGGER) do
            "Environment variable \"ONLINE\" does not contain \"docker\". " *
            "Skipping online DockerManager tests."
        end
    end

    if "batch" in ONLINE && !isempty(STACK_NAME)
        include("batch_online.jl")
    else
        warn(LOGGER) do
            "Environment variable \"ONLINE\" does not contain \"batch\". " *
            "Skipping online AWSBatchManager tests."
        end
    end

    if "batch-node" in ONLINE && !isempty(STACK_NAME)
        include("batch_node_online.jl")
    else
        warn(LOGGER) do
            "Environment variable \"ONLINE\" does not contain \"batch-node\". " *
            "Skipping online AWSBatchNodeManager tests."
        end
    end
end
