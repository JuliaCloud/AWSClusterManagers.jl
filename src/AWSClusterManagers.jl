module AWSClusterManagers

using Memento
using Mocking
using AWSBatch
using AWSBatch: max_vcpus
using JSON
using Compat: @__MODULE__, undef
using Compat.Sockets
using Compat.Dates
using Compat.Distributed
import Compat.Distributed: manage, launch

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
