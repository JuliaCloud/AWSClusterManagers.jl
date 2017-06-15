module AWSClusterManagers

import Base: launch, manage, cluster_cookie
using Memento
using Mocking

export ECSManager, AWSBatchManager, DockerManager

logger = get_logger(current_module())

include("job.jl")
include("container.jl")
include("ecs.jl")
include("batch.jl")
include("docker.jl")

end  # module
