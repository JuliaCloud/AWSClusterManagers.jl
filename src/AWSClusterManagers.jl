module AWSClusterManagers

import Base: launch, manage, cluster_cookie

export ECSManager, AWSBatchManager
export AWSBatchOverlayManager, LocalOverlayManager

include("batch-job.jl")

include("container.jl")
include("ecs.jl")
include("batch.jl")

include("OverlayManagers/OverlayManagers.jl")

using .OverlayManagers

end  # module
