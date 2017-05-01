using AWSClusterManagers
using Base.Test

const PKG_DIR = abspath(dirname(@__FILE__), "..")
const REV = cd(() -> readchomp(`git rev-parse HEAD`), PKG_DIR)
const PUSHED = !isempty(cd(() -> readchomp(`git branch -r --contains $REV`), PKG_DIR))

# Ignore the test directory when checking for a dirty state.
difference = cd(() -> readchomp(`git diff --name-only`), PKG_DIR)
dirty_files = filter!(!isempty, split(difference, "\n"))
const DIRTY = !isempty(filter(p -> !startswith(p, "test"), dirty_files))

@testset "AWSClusterManagers" begin
    # include("ecs.jl")
    include("batch.jl")

    if PUSHED && !DIRTY
        include("batch-online.jl")
    elseif DIRTY
        warn("Skipping online tests working directory is dirty")
    else
        warn("Skipping online tests as commit $REV has not been pushed")
    end
end
