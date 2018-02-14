module AWSClusterManagers

import Base: launch, manage, cluster_cookie
using Memento
using Mocking
using Compat: @__MODULE__

export ECSManager, AWSBatchManager, DockerManager, BatchEnvironmentError

const logger = getlogger(@__MODULE__)

function __init__()
    # https://invenia.github.io/Memento.jl/latest/faq/pkg-usage.html
    Memento.register(logger)
end

include("job.jl")
include("container.jl")
include("batch.jl")
include("docker.jl")

end  # module
