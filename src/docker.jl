# A complicated story
#
# It appears that working with unix sockets isn't well handled by Julia. We can definitely
# work with them at a low level but packages such as Requests.jl do not provide us with a
# way of informing them we are using a unix socket rather than a address/port. ..

# http://stackoverflow.com/questions/2149564/redirecting-tcp-traffic-to-a-unix-domain-socket-under-linux
# socat TCP-LISTEN:1234,bind=127.0.0.1,reuseaddr,fork,su=nobody,range=127.0.0.0/8 UNIX-CLIENT:/var/run/docker.sock
# nc -lk 1234 | nc -U /var/run/docker.sock

type DockerServer
    socket::Base.PipeEndpoint
end

DockerServer() = DockerServer(connect("/var/run/docker.sock"))

function api_version(docker::DockerServer)
    write(
        docker.socket,
        """
        GET /version HTTP/1.1
        Host: localhost
        User-Agent: AWSClusterManager/$VERSION
        Accept: application/json

        """
    )
end
