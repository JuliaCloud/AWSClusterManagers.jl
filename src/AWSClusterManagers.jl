module AWSClusterManagers

import Base: launch, manage, cluster_cookie
using Memento
using Mocking

export ECSManager, AWSBatchManager, DockerManager, BatchEnvironmentError

logger = get_logger(current_module())

include("job.jl")
include("container.jl")
include("batch.jl")
include("docker.jl")

end  # module
