import AWSClusterManagers: launch_timeout, num_workers

test_container = Dict("vcpus" => 2, "memory" => 4000)

# Test inner constructor
<<<<<<< HEAD
mgr = AWSBatchManager(1, 2, "job-definition", "job-name", "job-queue", 1000, "us-east-1", 600)
=======
mgr = AWSBatchManager(1, 2, "job-definition", "job-name", "job-queue", test_container, "us-east-1", 600)
>>>>>>> Added overriding of the vcpus and memory in batch worker submissions.

@test mgr.min_workers == 1
@test mgr.max_workers == 2
@test mgr.job_definition == "job-definition"
@test mgr.job_name == "job-name"
@test mgr.job_queue == "job-queue"
<<<<<<< HEAD
@test mgr.job_memory == 1000
=======
@test mgr.job_container == test_container
>>>>>>> Added overriding of the vcpus and memory in batch worker submissions.
@test mgr.region == "us-east-1"
@test mgr.timeout == 600

@test launch_timeout(mgr) == 600
@test num_workers(mgr) == (1, 2)

# Test keyword support
mgr = AWSBatchManager(
    3,
    4,
    definition="d",
    name="n",
    queue="q",
<<<<<<< HEAD
    memory=1000,
=======
    container=test_container,
>>>>>>> Added overriding of the vcpus and memory in batch worker submissions.
    region="us-west-1",
    timeout=5
)

@test mgr.min_workers == 3
@test mgr.max_workers == 4
@test mgr.job_definition == "d"
@test mgr.job_name == "n"
@test mgr.job_queue == "q"
<<<<<<< HEAD
@test mgr.job_memory == 1000
=======
@test mgr.job_container == test_container
>>>>>>> Added overriding of the vcpus and memory in batch worker submissions.
@test mgr.region == "us-west-1"
@test mgr.timeout == 5

# Define the keywords definition, name, queue, and region to avoid calling AWSBatchJob which
# only works inside of batch jobs.
kwargs = Dict(
    :definition => "d",
    :name => "n",
    :queue => "q",
<<<<<<< HEAD
    :memory => 1000,
=======
    :container => test_container,
>>>>>>> Added overriding of the vcpus and memory in batch worker submissions.
    :region => "ca-central-1"
)

@test num_workers(AWSBatchManager(3:4; kwargs...)) == (3, 4)
@test_throws MethodError AWSBatchManager(3:1:4; kwargs...)
@test_throws MethodError AWSBatchManager(3:2:4; kwargs...)

@test num_workers(AWSBatchManager(5; kwargs...)) == (5, 5)

# Running outside of the environment of a AWS batch job
if haskey(ENV, "AWS_BATCH_JOB_ID")
    job = AWSBatchJob()
    mgr = AWSBatchManager(3)

    @test mgr.min_workers == 3
    @test mgr.max_workers == 3
    @test mgr.job_definition == job.definition
    @test mgr.job_name == job.name
    @test mgr.job_queue == job.queue
    @test mgr.region == job.region
    @test mgr.timeout == AWSClusterManagers.DEFAULT_TIMEOUT
else
    @test_throws KeyError AWSBatchManager(3)  # TODO: Custom error?
end
