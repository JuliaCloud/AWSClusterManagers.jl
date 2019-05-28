module AWSClusterManagers

using AWSBatch: JobQueue, max_vcpus, run_batch
using Dates: Dates, Period, Minute, Second
using Distributed: Distributed, ClusterManager, WorkerConfig, cluster_cookie, start_worker
using JSON: JSON
using Memento: Memento, getlogger, warn, notice, debug
using Mocking: Mocking, @mock
using Sockets: IPAddr, IPv4, @ip_str, accept, connect, listen, listenany

export AWSBatchManager, AWSBatchNodeManager, DockerManager, start_batch_node_worker

const LOGGER = getlogger(@__MODULE__)

function __init__()
    # https://invenia.github.io/Memento.jl/latest/faq/pkg-usage.html
    Memento.register(LOGGER)
end

include("compat.jl")
include("container.jl")
include("batch.jl")
include("batch_node.jl")
include("docker.jl")

end  # module
