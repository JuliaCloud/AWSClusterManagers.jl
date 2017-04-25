using AWSClusterManagers
using Base.Test

@testset "AWSClusterManagers" begin
    # include("ecs.jl")
    include("batch.jl")
    include("batch-online.jl")
end
