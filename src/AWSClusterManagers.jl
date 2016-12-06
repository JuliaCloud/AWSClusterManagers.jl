module AWSClusterManagers

import Base: launch, manage, cluster_cookie
export LocalOverlayManager, launch, manage

# include("container.jl")
# include("ecs.jl")

include("OverlayManagers/OverlayManagers.jl")
using .OverlayManagers

end # module
