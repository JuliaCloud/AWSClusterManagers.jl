using AWSClusterManagers
using Base.Test
import Lumberjack: remove_truck

remove_truck("console")  # Disable logging

include("util.jl")

# include("ecs.jl")
include("overlay_managers/transport.jl")
include("overlay_managers/local.jl")
