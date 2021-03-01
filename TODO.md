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

## Review output from runtasks

The run tasks AWS command contains a section in the output for failures. We should probably
parse the output and ensure that their are no failed tasks.

```
{
    "failures": [
        {
            "reason": "RESOURCE:MEMORY", 
            "arn": "arn:aws:ecs:us-east-1:292522074875:container-instance/d6e98fba-83fe-4e52-9920-8d2bb8d5ff75"
        }
    ], 
    "tasks": []
}
```

One complication with failures from run-task is that we are already waiting for a set number of workers to contact us. One alternative is to only start listening to the number of workers that stated they were launching. Unfortunately since we cannot launch all worker at once we could end up being too slow to listen if all workers are listened to at the end. Probably the solution to this is to start listening to workers as we confirm they should be coming up.