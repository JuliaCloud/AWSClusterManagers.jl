@testset "get_interface_addrs" begin
    results = AWSClusterManagers.get_interface_addrs()

    @test results isa Vector{AWSClusterManagers.InterfaceAddress}
    @test length(results) > 0
end
