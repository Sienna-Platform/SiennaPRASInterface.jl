"""
Write PRAS dispatch problem output to a specific column of PowerFlowData (for batching).

This version writes to column t of the PowerFlowData matrices, allowing batched solving.

# Arguments
- `pf_data::PFS.PowerFlowData`: PowerFlows data structure to populate
- `dispatchproblem::PRASCore.Simulations.DispatchProblem`: PRAS dispatch problem with solution
- `pras_system::PRASCore.SystemModel`: PRAS system model
- `psy_system::PSY.System`: PowerSystems system
- `t::Int`: Current timestep (column index to write to)
- `state::PRASCore.Simulations.SystemState`: Current system state
- `generators_cache::Vector{PSY.Generator}`: Cache of generator objects
- `ramp_limits_cache::Vector{Union{Nothing, NamedTuple}}`: Cache of ramp limits
- `disaggregation_func::Function`: Function to disaggregate regional dispatch to generator-level dispatch
"""
function write_output_to_pf_data_column!(
    pf_data::PFS.PowerFlowData,
    dispatchproblem::PRASCore.Simulations.DispatchProblem,
    pras_system::PRASCore.SystemModel,
    psy_system::PSY.System,
    t::Int,
    state::PRASCore.Simulations.SystemState,
    generators_cache::Vector{PSY.Generator},
    ramp_limits_cache::Vector{Union{Nothing, NamedTuple{(:up, :down), Tuple{Float64, Float64}}}},
    disaggregation_func::Function,
)
    # Clear column t
    pf_data.bus_activepower_injection[:, t] .= 0.0
    pf_data.bus_activepower_withdrawals[:, t] .= 0.0
    pf_data.bus_reactivepower_injection[:, t] .= 0.0
    pf_data.bus_reactivepower_withdrawals[:, t] .= 0.0

    # Get regional dispatch from PRAS solution (dispatchable generation only)
    region_generation = get_generator_region_dispatch(pras_system, state, dispatchproblem, t)

    # Get fixed generation (non-dispatchable renewables)
    fixed_region_generation = get_generator_fixed_dispatch(pras_system, generators_cache, state, t)

    # Total generation includes both dispatchable and fixed
    total_region_generation = region_generation .+ fixed_region_generation

    # Disaggregate to per-generator dispatch using the specified disaggregation function
    current_generation = zeros(Float64, length(pras_system.generators.names))
    for (region_idx, gen_idxs) in enumerate(pras_system.region_gen_idxs)
        gen_dispatch = disaggregation_func(
            region_generation[region_idx],
            gen_idxs,
            pras_system,
            state,
            t,
            generators_cache,
            ramp_limits_cache,
        )

        # Store in global generator array
        for (local_idx, gen_idx) in enumerate(gen_idxs)
            current_generation[gen_idx] = gen_dispatch[local_idx]
        end
    end

    # Add fixed generation (non-dispatchable renewables)
    for region_idx in 1:length(pras_system.regions)
        gen_idxs = pras_system.region_gen_idxs[region_idx]
        for gen_idx in gen_idxs
            if !state.gens_available[gen_idx]
                continue
            end
            # Use cached generator object instead of get_component
            if isa(generators_cache[gen_idx], PSY.RenewableNonDispatch)
                current_generation[gen_idx] = pras_system.generators.capacity[gen_idx, t]
            end
        end
    end

    # Map generator dispatch to bus injections (write to column t)
    for gen_idx in 1:length(pras_system.generators.names)
        dispatch = current_generation[gen_idx]

        if dispatch <= 0.0
            continue
        end

        # Use cached generator object
        generator = generators_cache[gen_idx]

        # Get the bus this generator is connected to
        bus = PSY.get_bus(generator)
        bus_number = PSY.get_number(bus)

        # Get bus index in PowerFlowData
        bus_idx = get(pf_data.bus_lookup, bus_number, nothing)
        if isnothing(bus_idx)
            continue
        end

        # Add generation as active power injection (column t)
        pf_data.bus_activepower_injection[bus_idx, t] += dispatch
    end

    # Add loads as withdrawals from PRAS regional load data
    # Distribute regional loads proportionally to buses in each region
    for (region_idx, region_name) in enumerate(pras_system.regions.names)
        regional_load = pras_system.regions.load[region_idx, t]

        # Find all loads in this region
        # Get the area from PowerSystems
        area = PSY.get_component(PSY.Area, psy_system, region_name)
        if isnothing(area)
            continue
        end

        # Get all loads in this area
        loads_in_region = PSY.StaticLoad[]
        for load in PSY.get_components(PSY.StaticLoad, psy_system)
            load_bus = PSY.get_bus(load)
            load_area = PSY.get_area(load_bus)
            if !isnothing(load_area) && PSY.get_name(load_area) == region_name
                push!(loads_in_region, load)
            end
        end

        if isempty(loads_in_region)
            continue
        end

        # Calculate total max load in region for proportional distribution
        total_max_load_p = sum(PSY.get_max_active_power(l) for l in loads_in_region)
        total_max_load_q = sum(PSY.get_max_reactive_power(l) for l in loads_in_region)

        if total_max_load_p <= 0.0
            continue
        end

        # Distribute regional load proportionally to each load's max power
        for load in loads_in_region
            bus = PSY.get_bus(load)
            bus_number = PSY.get_number(bus)

            bus_idx = get(pf_data.bus_lookup, bus_number, nothing)
            if isnothing(bus_idx)
                continue
            end

            # Scale load proportionally
            load_max_p = PSY.get_max_active_power(load)
            load_max_q = PSY.get_max_reactive_power(load)

            load_p = regional_load * (load_max_p / total_max_load_p)
            load_q = regional_load * (load_max_q / total_max_load_p)  # Scale Q by same factor as P

            pf_data.bus_activepower_withdrawals[bus_idx, t] += load_p
            pf_data.bus_reactivepower_withdrawals[bus_idx, t] += load_q
        end
    end

    # Add storage charging as withdrawals and discharging as injections
    add_storage_to_powerflow_column!(pf_data, dispatchproblem, pras_system, psy_system, t, state)

    return nothing
