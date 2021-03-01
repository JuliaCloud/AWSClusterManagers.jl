# Design

A little background on the design of the ECSManager and why decisions were made the way
they were.

ECS is fundamentally a way of running Docker containers on EC2. It is quite possible that
multiple containers based upon the same image could be running on the same EC2 instance.
Since Julia uses TCP connections to talk between the various processes we need to be careful
not to use specific port to listen for connection as this would cause conflicts between
containers running on the same image. The solution to this problem is to use a "random" port
in the ephermal port range that is available.

Using an ephermal port solves the issue of running into port reservation conflicts but
introduces a new issue of having the port number on the newly spawned containers not being
deterministic by the process that launched them. Since Julia typically works by having the 
manager connecting to the workers this is an issue. The solution implemented is to have the
manager open a port to listen to and then include the address and port of itself as part
of the task definition using [container overrides](http://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_StartTask.html).
This way we can have the worker connect back to the manager.

Now Julia can use a variety of networking topologies (manager-to-worker or all-to-all).
In order to use as much of the built in code as possible we just have the worker report it's
address and port to the manager and then let the manager connect to the worker like in a 
typical cluster manager.

## Networking Mode

The current implementation makes use of Docker "host" networking. This type of networking
means we are working directly with the instances network interface instead of having 
a virtualized networking interface known as "bridge". The bridged networking is another way
of handling the port reservation problem but leads to other complications including not 
knowning the address of the instance in which the container is running. Without that
information we cannot talk to containers running on separate instances.

Additionally, it has been stated that the "host" networking has [higher performance](http://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definition_parameters.html#network_mode)
and allows processes running within containers to reserve ports on the container host. Also,
this allows us to access the host instance metadata via `curl http://169.254.169.254/latest/meta-data/`.
