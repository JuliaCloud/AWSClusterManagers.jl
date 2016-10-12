# AWSClusterManagers

[![Build Status](https://travis-ci.org/omus/AWSClusterManagers.jl.svg?branch=master)](https://travis-ci.org/omus/AWSClusterManagers.jl)

[![Coverage Status](https://coveralls.io/repos/omus/AWSClusterManagers.jl/badge.svg?branch=master&service=github)](https://coveralls.io/github/omus/AWSClusterManagers.jl?branch=master)

[![codecov.io](http://codecov.io/github/omus/AWSClusterManagers.jl/coverage.svg?branch=master)](http://codecov.io/github/omus/AWSClusterManagers.jl?branch=master)

Julia ClusterManagers which run withn the AWS infrastructure.

## ECS Manager

Meant for use within a ECS task which wants to spawn additional ECS tasks.

Requirements:
- Task definition uses networkMode "host"
- Security groups allow ECS cluster containers to talk to each other in the ephemeral port range
- Tasks have permission to execute "ecs:RunTask"
- Image which has julia, awscli, and this package installed

When a ECS task uses this manager there are several steps involved in setting up the new process. They are as follows:

1. Open a TCP server on a random port in the ephemeral range and start listening (manager)
2. Execute "ecs:RunTask" with a task defintion overrides which spawns julia and connects to the manager via TCP. Run the `start_worker` function which will send the workers address and port to the manager via the TCP socket.
3. The manager now knows the workers address and stops the TCP server.
4. Using the address of the worker the manager connects to the worker like a typical cluster manager.