end

"""
Add storage charging/discharging to power flow data column t.
"""
function add_storage_to_powerflow_column!(
    pf_data::PFS.PowerFlowData,
    dispatchproblem::PRASCore.Simulations.DispatchProblem,
    pras_system::PRASCore.SystemModel,
    psy_system::PSY.System,
    t::Int,
    state::PRASCore.Simulations.SystemState,
)
    # Get storage dispatch flows from PRAS solution
    edges = dispatchproblem.fp.edges

    # Process regular Storage devices
    for (stor_idx, stor_name) in enumerate(pras_system.storages.names)
        if !state.stors_available[stor_idx]
            continue
        end

        # Get charging flow (withdrawal from grid)
        charge_edge_idx = dispatchproblem.storage_charge_edges[stor_idx]
        charge_flow = edges[charge_edge_idx].flow

        # Get discharging flow (injection to grid)
        discharge_edge_idx = dispatchproblem.storage_discharge_edges[stor_idx]
        discharge_flow = edges[discharge_edge_idx].flow

        # Find the storage device in PowerSystems
        storage = PSY.get_component(PSY.Storage, psy_system, stor_name)
        if isnothing(storage)
            continue
        end

        # Get the bus this storage is connected to
        bus = PSY.get_bus(storage)
        bus_number = PSY.get_number(bus)
        bus_idx = get(pf_data.bus_lookup, bus_number, nothing)
        if isnothing(bus_idx)
            continue
        end

        # Add charging as withdrawal, discharging as injection (column t)
        pf_data.bus_activepower_withdrawals[bus_idx, t] += charge_flow
        pf_data.bus_activepower_injection[bus_idx, t] += discharge_flow
    end

    # Process GeneratorStorage devices (e.g., hydro with reservoirs)
    for (genstor_idx, genstor_name) in enumerate(pras_system.generatorstorages.names)
        if !state.genstors_available[genstor_idx]
            continue
        end

        # Get grid charging flow (withdrawal from grid)
        gridcharge_edge_idx = dispatchproblem.genstorage_gridcharge_edges[genstor_idx]
        gridcharge_flow = edges[gridcharge_edge_idx].flow

        # Get total grid injection flow (via totalgrid edge)
        totalgrid_edge_idx = dispatchproblem.genstorage_totalgrid_edges[genstor_idx]
        grid_injection_flow = edges[totalgrid_edge_idx].flow

        # Find the generator-storage device in PowerSystems
        genstorage = PSY.get_component(PSY.HydroGen, psy_system, genstor_name)
        if isnothing(genstorage)
            continue
        end

        # Get the bus this generator-storage is connected to
        bus = PSY.get_bus(genstorage)
        bus_number = PSY.get_number(bus)
        bus_idx = get(pf_data.bus_lookup, bus_number, nothing)
        if isnothing(bus_idx)
            continue
        end

        # Add charging as withdrawal, injection as generation (column t)
        pf_data.bus_activepower_withdrawals[bus_idx, t] += gridcharge_flow
        pf_data.bus_activepower_injection[bus_idx, t] += grid_injection_flow
    end

    return nothing
