module Hydro_Planning

using SiennaPRASInterface
using PowerSystems
const PSY = PowerSystems
using HydroPowerSimulations  # This is now available because the extension loaded

# Overload or extend a function from your main package
function SiennaPRASInterface.run_hydro_planning(sys::PSY.System)
    println("Using HydroPowerSimulations.jl to generate energy/water budgets...")
    # Call HPS here
    # Add time series to HydroReservoir
    return nothing
end

end
