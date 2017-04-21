import AWSClusterManagers: launch_timeout, num_workers

# Test inner constructor
mgr = AWSBatchManager(1, 2, "job-definition", "job-name", "job-queue", "us-east-1", 600)

@test mgr.min_workers == 1
@test mgr.max_workers == 2
@test mgr.definition == "job-definition"
@test mgr.name == "job-name"
@test mgr.queue == "job-queue"
@test mgr.region == "us-east-1"
@test mgr.timeout == 600

@test launch_timeout(mgr) == 600
@test num_workers(mgr) == (1, 2)

# Test keyword support
mgr = AWSBatchManager(3, 4, definition="d", name="n", queue="q", region="us-west-1", timeout=5)

@test mgr.min_workers == 3
@test mgr.max_workers == 4
@test mgr.definition == "d"
@test mgr.name == "n"
@test mgr.queue == "q"
@test mgr.region == "us-west-1"
@test mgr.timeout == 5

# Define the keywords definition, name, queue, and region to avoid calling AWSBatchJob which
# only works inside of batch jobs.
kwargs = Dict(:definition => "d", :name => "n", :queue => "q", :region => "ca-central-1")

@test num_workers(AWSBatchManager(3:4; kwargs...)) == (3, 4)
@test_throws MethodError AWSBatchManager(3:1:4; kwargs...)
@test_throws MethodError AWSBatchManager(3:2:4; kwargs...)

@test num_workers(AWSBatchManager(5; kwargs...)) == (5, 5)


if haskey(ENV, "AWS_BATCH_JOB_ID")
    job = AWSBatchJob()
    mgr = AWSBatchManager(3)

    @test mgr.min_workers == 3
    @test mgr.max_workers == 3
    @test mgr.definition == job.definition
    @test mgr.name == job.name
    @test mgr.queue == job.queue
    @test mgr.region == job.region
    @test mgr.timeout == AWSClusterManagers.DEFAULT_TIMEOUT
else
    # Running outside of the environment of a AWS batch job
    @test_throws KeyError AWSBatchManager(3)  # TODO: Custom error?
end
