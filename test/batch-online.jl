isdefined(:TestHelpers) || include("TestHelpers.jl")

import TestHelpers: IMAGE_DEFINITION, MANAGER_JOB_QUEUE, WORKER_JOB_QUEUE, JOB_DEFINITION, JOB_NAME
import TestHelpers: register, deregister, submit, status, log, details, time_str, Running, Succeeded

# Report the AWS CLI version as API changes could be the cause of exceptions here.
# Note: `aws --version` prints to STDERR instead of STDOUT.
info(readstring(pipeline(`aws --version`, stderr=`cat`)))

@testset "Spawn" begin
    info("Registering AWS batch job definition: $(JOB_DEFINITION.name)")
    num_workers = 3

    # Will be running the HEAD revision of the code remotely
    # Note: Pkg.checkout doesn't work on untracked branches / SHAs with Julia 0.5.1
    code = """
    Pkg.update()
    Pkg.clone("git@gitlab.invenia.ca:invenia/AWSClusterManagers.jl")
    cd(Pkg.dir("AWSClusterManagers"))
    run(`git checkout --detach $REV`)
    Pkg.resolve()
    Pkg.build("AWSClusterManagers")

    using Memento
    Memento.config("debug"; fmt="{msg}")
    import AWSClusterManagers: AWSBatchManager
    addprocs(AWSBatchManager($num_workers, queue="$WORKER_JOB_QUEUE"))
    println("NumProcs: ", nprocs())
    for i in workers()
        println("Worker \$i: ", remotecall_fetch(() -> ENV["AWS_BATCH_JOB_ID"], i))
    end
    """

    json = Dict(
        "image" => "292522074875.dkr.ecr.us-east-1.amazonaws.com/$IMAGE_DEFINITION:latest",
        "jobRoleArn" => "arn:aws:iam::292522074875:role/AWSBatchClusterManagerJobRole",
        "vcpus" => 1,
        "memory" => 1024,
        "command" => [
            "julia", "-e", replace(code, r"\n+", "; ")
        ]
    )

    job_def = register(JOB_DEFINITION, json)

    info("Submitting AWS Batch job")
    job = submit(job_def, JOB_NAME, MANAGER_JOB_QUEUE)

    # If no resources are available it could take around 5 minutes before the job is running
    info("Waiting for AWS Batch job $(job.id) to complete (~5 minutes)")
    while status(job) <= Running
        sleep(30)
    end

    # Remove the job definition as it is specific to a revision
    deregister(job_def)

    @test status(job) == Succeeded

    output = log(job)

    m = match(r"(?<=NumProcs: )\d+", output)
    num_procs = m !== nothing ? parse(Int, m.match) : -1
    spawned_jobs = Set(matchall(r"(?<=Spawning job: )[0-9a-f\-]+", output))
    reported_jobs = Set(matchall(r"(?<=Worker \d: )[0-9a-f\-]+", output))

    @test num_procs == num_workers + 1
    @test length(reported_jobs) == num_workers
    @test spawned_jobs == reported_jobs

    # Report some details about the job
    d = details(job)
    created_at = Dates.unix2datetime(d["createdAt"] / 1000)
    started_at = Dates.unix2datetime(d["startedAt"] / 1000)
    stopped_at = Dates.unix2datetime(d["stoppedAt"] / 1000)

    # TODO: Unless I'm forgetting something just extrating the seconds from the milliseconds
    # is awkward
    launch_duration = div(Dates.value(started_at - created_at), 1000)
    run_duration = div(Dates.value(stopped_at - started_at), 1000)

    info("Job launch duration: $(time_str(launch_duration))")
    info("Job run duration:    $(time_str(run_duration))")
end
