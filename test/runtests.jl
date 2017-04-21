using AWSClusterManagers
using Base.Test
import Lumberjack: remove_truck

remove_truck("console")  # Disable logging

# include("ecs.jl")
include("batch.jl")

# include("overlay_managers/util.jl")
# include("overlay_managers/transport.jl")
# include("overlay_managers/local.jl")
