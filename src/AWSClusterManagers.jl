module AWSClusterManagers

using AWSBatch
using AWSBatch: max_vcpus
using Dates
using Distributed
import Distributed: manage, launch
using JSON
using Memento
using Mocking
using Sockets

export ECSManager, AWSBatchManager, DockerManager

const logger = getlogger(@__MODULE__)

function __init__()
    # https://invenia.github.io/Memento.jl/latest/faq/pkg-usage.html
    Memento.register(logger)
end

include("container.jl")
include("batch.jl")
include("docker.jl")

end  # module
