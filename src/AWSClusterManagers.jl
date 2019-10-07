module AWSClusterManagers

using AWSBatch: JobQueue, max_vcpus, run_batch
using Dates: Dates, Period, Minute, Second
using Distributed: Distributed, ClusterManager, WorkerConfig, cluster_cookie
using JSON: JSON
using Memento: Memento, getlogger, warn, notice, debug
using Mocking: Mocking, @mock
using Sockets: IPv4, @ip_str, accept, listenany

export AWSBatchManager, DockerManager

const LOGGER = getlogger(@__MODULE__)

function __init__()
    # https://invenia.github.io/Memento.jl/latest/faq/pkg-usage.html
    Memento.register(LOGGER)
end

include("compat.jl")
include("container.jl")
include("batch.jl")
include("docker.jl")

end  # module
