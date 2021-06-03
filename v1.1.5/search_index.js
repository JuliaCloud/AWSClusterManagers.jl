var documenterSearchIndex = {"docs":
[{"location":"pages/api/#API","page":"API","title":"API","text":"","category":"section"},{"location":"pages/api/","page":"API","title":"API","text":"Modules = [AWSClusterManagers]\nPrivate = false\nPages = [\"AWSClusterManagers.jl\", \"docker.jl\", \"batch.jl\", \"container.jl\", \"ecs.jl\"]","category":"page"},{"location":"pages/api/#AWSClusterManagers.DockerManager","page":"API","title":"AWSClusterManagers.DockerManager","text":"DockerManager(num_workers; kwargs...)\n\nA cluster manager which spawns workers via a locally running Docker daemon service. Typically used on a single machine to debug multi-machine Julia code.\n\nIn order to make a local Docker cluster you'll need to have an available Docker image that has Julia, a version of AWSClusterManagers which includes DockerManager, and the docker cli all baked into the image.\n\nYou can then create a Docker container which is capable of spawning additional Docker containers via:\n\ndocker run –network=host -v /var/run/docker.sock:/var/run/docker.sock –rm -it <image> julia\n\nNote: The host networking is required for the containers to be able to intercommunicate. The Docker host's UNIX socket needs to be forwarded so we can allow the container to communicate with host Docker process.\n\nArguments\n\nnum_workers::Int: The number of workers to spawn\n\nKeywords\n\nimage::AbstractString: The docker image to run.\ntimeout::Second: The maximum number of seconds to wait for workers to become available before aborting.\n\nExamples\n\njulia> addprocs(DockerManager(4, \"myproject:latest\"))\n\n\n\n\n\n","category":"type"},{"location":"pages/api/#AWSClusterManagers.AWSBatchManager","page":"API","title":"AWSClusterManagers.AWSBatchManager","text":"AWSBatchManager(max_workers; kwargs...)\nAWSBatchManager(min_workers:max_workers; kwargs...)\nAWSBatchManager(min_workers, max_workers; kwargs...)\n\nA cluster manager which spawns workers via Amazon Web Services Batch service. Typically used within an AWS Batch job to add additional resources. The number of workers spawned may be potentially be lower than the requested max_workers due to resource contention. Specifying min_workers can allow the launch to succeed with less than the requested max_workers.\n\nArguments\n\nmin_workers::Int: The minimum number of workers to spawn or an exception is thrown\nmax_workers::Int: The number of requested workers to spawn\n\nKeywords\n\ndefinition::AbstractString: Name of the AWS Batch job definition which dictates properties of the job including the Docker image, IAM role, and command to run\nname::AbstractString: Name of the job inside of AWS Batch\nqueue::AbstractString: The job queue in which workers are submitted. Can be either the queue name or the Amazon Resource Name (ARN) of the queue. If not set will default to the environmental variable \"WORKERJOBQUEUE\".\nmemory::Integer: Memory limit (in MiB) for the job container. The container will be killed if it exceeds this value.\nregion::AbstractString: The region in which the API requests are sent and in which new worker are spawned. Defaults to \"us-east-1\". Available regions for AWS batch can be found in the AWS documentation.\ntimeout::Period: The maximum number of seconds to wait for workers to become available before attempting to proceed without the missing workers.\n\nExamples\n\njulia> addprocs(AWSBatchManager(3))  # Needs to be run from within a running AWS batch job\n\n\n\n\n\n","category":"type"},{"location":"assets/figures/README/","page":"-","title":"-","text":"The SVG diagrams in this folder were created with draw.io. The saved XML files are included in case you need to modify the diagrams for any reason, but please ensure that you save and copy the XML file for the modified diagram along with the new SVG(s).","category":"page"},{"location":"assets/figures/README/","page":"-","title":"-","text":"The diagrams exported with the *-light suffix are exported with \"Transparent Background\" enabled and \"Dark\" disabled. The *-dark suffix diagrams are exported with \"Transparent Background\" enabled and \"Dark\" enabled. Note that the \"Dark\" option only appears if you are using a dark theme in draw.io.","category":"page"},{"location":"pages/docker/#Docker","page":"Docker","title":"Docker","text":"","category":"section"},{"location":"pages/docker/","page":"Docker","title":"Docker","text":"The DockerManager allows you to simulate a multi-machine julia cluster using Docker containers. In the future, worker containers could be run across multiple hosts using docker swarm, but this is currently not a supported configuration.","category":"page"},{"location":"pages/docker/#Requirements","page":"Docker","title":"Requirements","text":"","category":"section"},{"location":"pages/docker/","page":"Docker","title":"Docker","text":"Docker\nA Docker image which has Julia, Docker andAWSClusterManagers.jl installed. A sample Dockerfile is provided in the root directory of this repository.","category":"page"},{"location":"pages/docker/#Usage","page":"Docker","title":"Usage","text":"","category":"section"},{"location":"pages/docker/","page":"Docker","title":"Docker","text":"In order to build the AWSClusterManagers docker container you should first build the julia-baked:0.6 docker image (or pull it down from ECR). More details on getting the julia-baked:0.6 image can be found in our Dockerfiles repository.","category":"page"},{"location":"pages/docker/","page":"Docker","title":"Docker","text":"docker build -t aws-cluster-managers-test:latest .\n\n# Optionally tag and push the image to ECR to share with others or for use with the AWSBatchManager.\n$(aws ecr get-login --region us-east-1)\ndocker tag aws-cluster-managers-test:latest 468665244580.dkr.ecr.us-east-1.amazonaws.com/aws-cluster-managers-test:latest\ndocker push 468665244580.dkr.ecr.us-east-1.amazonaws.com/aws-cluster-managers-test:latest","category":"page"},{"location":"pages/docker/#Overview","page":"Docker","title":"Overview","text":"","category":"section"},{"location":"pages/docker/","page":"Docker","title":"Docker","text":"(Image: Docker Managers)","category":"page"},{"location":"pages/docker/","page":"Docker","title":"Docker","text":"The client machine on the left (e.g., you laptop) begins by starting an interactive docker container using the image \"myproject\".","category":"page"},{"location":"pages/docker/","page":"Docker","title":"Docker","text":"docker run --network=host -v /var/run/docker.sock:/var/run/docker.sock --rm -it myproject:latest julia\n               _\n   _       _ _(_)_     |  A fresh approach to technical computing\n  (_)     | (_) (_)    |  Documentation: https://docs.julialang.org\n   _ _   _| |_  __ _   |  Type \"?help\" for help.\n  | | | | | | |/ _` |  |\n  | | |_| | | | (_| |  |  Version 0.6.0 (2017-06-19 13:05 UTC)\n _/ |\\__'_|_|_|\\__'_|  |\n|__/                   |  x86_64-amazon-linux\n\njulia>","category":"page"},{"location":"pages/docker/","page":"Docker","title":"Docker","text":"NOTE: We need to use --network=host -v /var/run/docker.sock:/var/run/docker.sock in order for the docker container to bring up worker containers.","category":"page"},{"location":"pages/docker/","page":"Docker","title":"Docker","text":"From here we can bring up worker machines and debug our multi-machine julia code.","category":"page"},{"location":"pages/docker/","page":"Docker","title":"Docker","text":"julia> import AWSClusterManagers: DockerManager\n\njulia> addprocs(DockerManager(4, \"myproject:latest\"))\n4-element Array{Int64,1}:\n 2\n 3\n 4\n 5\n\njulia> nprocs()\n5\n\njulia> for i in workers()\n           println(\"Worker $i: \", remotecall_fetch(() -> myid(), i))\n       end\nWorker 2: 2\nWorker 3: 3\nWorker 4: 4\nWorker 5: 5","category":"page"},{"location":"pages/docker/#Running-the-DockerManager-outside-of-a-container","page":"Docker","title":"Running the DockerManager outside of a container","text":"","category":"section"},{"location":"pages/docker/","page":"Docker","title":"Docker","text":"It's also possible to run the DockerManager outside of a container, so long as the host docker daemon is running and you're running the same version of julia (and packages) on the host.","category":"page"},{"location":"pages/design/#Design","page":"Design","title":"Design","text":"","category":"section"},{"location":"pages/design/","page":"Design","title":"Design","text":"A little background on the design of the ECSManager and why decisions were made the way they were.","category":"page"},{"location":"pages/design/","page":"Design","title":"Design","text":"ECS is fundamentally a way of running Docker containers on EC2. It is quite possible that multiple containers based upon the same image could be running on the same EC2 instance. Since Julia uses TCP connections to talk between the various processes we need to be careful not to use specific port to listen for connection as this would cause conflicts between containers running on the same image. The solution to this problem is to use a \"random\" port in the ephermal port range that is available.","category":"page"},{"location":"pages/design/","page":"Design","title":"Design","text":"Using an ephermal port solves the issue of running into port reservation conflicts but introduces a new issue of having the port number on the newly spawned containers not being deterministic by the process that launched them. Since Julia typically works by having the  manager connecting to the workers this is an issue. The solution implemented is to have the manager open a port to listen to and then include the address and port of itself as part of the task definition using container overrides. This way we can have the worker connect back to the manager.","category":"page"},{"location":"pages/design/","page":"Design","title":"Design","text":"Now Julia can use a variety of networking topologies (manager-to-worker or all-to-all). In order to use as much of the built in code as possible we just have the worker report it's address and port to the manager and then let the manager connect to the worker like in a  typical cluster manager.","category":"page"},{"location":"pages/design/#Networking-Mode","page":"Design","title":"Networking Mode","text":"","category":"section"},{"location":"pages/design/","page":"Design","title":"Design","text":"The current implementation makes use of Docker \"host\" networking. This type of networking means we are working directly with the instances network interface instead of having  a virtualized networking interface known as \"bridge\". The bridged networking is another way of handling the port reservation problem but leads to other complications including not  knowning the address of the instance in which the container is running. Without that information we cannot talk to containers running on separate instances.","category":"page"},{"location":"pages/design/","page":"Design","title":"Design","text":"Additionally, it has been stated that the \"host\" networking has higher performance and allows processes running within containers to reserve ports on the container host. Also, this allows us to access the host instance metadata via curl http://169.254.169.254/latest/meta-data/.","category":"page"},{"location":"pages/batch/#Batch","page":"Batch","title":"Batch","text":"","category":"section"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"The AWSBatchManager allows you to use the AWS Batch service as a Julia cluster.","category":"page"},{"location":"pages/batch/#Requirements","page":"Batch","title":"Requirements","text":"","category":"section"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"An IAM role is setup that allows batch:SubmitJob, batch:DescribeJobs, and batch:DescribeJobDefinitions\nA Docker image registered with AWS ECR which has Julia and AWSClusterManagers.jl installed.","category":"page"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"The AWSBatchManager requires that the running AWS Batch jobs are run using \"networkMode=host\" which is the default for AWS Batch. This is only mentioned for completeness.","category":"page"},{"location":"pages/batch/#Usage","page":"Batch","title":"Usage","text":"","category":"section"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"Let's assume we want to run the following script:","category":"page"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"# demo.jl\nusing AWSClusterManagers: AWSBatchManager\n\naddprocs(AWSBatchManager(4))\n\nprintln(\"Num Procs: \", nprocs())\n\n@everywhere id = myid()\n\nfor i in workers()\n    println(\"Worker $i: \", remotecall_fetch(() -> id, i))\nend","category":"page"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"The workflow for deploying it on AWS Batch will be:","category":"page"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"Build a docker container for your program.\nPush the container to ECR.\nRegister a new job definition which uses that container and specifies a command to run.\nSubmit a job to Batch.","category":"page"},{"location":"pages/batch/#Overview","page":"Batch","title":"Overview","text":"","category":"section"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"(Image: Batch Managers)","category":"page"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"The client machines on the left (e.g., your laptop) begin by pushing a docker image to ECR, registering a job definition, and submitting a cluster manager batch job. The cluster manager job (JobID: 9086737) begins executing julia demo.jl which immediately submits 4 more batch jobs (JobIDs: 4636723, 3957289, 8650218 and 7931648) to function as its workers. The manager then waits for the worker jobs to become available and register themselves with the manager by executing julia -e 'sock = connect(<manager_ip>, <manager_port>); Base.start_worker(sock, <cluster_cookie>)' in identical containers. Once the workers are available the remainder of the script sees them as ordinary julia worker processes (identified by the integer pid values shown in parentheses). Finally, the batch manager exits, releasing all batch resources, and writing all STDOUT & STDERR to CloudWatch logs for the clients to view or download.","category":"page"},{"location":"pages/batch/#Building-the-Docker-Image","page":"Batch","title":"Building the Docker Image","text":"","category":"section"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"To begin we'll want to build a docker image which contains:","category":"page"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"julia\nAWSClusterManagers\ndemo.jl","category":"page"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"Example:","category":"page"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"FROM julia-bin:1.0\n\nRUN julia -e 'using Pkg; Pkg.add(\"AWSClusterManagers\")'\nCOPY demo.jl .\n\nCMD [\"julia demo.jl\"]","category":"page"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"Now build the docker file with:","category":"page"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"docker build -t 000000000000.dkr.ecr.us-east-1.amazonaws.com/demo:latest .","category":"page"},{"location":"pages/batch/#Pushing-to-ECR","page":"Batch","title":"Pushing to ECR","text":"","category":"section"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"Now we want to get our docker image on ECR. Start by logging into the ECR service (this assumes your have awscli configured with the correct permissions):","category":"page"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"$(aws ecr get-login --region us-east-1)","category":"page"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"Now you should be able to push the image to ECR:","category":"page"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"docker push 000000000000.dkr.ecr.us-east-1.amazonaws.com/demo:latest","category":"page"},{"location":"pages/batch/#Registering-a-Job-Definition","page":"Batch","title":"Registering a Job Definition","text":"","category":"section"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"Let's register a job definition now.","category":"page"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"NOTE: Registering a batch job requires the ECR image (see above) and an IAM role to apply to the job. The AWSBatchManager requires that the IAM role have access to the following operations:","category":"page"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"batch:SubmitJob\nbatch:DescribeJobs\nbatch:DescribeJobDefinitions","category":"page"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"Example)","category":"page"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"aws batch register-job-definition --job-definition-name aws-batch-demo --type container --container-properties '\n{\n    \"image\": \"000000000000.dkr.ecr.us-east-1.amazonaws.com/demo:latest\",\n    \"vcpus\": 1,\n    \"memory\": 1024,\n    \"jobRoleArn\": \"arn:aws:iam::000000000000:role/AWSBatchClusterManagerJobRole\",\n    \"command\": [\"julia\", \"demo.jl\"]\n}'","category":"page"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"NOTE: A job definition only needs to be registered once and can be re-used for multiple job submissions.","category":"page"},{"location":"pages/batch/#Submitting-Jobs","page":"Batch","title":"Submitting Jobs","text":"","category":"section"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"Once the job definition has been registered we can then run the AWS Batch job. In order to run a job you'll need to setup a compute environment with an associated a job queue:","category":"page"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"aws batch submit-job --job-name aws-batch-demo --job-definition aws-batch-demo --job-queue aws-batch-queue","category":"page"},{"location":"pages/batch/#Running-AWSBatchManager-Locally","page":"Batch","title":"Running AWSBatchManager Locally","text":"","category":"section"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"While it is generally preferable to run the AWSBatchManager as a batch job, it can also be run locally. In this case, worker batch jobs would be submitted from your local machine and would need to connect back to your machine from Amazon's network. Unfortunately, this may result in networking bottlenecks if you're transferring large amounts of data between the manager (you local machine) and the workers (batch jobs).","category":"page"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"(Image: Batch Workers)","category":"page"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"As with the previous workflow, the client machine on the left begins by pushing a docker image to ECR (so the workers have access to the same code) and registers a job definition (if one doesn't already exist). The client machine then runs julia demo.jl as the cluster manager which immediately submits 4 batch jobs (JobIDs: 4636723, 3957289, 8650218 and 7931648) to function as its workers. The client machine waits for the worker machines to come online. Once the workers are available the remainder of the script sees them as ordinary julia worker processes (identified by the integer pid values shown in parentheses) for the remainder of the program execution.","category":"page"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"NOTE: Since the AWSBatchManager is not being run from within a batch job we need to give it some extra parameters when we create it.","category":"page"},{"location":"pages/batch/","page":"Batch","title":"Batch","text":"mgr = AWSBatchManager(\n    4,\n    definition=\"aws-batch-worker\",\n    name=\"aws-batch-worker\",\n    queue=\"aws-batch-queue\",\n    region=\"us-west-1\",\n    timeout=5\n)","category":"page"},{"location":"pages/ecs/#ECS-(EC2-Container-Service)","page":"ECS","title":"ECS (EC2 Container Service)","text":"","category":"section"},{"location":"pages/ecs/","page":"ECS","title":"ECS","text":"Meant for use within a ECS task which wants to spawn additional ECS tasks.","category":"page"},{"location":"pages/ecs/","page":"ECS","title":"ECS","text":"Requirements:","category":"page"},{"location":"pages/ecs/","page":"ECS","title":"ECS","text":"Task definition uses networkMode \"host\"\nSecurity groups allow ECS cluster containers to talk to each other in the ephemeral port range\nTasks have permission to execute \"ecs:RunTask\"\nImage which has julia, awscli, and this package installed","category":"page"},{"location":"pages/ecs/","page":"ECS","title":"ECS","text":"When a ECS task uses this manager there are several steps involved in setting up the new process. They are as follows:","category":"page"},{"location":"pages/ecs/","page":"ECS","title":"ECS","text":"Open a TCP server on a random port in the ephemeral range and start listening (manager)\nExecute \"ecs:RunTask\" with a task defintion overrides which spawns julia and connects to the manager via TCP. Run the start_worker function which will send the workers address and port to the manager via the TCP socket.\nThe manager now knows the workers address and stops the TCP server.\nUsing the address of the worker the manager connects to the worker like a typical cluster manager.","category":"page"},{"location":"#AWSClusterManagers","page":"Home","title":"AWSClusterManagers","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"(Image: CI) (Image: Bors enabled) (Image: codecov) (Image: Stable Documentation)","category":"page"},{"location":"","page":"Home","title":"Home","text":"Julia cluster managers which run within the AWS infrastructure.","category":"page"},{"location":"#Installation","page":"Home","title":"Installation","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"Pkg.add(\"AWSClusterManagers\")","category":"page"},{"location":"#Sample-Project-Architecture","page":"Home","title":"Sample Project Architecture","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"The details of how the AWSECSManager & AWSBatchManager will be described in more detail shortly, but we'll briefly summarizes a real world application archtecture using the AWSBatchManager.","category":"page"},{"location":"","page":"Home","title":"Home","text":"(Image: Batch Project)","category":"page"},{"location":"","page":"Home","title":"Home","text":"The client machines on the left (e.g., your laptop) begin by pushing a docker image to ECR, registering a job definition, and submitting a cluster manager batch job. The cluster manager job (JobID: 9086737) begins executing julia demo.jl which immediately submits 4 more batch jobs (JobIDs: 4636723, 3957289, 8650218 and 7931648) to function as its workers. The manager then waits for the worker jobs to become available and register themselves with the manager. Once the workers are available the remainder of the script sees them as ordinary julia worker processes (identified by the integer pid values shown in parentheses). Finally, the batch manager exits, releasing all batch resources, and writing all STDOUT & STDERR to CloudWatch logs for the clients to view or download and saving an program results to S3. The clients may then choose to view or download the logs/results at a later time.","category":"page"}]
}
