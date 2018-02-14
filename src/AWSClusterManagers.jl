module AWSClusterManagers

import Base: launch, manage, cluster_cookie
using Memento
using Mocking
using Compat: @__MODULE__

export ECSManager, AWSBatchManager, DockerManager

logger = get_logger(@__MODULE__)

include("job.jl")
include("container.jl")
include("batch.jl")
include("docker.jl")

end  # module
