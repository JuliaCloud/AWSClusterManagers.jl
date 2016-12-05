module OverlayCluster

import Lumberjack: debug, info

using AWSClusterManagers.OverlayNetwork
import AWSClusterManagers.OverlayNetwork: DEFAULT_HOST, DEFAULT_PORT

export OverlayClusterManager, start_worker, aws_batch_launcher, num_processes

include("message.jl")
include("batch.jl")
include("manager.jl")
include("worker.jl")

end
