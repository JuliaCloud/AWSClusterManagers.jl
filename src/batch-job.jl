type AWSBatchJob
    id::String
    name::String
    definition::String
    queue::String
    region::String
end

function AWSBatchJob()
    # Variable names discovered by inspecting the AWS Batch job as a running ECS task
    job_id = ENV["AWS_BATCH_JOB_ID"]
    job_queue = ENV["AWS_BATCH_JQ_NAME"]

    # Get the zone information from the EC2 instance metadata.
    zone = readstring(pipeline(`curl http://169.254.169.254/latest/meta-data/placement/availability-zone`, stderr=DevNull))
    region = chop(zone)

    # Requires permissions to access to "batch:DescribeJobs"
    json = JSON.parse(readstring(`aws --region $region batch describe-jobs --jobs $job_id`))
    details = first(json["jobs"])

    AWSBatchJob(
        job_id,
        details["jobName"],
        details["jobDefinition"],
        job_queue,
        region,
    )
end
