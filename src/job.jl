type AWSBatchJob
    id::String
    name::String
    definition::String
    container::Dict
    queue::String
    region::String
end

"""
    AWSBatchJob()

Perform introspection on the currently running AWS Batch job to discover details such as
the: job ID, job name, job definition name, job queue, and region.
"""
function AWSBatchJob()
    # Environmental variables set by the AWS Batch service. They were discovered by
    # inspecting the running AWS Batch job in the ECS task interface.
    job_id = ENV["AWS_BATCH_JOB_ID"]
    job_queue = ENV["AWS_BATCH_JQ_NAME"]

    # Get the zone information from the EC2 instance metadata.
    zone = @mock readstring(pipeline(`curl http://169.254.169.254/latest/meta-data/placement/availability-zone`; stderr=DevNull))
    region = chop(zone)

    # Requires permissions to access to "batch:DescribeJobs"
    json = JSON.parse(@mock readstring(`aws --region $region batch describe-jobs --jobs $job_id`))
    details = first(json["jobs"])

    AWSBatchJob(
        job_id,
        details["jobName"],
        details["jobDefinition"],
        details["container"],
        job_queue,
        region,
    )
end
