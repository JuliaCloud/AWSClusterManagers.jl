# Gets the logs messages associated with a AWSBatch BatchJob as a single string
function log_messages(job::BatchJob)
    events = log_events(job)
    return join([event.message for event in events], '\n')
end

function time_str(secs::Real)
    @sprintf("%02d:%02d:%02d", div(secs, 3600), rem(div(secs, 60), 60), rem(secs, 60))
end

function register_job_definition(job_definition::AbstractDict)
    output = AWSCore.Services.batch("POST", "/v1/registerjobdefinition", job_definition)
    return output["jobDefinitionArn"]
end

function submit_job(;
    job_name::AbstractString,
    job_definition::AbstractString,
    job_queue::AbstractString=STACK["WorkerJobQueueArn"],
    node_overrides::Dict=Dict(),
)
    options = Dict{String,Any}(
        "jobName" => job_name,
        "jobDefinition" => job_definition,
        "jobQueue" => job_queue,
    )

    if !isempty(node_overrides)
        options["nodeOverrides"] = node_overrides
    end

    print(JSON.json(options, 4))

    output = AWSCore.Services.batch("POST", "/v1/submitjob", options)
    return BatchJob(output["jobId"])
end

function describe_compute_environment(compute_environment::AbstractString)
    # Equivalent to running the following on the AWS CLI
    # ```
    # aws batch describe-compute-environments
    #   --compute-environments $(STACK["ComputeEnvironmentArn"])
    #   --query computeEnvironments[0]
    # ```
    output = AWSCore.Services.batch(
        "POST", "/v1/describecomputeenvironments",
        Dict("computeEnvironments" => [compute_environment]),
    )

    details = if !isempty(output["computeEnvironments"])
        output["computeEnvironments"][1]
    else
        nothing
    end

    return details
end

function wait_finish(job::BatchJob; timeout::Period=Minute(15))
    timeout_secs = Dates.value(Second(timeout))

    info(LOGGER, "Waiting for AWS Batch job to finish (~5 minutes)")
    start_time = time()
    # TODO: Disable logging from wait? Or at least emit timestamps
    wait(job, [AWSBatch.FAILED, AWSBatch.SUCCEEDED], timeout=timeout_secs)  # TODO: Support timeout as Period
    info(LOGGER, "Job duration: $(time_str(time() - start_time))")
    return nothing
end
