using AWSClusterManagers
using Base.Test

const PKG_DIR = abspath(dirname(@__FILE__), "..")
const REV = readchomp(`git -C $PKG_DIR rev-parse HEAD`)
const PUSHED = !isempty(readchomp(`git -C $PKG_DIR branch -r --contains $REV`))

# Ignore the test directory when checking for a dirty state.
dirty_files = filter!(!isempty, split(readchomp(`git -C $PKG_DIR diff --name-only`), "\n"))
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
