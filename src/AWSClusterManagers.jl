module AWSClusterManagers

using AWSBatch: JobQueue, max_vcpus, run_batch
using Dates: Dates, Period, Minute, Second, Millisecond
using Distributed: Distributed, ClusterManager, WorkerConfig, cluster_cookie, start_worker
using JSON: JSON
using Memento: Memento, getlogger, warn, notice, info, debug
using Mocking: Mocking, @mock
using Sockets: IPAddr, IPv4, @ip_str, accept, connect, getipaddr, listen, listenany

export AWSBatchManager, AWSBatchNodeManager, DockerManager, start_batch_node_worker

const LOGGER = getlogger(@__MODULE__)

function __init__()
    # https://invenia.github.io/Memento.jl/latest/faq/pkg-usage.html
    Memento.register(LOGGER)
end

include("socket.jl")
include("container.jl")
include("batch.jl")
include("batch_node.jl")
include("docker.jl")

end  # module
