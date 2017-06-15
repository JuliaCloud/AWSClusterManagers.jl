import AWSClusterManagers: launch_timeout, num_workers, AWSBatchJob
import Base: AbstractCmd

const BATCH_ENVS = (
    "AWS_BATCH_JOB_ID" => "bcf0b186-a532-4122-842e-2ccab8d54efb",
    "AWS_BATCH_JQ_NAME" => "HighPriority"
)

# Test inner constructor
@testset "AWSBatchManager" begin
    @testset "Constructors" begin
        @testset "Inner" begin
            mgr = AWSBatchManager(
                1,
                2,
                "job-definition",
                "job-name",
                "job-queue",
                1000,
                "us-east-1",
                600
            )

            @test mgr.min_workers == 1
            @test mgr.max_workers == 2
            @test mgr.job_definition == "job-definition"
            @test mgr.job_name == "job-name"
            @test mgr.job_queue == "job-queue"
            @test mgr.job_memory == 1000
            @test mgr.region == "us-east-1"
            @test mgr.timeout == 600

            @test launch_timeout(mgr) == 600
            @test num_workers(mgr) == (1, 2)
        end
        @testset "Keyword" begin
            mgr = AWSBatchManager(
                3,
                4,
                definition="d",
                name="n",
                queue="q",
                memory=1000,
                region="us-west-1",
                timeout=5
            )

            @test mgr.min_workers == 3
            @test mgr.max_workers == 4
            @test mgr.job_definition == "d"
            @test mgr.job_name == "n"
            @test mgr.job_queue == "q"
            @test mgr.job_memory == 1000
            @test mgr.region == "us-west-1"
            @test mgr.timeout == 5
        end
        @testset "Kwargs" begin
            # Define the keywords definition, name, queue, and region to avoid
            # calling AWSBatchJob which only works inside of batch jobs.
            kwargs = Dict(
                :definition => "d",
                :name => "n",
                :queue => "q",
                :memory => 1000,
                :region => "ca-central-1"
            )

            @test num_workers(AWSBatchManager(3:4; kwargs...)) == (3, 4)
            @test_throws MethodError AWSBatchManager(3:1:4; kwargs...)
            @test_throws MethodError AWSBatchManager(3:2:4; kwargs...)

            @test num_workers(AWSBatchManager(5; kwargs...)) == (5, 5)
        end
        @testset "AWS Defaults" begin
            # Running outside of the environment of an AWS batch job
            if !haskey(ENV, "AWS_BATCH_JOB_ID")
                @test_throws KeyError AWSBatchManager(3)  # TODO: Custom error?
            end

            # Mock being run on an AWS batch job
            withenv(BATCH_ENVS...) do
                patch = @patch readstring(cmd::AbstractCmd) = Mock.readstring(cmd)

                apply(patch) do
                    job = AWSBatchJob()
                    mgr = AWSBatchManager(3)

                    @test mgr.min_workers == 3
                    @test mgr.max_workers == 3
                    @test mgr.job_definition == job.definition
                    @test mgr.job_name == job.name
                    @test mgr.job_queue == job.queue
                    @test mgr.region == job.region
                    @test mgr.timeout == AWSClusterManagers.DEFAULT_TIMEOUT

                    @test mgr == AWSBatchManager(3)
                end
            end
        end
    end
    @testset "Adding procs" begin
        @testset "Worker Succeeds" begin
            withenv(BATCH_ENVS...) do
                patch = @patch readstring(cmd::AbstractCmd) = Mock.readstring(cmd)

                apply(patch) do
                    # Bring up a single "worker"
                    procs = addprocs(AWSBatchManager(1))
                    @test length(procs) == 1
                    rmprocs(procs; waitfor=5.0)
                end
            end
        end
        @testset "Worker Timeout" begin
            withenv(BATCH_ENVS...) do
                patch = @patch readstring(cmd::AbstractCmd) = Mock.readstring(cmd, false)

                apply(patch) do
                    @test_throws ErrorException addprocs(AWSBatchManager(1; timeout=1.0))
                end
            end
        end
    end
end
