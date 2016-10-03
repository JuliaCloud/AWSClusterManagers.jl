# TODO

The following is a list of items that are a mostly nice-to-haves.

## Bridge networking support

In order to work with bridge networking in ECS we need to use the ECS API more. The basics of how we could support bridged networking is:

1. Launch the worker tasks
2. Use the task IDs from the output of the launch and use `describe-tasks` to determine the host port used (when ephemeral is used)
3. Determine the address of the containers instance (container-id to instance-id to IP address)
4. Manager connects to workers using the information gathered

Additionally we probably want to be able to determine if a task is using "bridge" or "host" networking. We can easily determine which "networkMode" was used via `describe-task-definition`. Note, this may not be enough as the "networkMode" may be overridden. In that case we would have to check the task itself.


## Task introspection

Since tasks launch other tasks it would be good to have some kind of introspection available within a task to determine its own definition name. Note that [container agent introspection](http://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-agent-introspection.html) does exist but it deals with the container instance and not the containers themselves.

## TLS Sockets

Ideally we should be using a secure channel to talk betweek the ECS tasks.