end

"""
Write PRAS dispatch problem output to PowerFlows.jl PowerFlowData structure (legacy single-timestep version).

This function maps the regional dispatch solution from PRAS to bus-level
injections and withdrawals in the PowerFlows data structure.

# Arguments
- `pf_data::PFS.PowerFlowData`: PowerFlows data structure to populate
- `dispatchproblem::PRASCore.Simulations.DispatchProblem`: PRAS dispatch problem with solution
- `pras_system::PRASCore.SystemModel`: PRAS system model
- `psy_system::PSY.System`: PowerSystems system
- `t::Int`: Current timestep
- `state::PRASCore.Simulations.SystemState`: Current system state
"""
function write_output_to_pf_data!(
    pf_data::PFS.PowerFlowData,
    dispatchproblem::PRASCore.Simulations.DispatchProblem,
    pras_system::PRASCore.SystemModel,
    psy_system::PSY.System,
    t::Int,
    state::PRASCore.Simulations.SystemState,
    generators_cache::Vector{PSY.Generator},
    ramp_limits_cache::Vector{Union{Nothing, NamedTuple{(:up, :down), Tuple{Float64, Float64}}}},
)
    # Clear previous data
    fill!(pf_data.bus_activepower_injection, 0.0)
    fill!(pf_data.bus_activepower_withdrawals, 0.0)
    fill!(pf_data.bus_reactivepower_injection, 0.0)
    fill!(pf_data.bus_reactivepower_withdrawals, 0.0)

    # Get regional dispatch from PRAS solution (dispatchable generation only)
    region_generation = get_generator_region_dispatch(pras_system, state, dispatchproblem, t)

    # Get fixed generation (non-dispatchable renewables)
    fixed_region_generation = get_generator_fixed_dispatch(pras_system, generators_cache, state, t)

    # Total generation includes both dispatchable and fixed
    total_region_generation = region_generation .+ fixed_region_generation

    # Disaggregate to per-generator dispatch using proportional allocation
    current_generation = zeros(Float64, length(pras_system.generators.names))
    for (region_idx, gen_idxs) in enumerate(pras_system.region_gen_idxs)
        # Use proportional disaggregation to distribute dispatchable generation
        gen_dispatch = proportional_disaggregation(
            region_generation[region_idx],
            gen_idxs,
            pras_system,
            state,
            t,
            generators_cache,
            ramp_limits_cache,
        )

        # Store in global generator array
        for (local_idx, gen_idx) in enumerate(gen_idxs)
            current_generation[gen_idx] = gen_dispatch[local_idx]
        end
    end

    # Add fixed generation (non-dispatchable renewables)
    for region_idx in 1:length(pras_system.regions)
        gen_idxs = pras_system.region_gen_idxs[region_idx]
        for gen_idx in gen_idxs
            if !state.gens_available[gen_idx]
                continue
            end
            # Use cached generator object instead of get_component
            if isa(generators_cache[gen_idx], PSY.RenewableNonDispatch)
                current_generation[gen_idx] = pras_system.generators.capacity[gen_idx, t]
            end
        end
    end

    # Map generator dispatch to bus injections
    for gen_idx in 1:length(pras_system.generators.names)
        dispatch = current_generation[gen_idx]

        if dispatch <= 0.0
            continue
        end

        # Use cached generator object
        generator = generators_cache[gen_idx]

        # Get the bus this generator is connected to
        bus = PSY.get_bus(generator)
        bus_number = PSY.get_number(bus)

        # Get bus index in PowerFlowData
        bus_idx = get(pf_data.bus_lookup, bus_number, nothing)
        if isnothing(bus_idx)
            continue
        end

        # Add generation as active power injection (column 1 for single timestep)
        pf_data.bus_activepower_injection[bus_idx, 1] += dispatch
    end

    # Add loads as withdrawals from PRAS regional load data
    # Distribute regional loads proportionally to buses in each region
    for (region_idx, region_name) in enumerate(pras_system.regions.names)
        regional_load = pras_system.regions.load[region_idx, t]

        # Find all loads in this region
        # Get the area from PowerSystems
        area = PSY.get_component(PSY.Area, psy_system, region_name)
        if isnothing(area)
            continue
        end

        # Get all loads in this area
        loads_in_region = PSY.StaticLoad[]
        for load in PSY.get_components(PSY.StaticLoad, psy_system)
            load_bus = PSY.get_bus(load)
            load_area = PSY.get_area(load_bus)
            if !isnothing(load_area) && PSY.get_name(load_area) == region_name
                push!(loads_in_region, load)
            end
        end

        if isempty(loads_in_region)
            continue
        end

        # Calculate total max load in region for proportional distribution
        total_max_load_p = sum(PSY.get_max_active_power(l) for l in loads_in_region)
        total_max_load_q = sum(PSY.get_max_reactive_power(l) for l in loads_in_region)

        if total_max_load_p <= 0.0
            continue
        end

        # Distribute regional load proportionally to each load's max power
        for load in loads_in_region
            bus = PSY.get_bus(load)
            bus_number = PSY.get_number(bus)

            bus_idx = get(pf_data.bus_lookup, bus_number, nothing)
            if isnothing(bus_idx)
                continue
            end

            # Scale load proportionally
            load_max_p = PSY.get_max_active_power(load)
            load_max_q = PSY.get_max_reactive_power(load)

            load_p = regional_load * (load_max_p / total_max_load_p)
            load_q = regional_load * (load_max_q / total_max_load_p)  # Scale Q by same factor as P

            pf_data.bus_activepower_withdrawals[bus_idx, 1] += load_p
            pf_data.bus_reactivepower_withdrawals[bus_idx, 1] += load_q
        end
    end

    # Add storage charging as withdrawals and discharging as injections
    # Storage charging withdraws power like a load, discharging injects like generation
    add_storage_to_powerflow!(pf_data, dispatchproblem, pras_system, psy_system, t, state)

    return nothing
