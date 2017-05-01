# AWSClusterManagers
[![stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://doc.invenia.ca/invenia/AWSClusterManagers.jl/master)
[![latest](https://img.shields.io/badge/docs-latest-blue.svg)](https://doc.invenia.ca/invenia/AWSClusterManagers.jl/master)
[![build status](https://gitlab.invenia.ca/invenia/AWSClusterManagers.jl/badges/master/build.svg)](https://gitlab.invenia.ca/invenia/AWSClusterManagers.jl/commits/master)
[![coverage](https://gitlab.invenia.ca/invenia/AWSClusterManagers.jl/badges/master/coverage.svg)](https://gitlab.invenia.ca/invenia/AWSClusterManagers.jl/commits/master)

Julia cluster managers which run within the AWS infrastructure.

## Installation

In order to run AWSClusterManagers you'll need to have the [AWS CLI](https://aws.amazon.com/cli)
installed. The recommended way to to install this is to use PIP which will have the latest
version available versus what may be available on your system's package manager.

```bash
pip install awscli
aws configure
```

## AWS Batch Manager

The AWSBatchManager allows you to use the [AWS Batch](https://aws.amazon.com/batch/) service
as a Julia cluster. Requirements to use this cluster manager are:

* [AWS CLI](https://aws.amazon.com/cli) tools are installed and setup
* An IAM role is setup that allows `batch:SubmitJob` and `batch:DescribeJobs`
* A Docker image registered with [AWS ECR](https://aws.amazon.com/ecr/) which has Julia
  installed, AWSClusterManagers.jl, and the AWS CLI.

The AWSBatchManager requires that the running AWS Batch jobs are run using
["networkMode=host"](http://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definition_parameters.html#network_mode)
which is the default for AWS Batch. This is only mentioned for completeness.

### Example

Typical use of this package will take place from within an already running AWS Batch job.
We'll start by first registering a job definition which requires a registered ECR image and
an IAM role. Note that the job definition needs to only be registered once and can be
re-used for multiple job submissions.

```bash
aws batch register-job-definition --job-definition-name aws-batch-demo --type container --container-properties '
{
    "image": "000000000000.dkr.ecr.us-east-1.amazonaws.com/demo:latest",
    "vcpus": 1,
    "memory": 1024,
    "jobRoleArn": "arn:aws:iam::000000000000:role/AWSBatchClusterManagerJobRole",
    "command": [
        "julia", "-e", "import AWSClusterManagers: AWSBatchManager; addprocs(AWSBatchManager(3)); println(\"Num Procs: \", nprocs()); @everywhere id = myid(); for i in workers(); println(\"Worker $i: \", remotecall_fetch(() -> id, i)); end"
    ]
}'
```

Once the job definition has been registered we can then run the AWS Batch job. In order to
run a job you'll need to setup a compute environment with an associated a job queue:

```bash
aws batch submit-job --job-name aws-batch-demo --job-definition aws-batch-demo --job-queue aws-batch-queue
```
