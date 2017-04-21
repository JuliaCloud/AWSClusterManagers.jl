In order for the broker to pass event messages (such as connect/disconnect) to nodes there needs to be shared communication framework that both the broker and the nodes understand. By introducing a "command" field we can make the broker aware of message types which gives the broker the ability to send event based messages. Additionally, the new "command" field would make it possible for us to formalize the registration process.

- The "connect" event allows the manager to listen for connecting workers. This eliminates the need for the HELLO_MSG

Questions
- Should the KILL_MSG be integrated into the new command field? Probably not as not all nodes respect this command


An attempt at the new message structure:

command codes:
- data    = 0x00
- event   = 0x01

0x00,src,dest,len,data
0x01,node,


NOTE: Talked to Mike and he suggested moving away from subscribing to events and move towards switching the broker from discarding messages to returning a HOST UNREACHABLE command to the source of the message.


src,dest,cmd,len,data

srd,dest,DATA,len,data
src,dest,HOST_UNREACHABLE