end

"""
Add storage charging/discharging to power flow data.

Storage charging withdraws power from the grid (like a load).
Storage discharging injects power to the grid (like generation).
"""
function add_storage_to_powerflow!(
    pf_data::PFS.PowerFlowData,
    dispatchproblem::PRASCore.Simulations.DispatchProblem,
    pras_system::PRASCore.SystemModel,
    psy_system::PSY.System,
    t::Int,
    state::PRASCore.Simulations.SystemState,
)
    # Get storage dispatch flows from PRAS solution
    edges = dispatchproblem.fp.edges

    # Process regular Storage devices
    for (stor_idx, stor_name) in enumerate(pras_system.storages.names)
        if !state.stors_available[stor_idx]
            continue
        end

        # Get charging flow (withdrawal from grid)
        charge_edge_idx = dispatchproblem.storage_charge_edges[stor_idx]
        charge_flow = edges[charge_edge_idx].flow

        # Get discharging flow (injection to grid)
        discharge_edge_idx = dispatchproblem.storage_discharge_edges[stor_idx]
        discharge_flow = edges[discharge_edge_idx].flow

        # Find the storage device in PowerSystems
        storage = PSY.get_component(PSY.Storage, psy_system, stor_name)
        if isnothing(storage)
            continue
        end

        # Get the bus this storage is connected to
        bus = PSY.get_bus(storage)
        bus_number = PSY.get_number(bus)
        bus_idx = get(pf_data.bus_lookup, bus_number, nothing)
        if isnothing(bus_idx)
            continue
        end

        # Add charging as withdrawal, discharging as injection
        pf_data.bus_activepower_withdrawals[bus_idx, 1] += charge_flow
        pf_data.bus_activepower_injection[bus_idx, 1] += discharge_flow
    end

    # Process GeneratorStorage devices (e.g., hydro with reservoirs)
    for (genstor_idx, genstor_name) in enumerate(pras_system.generatorstorages.names)
        if !state.genstors_available[genstor_idx]
            continue
        end

        # Get grid charging flow (withdrawal from grid)
        gridcharge_edge_idx = dispatchproblem.genstorage_gridcharge_edges[genstor_idx]
        gridcharge_flow = edges[gridcharge_edge_idx].flow

        # Get total grid injection flow (via totalgrid edge)
        totalgrid_edge_idx = dispatchproblem.genstorage_totalgrid_edges[genstor_idx]
        grid_injection_flow = edges[totalgrid_edge_idx].flow

        # Find the generator-storage device in PowerSystems
        genstorage = PSY.get_component(PSY.HydroGen, psy_system, genstor_name)
        if isnothing(genstorage)
            continue
        end

        # Get the bus this generator-storage is connected to
        bus = PSY.get_bus(genstorage)
        bus_number = PSY.get_number(bus)
        bus_idx = get(pf_data.bus_lookup, bus_number, nothing)
        if isnothing(bus_idx)
            continue
        end

        # Add charging as withdrawal, injection as generation
        pf_data.bus_activepower_withdrawals[bus_idx, 1] += gridcharge_flow
        pf_data.bus_activepower_injection[bus_idx, 1] += grid_injection_flow
    end

    return nothing
end
