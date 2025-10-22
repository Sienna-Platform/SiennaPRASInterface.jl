"""
Bias estimation between PRAS and Sienna models through importance sampling.

This module implements a workflow to estimate bias in shortfall events between
PRAS (probabilistic) and Sienna (detailed) power system models by:

1. Running PRAS sequential Monte Carlo simulations
2. Computing ramp rate violation metrics from PRAS results
3. Using importance sampling to preferentially test samples with high ramp violations
4. Running corresponding Sienna simulations with matched outage patterns
5. Comparing shortfall probabilities to estimate model bias

The key insight is that ramp rate violations in PRAS (which ignores ramping constraints)
are likely correlated with bias relative to Sienna (which enforces ramping constraints).

# Disaggregation Functions

Ramp violations are computed at the generator level by disaggregating regional dispatch
to individual generators. Users can provide custom disaggregation functions with signature:

```julia
function my_disaggregation(
    region_dispatch::Float64,
    gen_idxs::UnitRange{Int},
    system::PRASCore.SystemModel,
    state::PRASCore.Simulations.SystemState,
    t::Int,
)::Vector{Float64}
    # Return vector of length(gen_idxs) with dispatch for each generator
end
```
"""

using PowerSystems
using PRASCore: Period, PowerUnit, EnergyUnit, ZonedDateTime, StepRange
using TimeSeries
# Import PRAS types and interfaces
using PRASCore

using Dates: Hour, AbstractTime

const PSY = PowerSystems

# Import necessary functions from other modules in this package
import ..get_device_ramodel
import ..build_component_to_formulation
import ..generate_pras_system
import ..RATemplate
import ..SPIOutageResult

# Import cost evaluation utilities
include("util/cost_evaluation.jl")

"""
    DisaggregationFunction

Function type for disaggregating regional dispatch to individual generators.

# Arguments

  - `region_dispatch::Float64`: Total dispatch for the region
  - `gen_idxs::UnitRange{Int}`: Generator indices for the region
  - `system::PRASCore.SystemModel`: PRAS system model
  - `state::PRASCore.Simulations.SystemState`: Current system state
  - `t::Int`: Current timestep

# Returns

  - `Vector{Float64}`: Dispatch for each generator in gen_idxs
"""
const DisaggregationFunction = Function

"""
    proportional_disaggregation(region_dispatch, gen_idxs, system, state, t)

Default disaggregation: proportional to available capacity.

Distributes regional dispatch to generators based on their capacity share.
This is simple but tends to create more ramp violations than optimal dispatch.
"""
function proportional_disaggregation(
    region_dispatch::Float64,
    gen_idxs::UnitRange{Int},
    system::PRASCore.SystemModel,
    state::PRASCore.Simulations.SystemState,
    t::Int,
)
    gen_dispatch = zeros(Float64, length(gen_idxs))
    total_capacity = 0.0

    # Calculate total available capacity
    for (i, gen_idx) in enumerate(gen_idxs)
        if state.gens_available[gen_idx]
            total_capacity += system.generators.capacity[gen_idx, t]
        end
    end

    # Disaggregate proportionally
    if total_capacity > 0.0
        for (i, gen_idx) in enumerate(gen_idxs)
            if state.gens_available[gen_idx]
                capacity = system.generators.capacity[gen_idx, t]
                gen_dispatch[i] = region_dispatch * (capacity / total_capacity)
            end
        end
    end

    return gen_dispatch
end

"""
    merit_order_disaggregation(region_dispatch, gen_idxs, system, state, t, sys)

Merit order disaggregation: dispatch generators in order of marginal cost.

Dispatches the cheapest generators first up to their capacity, then moves to
more expensive generators. This is more realistic than proportional dispatch
and tends to create fewer ramp violations for baseload plants.

# Arguments

  - `region_dispatch::Float64`: Total dispatch needed for the region
  - `gen_idxs::UnitRange{Int}`: Generator indices for the region
  - `system::PRASCore.SystemModel`: PRAS system model
  - `state::PRASCore.Simulations.SystemState`: Current system state
  - `t::Int`: Current timestep
  - `sys::PSY.System`: PowerSystems system (for accessing cost data)

# Returns

  - `Vector{Float64}`: Dispatch for each generator in gen_idxs
"""
function merit_order_disaggregation(
    region_dispatch::Float64,
    gen_idxs::UnitRange{Int},
    system::PRASCore.SystemModel,
    state::PRASCore.Simulations.SystemState,
    t::Int,
    sys::PSY.System,
)
    gen_dispatch = zeros(Float64, length(gen_idxs))

    # Build list of available generators with their costs and capacities
    available_gens = Tuple{Int, Float64, Float64}[]  # (local_idx, marginal_cost, capacity)

    for (i, gen_idx) in enumerate(gen_idxs)
        if !state.gens_available[gen_idx]
            continue
        end

        gen_name = system.generators.names[gen_idx]
        capacity = system.generators.capacity[gen_idx, t]

        if capacity <= 0.0
            continue
        end

        # Get marginal cost from PowerSystems
        generator = PSY.get_component(PSY.Generator, sys, gen_name)
        marginal_cost = get_marginal_cost_at_max_power(generator)

        push!(available_gens, (i, marginal_cost, capacity))
    end

    sort!(available_gens, by=x -> x[2])
    remaining_dispatch = region_dispatch

    for (local_idx, cost, capacity) in available_gens
        if remaining_dispatch <= 0.0
            break
        end

        # Dispatch this generator up to its capacity
        dispatch = min(capacity, remaining_dispatch)
        gen_dispatch[local_idx] = dispatch
        remaining_dispatch -= dispatch
    end

    return gen_dispatch
end

"""
    ramp_aware_disaggregation(region_dispatch, gen_idxs, system, state, t, sys)

Ramp-aware disaggregation: dispatch generators in order of ramp capability.

Dispatches the most flexible generators (highest ramp rates) first, keeping
less flexible baseload units at steady output. This minimizes total ramp violations
by using the generators best suited to handle dispatch variations.

# Arguments

  - `region_dispatch::Float64`: Total dispatch needed for the region
  - `gen_idxs::UnitRange{Int}`: Generator indices for the region
  - `system::PRASCore.SystemModel`: PRAS system model
  - `state::PRASCore.Simulations.SystemState`: Current system state
  - `t::Int`: Current timestep
  - `sys::PSY.System`: PowerSystems system (for accessing ramp limit data)

# Returns

  - `Vector{Float64}`: Dispatch for each generator in gen_idxs
"""
function ramp_aware_disaggregation(
    region_dispatch::Float64,
    gen_idxs::UnitRange{Int},
    system::PRASCore.SystemModel,
    state::PRASCore.Simulations.SystemState,
    t::Int,
    sys::PSY.System,
)
    gen_dispatch = zeros(Float64, length(gen_idxs))

    # Build list of available generators with their ramp rates and capacities
    available_gens = Tuple{Int, Float64, Float64}[]  # (local_idx, min_ramp_rate_MW_per_min, capacity)

    for (i, gen_idx) in enumerate(gen_idxs)
        if !state.gens_available[gen_idx]
            continue
        end

        gen_name = system.generators.names[gen_idx]
        capacity = system.generators.capacity[gen_idx, t]

        if capacity <= 0.0
            continue
        end

        # Get ramp rates from PowerSystems
        generator = PSY.get_component(PSY.Generator, sys, gen_name)

        # Get ramp rate (use min of up/down as limiting factor)
        if isa(generator, Union{PSY.ThermalGen, PSY.HydroDispatch})
            ramp_limits = PSY.get_ramp_limits(generator)
            min_ramp_rate = min(ramp_limits.up, ramp_limits.down)
        elseif isa(generator, PSY.RenewableDispatch)
            # Renewable dispatch is very flexible
            min_ramp_rate = capacity  # Can ramp to full capacity in 1 minute
        else
            # Non-dispatchable or unknown - assume inflexible
            min_ramp_rate = 0.0
        end

        push!(available_gens, (i, min_ramp_rate, capacity))
    end

    sort!(available_gens, by=x -> x[2])
    remaining_dispatch = region_dispatch

    for (local_idx, ramp_rate, capacity) in available_gens
        if remaining_dispatch <= 0.0
            break
        end

        # Dispatch this generator up to its capacity
        dispatch = min(capacity, remaining_dispatch)
        gen_dispatch[local_idx] = dispatch
        remaining_dispatch -= dispatch
    end

    return gen_dispatch
end


struct RampViolations <: PRASCore.Results.ResultSpec
    sys::PSY.System
    disaggregation_func::DisaggregationFunction

    function RampViolations(
        sys::PSY.System;
        disaggregation_func=proportional_disaggregation,
    )
        return new(sys, disaggregation_func)
    end
end

mutable struct Sparse3DAccumulator{T}
    idx::Vector{Int64}
    time::Vector{Int64}
    sampleid::Vector{Int64}
    value::Vector{T}
end
function Sparse3DAccumulator{T}() where {T}
    return Sparse3DAccumulator{T}(Int64[], Int64[], Int64[], T[])
end

function Base.setindex!(
    x::Sparse3DAccumulator{T},
    val::T,
    idx::Int64,
    time::Int64,
    sampleid::Int64,
) where {T}
    push!(x.value, val)
    push!(x.idx, idx)
    push!(x.time, time)
    push!(x.sampleid, sampleid)
end

mutable struct Sparse2DAccumulator{T}
    time::Vector{Int64}
    sampleid::Vector{Int64}
    value::Vector{T}
end

function Sparse2DAccumulator{T}() where {T}
    return Sparse2DAccumulator{T}(Int64[], Int64[], T[])
end

function Base.setindex!(
    x::Sparse2DAccumulator{T},
    val::T,
    time::Int64,
    sampleid::Int64,
) where {T}
    push!(x.value, val)
    push!(x.time, time)
    push!(x.sampleid, sampleid)
end

function merge!(x::Sparse3DAccumulator{T}, y::Sparse3DAccumulator{T}) where {T}
    append!(x.idx, y.idx)
    append!(x.time, y.time)
    append!(x.sampleid, y.sampleid)
    append!(x.value, y.value)
end

function merge!(x::Sparse2DAccumulator{T}, y::Sparse2DAccumulator{T}) where {T}
    append!(x.time, y.time)
    append!(x.sampleid, y.sampleid)
    append!(x.value, y.value)
end

mutable struct RampViolationsAccumulator <:
               PRASCore.Results.ResultAccumulator{RampViolations}
    sys::PSY.System
    disaggregation_func::DisaggregationFunction
    ramp_violation::Sparse3DAccumulator{Float64}  # Magnitude of violation (MW/min)
    ramp_required::Sparse3DAccumulator{Float64}  # Required ramp rate (MW/min)
    ramp_limit::Sparse3DAccumulator{Float64}  # Ramp limit that was violated (MW/min)
    total_ramp_violation::Sparse2DAccumulator{Float64}
    generator_unavailability::Sparse3DAccumulator{Bool}
    previous_generation::Vector{Float64}  # Per-generator dispatch
    previous_availability::Vector{Bool}
    regional_ramp_infeasibility::Sparse3DAccumulator{Float64}  # Regional ramp feasibility violations
    previous_regional_dispatch::Vector{Float64}  # Track previous regional dispatch
end

function PRASCore.Results.accumulator(
    sys::PRASCore.SystemModel{N},
    nsamples::Int,
    ramp_violator::RampViolations,
) where {N}
    return RampViolationsAccumulator(
        ramp_violator.sys,
        ramp_violator.disaggregation_func,
        Sparse3DAccumulator{Float64}(),  # ramp_violation
        Sparse3DAccumulator{Float64}(),  # ramp_required
        Sparse3DAccumulator{Float64}(),  # ramp_limit
        Sparse2DAccumulator{Float64}(),  # total_ramp_violation
        Sparse3DAccumulator{Bool}(),  # generator_unavailability
        zeros(Float64, length(sys.generators.names)),  # previous_generation
        zeros(Bool, length(sys.generators.names)),  # previous_availability
        Sparse3DAccumulator{Float64}(),  # regional_ramp_infeasibility
        zeros(Float64, length(sys.regions)),  # previous_regional_dispatch
    )
end

function PRASCore.Results.merge!(x::RampViolationsAccumulator, y::RampViolationsAccumulator)
    merge!(x.ramp_violation, y.ramp_violation)
    merge!(x.ramp_required, y.ramp_required)
    merge!(x.ramp_limit, y.ramp_limit)
    merge!(x.total_ramp_violation, y.total_ramp_violation)
    merge!(x.generator_unavailability, y.generator_unavailability)
    merge!(x.regional_ramp_infeasibility, y.regional_ramp_infeasibility)
end

PRASCore.Results.accumulatortype(::RampViolations) = RampViolationsAccumulator

struct RampViolationsResult{N, L, T <: PRASCore.Period}
    timestamps::StepRange{PRASCore.ZonedDateTime, T}
    generators::Vector{String}
    ramp_violation::Sparse3DAccumulator{Float64}  # Magnitude of violation (MW/min)
    ramp_required::Sparse3DAccumulator{Float64}  # Required ramp rate (MW/min)
    ramp_limit::Sparse3DAccumulator{Float64}  # Ramp limit that was violated (MW/min)
    total_ramp_violation::Sparse2DAccumulator{Float64}
    generator_unavailability::Sparse3DAccumulator{Bool}
    regional_ramp_infeasibility::Sparse3DAccumulator{Float64}  # Regional ramp feasibility violations
end

function PRASCore.Results.finalize(
    acc::RampViolationsAccumulator,
    system::PRASCore.SystemModel{N, L, T},
) where {N, L, T}
    return RampViolationsResult{N, L, T}(
        system.timestamps,
        system.generators.names,
        acc.ramp_violation,
        acc.ramp_required,
        acc.ramp_limit,
        acc.total_ramp_violation,
        acc.generator_unavailability,
        acc.regional_ramp_infeasibility,
    )
end

# HydroDispatch
# ThermalMultiStart
# ThermalStandard

"""
    get_regional_ramp_bounds(sys, system, state, region_idx, t)

Calculate the maximum ramp capability (up and down) for a region.

Returns a named tuple (up=MW/min, down=MW/min) representing the sum of all
available generator ramp limits in the region at timestep t.
"""
function get_regional_ramp_bounds(
    sys::PSY.System,
    system::PRASCore.SystemModel,
    state::PRASCore.Simulations.SystemState,
    region_idx::Int,
    t::Int,
)
    gen_idxs = system.region_gen_idxs[region_idx]

    total_ramp_up = 0.0
    total_ramp_down = 0.0

    for gen_idx in gen_idxs
        if !state.gens_available[gen_idx]
            continue
        end

        gen_name = system.generators.names[gen_idx]
        generator = PSY.get_component(PSY.Generator, sys, gen_name)

        # Skip non-dispatchable renewables
        if isa(generator, PSY.RenewableNonDispatch)
            continue
        end

        if isa(generator, Union{PSY.ThermalGen, PSY.HydroDispatch})
            ramp_limits = PSY.get_ramp_limits(generator)
            # Check for NaN ramp limits and fail fast with clear error
            if isnan(ramp_limits.up) || isnan(ramp_limits.down)
                error(
                    "Generator $(gen_name) has NaN ramp limits (up=$(ramp_limits.up), down=$(ramp_limits.down)).",
                )
            end
            total_ramp_up += ramp_limits.up
            total_ramp_down += ramp_limits.down
        elseif isa(generator, PSY.RenewableDispatch)
            # Renewable dispatch is very flexible
            capacity = system.generators.capacity[gen_idx, t]
            total_ramp_up += capacity
            total_ramp_down += capacity
        end
    end

    return (up=total_ramp_up, down=total_ramp_down)
end

"""
Get ramp limits for an individual generator.

Returns a named tuple with:

  - up: up ramp limit (MW/min)
  - down: down ramp limit (MW/min)
  - can_ramp: whether generator can ramp (false if turning on/off or non-dispatchable)
"""
function get_generator_ramp_limits(
    generator::PSY.Generator,
    system::PRASCore.SystemModel,
    gen_idx::Int,
    previous_availability::Bool,
    current_availability::Bool,
    t::Int,
)
    # Generator turning on or off - use capacity change rather than ramp limit
    if previous_availability && !current_availability
        return (
            up=0.0,
            down=0.0,
            can_ramp=false,
            capacity_change=-system.generators.capacity[gen_idx, t],
        )
    elseif !previous_availability && current_availability
        return (
            up=0.0,
            down=0.0,
            can_ramp=false,
            capacity_change=system.generators.capacity[gen_idx, t],
        )
    elseif !current_availability
        return (up=0.0, down=0.0, can_ramp=false, capacity_change=0.0)
    end

    # Generator staying online - check if it has ramp limits
    if isa(generator, Union{PSY.HydroDispatch, PSY.ThermalGen})
        # Use PSY.get_ramp_limits() to get values in system units (NATURAL_UNITS = MW/min)
        ramp_limits = PSY.get_ramp_limits(generator)
        return (
            up=ramp_limits.up,
            down=ramp_limits.down,
            can_ramp=true,
            capacity_change=0.0,
        )
    elseif isa(generator, PSY.RenewableDispatch)
        # Renewable dispatch can change freely within capacity bounds
        capacity = max(
            system.generators.capacity[gen_idx, t],
            system.generators.capacity[gen_idx, t - 1],
        )
        return (up=capacity, down=capacity, can_ramp=true, capacity_change=0.0)
    else
        # Non-dispatchable or unknown type - no ramp constraint
        return (up=Inf, down=Inf, can_ramp=true, capacity_change=0.0)
    end
end

# Each of these has a .ramp_limits::UpDown field in units of MW/min. UpDown is a named tuple (up=, down=).

"""
    record!(acc::RampViolationsAccumulator, system, state, problem, sampleid, t)

Record ramp rate violations for the current time step during PRAS simulation.

This function extracts generator dispatch from the PRAS problem solution, disaggregates
regional dispatch to individual generators, and computes ramp rate violations based on
each generator's ramp limits.
"""
function PRASCore.Simulations.record!(
    acc::RampViolationsAccumulator,
    system::PRASCore.SystemModel{N, L, T, P, E},
    state::PRASCore.Simulations.SystemState,
    problem::PRASCore.Simulations.DispatchProblem,
    sampleid::Int,
    t::Int,
) where {N, L, T, P, E}
    try
        # Get regional dispatch
        region_generation = get_generator_region_dispatch(system, state, problem, t)
        fixed_region_generation = get_generator_fixed_dispatch(system, acc.sys, state, t)
        region_generation .-= fixed_region_generation

        # Check regional ramp feasibility BEFORE disaggregation
        if t >= 2
            time_difference = Dates.Minute(system.timestamps[t] - system.timestamps[t - 1])

            for region_idx in 1:length(system.regions)
                # Calculate required regional ramp
                required_dispatch_change =
                    region_generation[region_idx] -
                    acc.previous_regional_dispatch[region_idx]
                required_ramp_rate = required_dispatch_change / time_difference.value  # MW/min

                # Calculate available regional ramp capability
                ramp_bounds =
                    get_regional_ramp_bounds(acc.sys, system, state, region_idx, t)

                # Check if regional ramp is feasible
                infeasibility = 0.0
                if required_ramp_rate > 0.0 && required_ramp_rate > ramp_bounds.up
                    infeasibility = required_ramp_rate - ramp_bounds.up
                elseif required_ramp_rate < 0.0 &&
                       abs(required_ramp_rate) > ramp_bounds.down
                    infeasibility = abs(required_ramp_rate) - ramp_bounds.down
                end

                # Record regional infeasibility if it exists
                if infeasibility > 0.0
                    acc.regional_ramp_infeasibility[region_idx, t, sampleid] = infeasibility
                end
            end
        end

        # Store current regional dispatch for next timestep
        copy!(acc.previous_regional_dispatch, region_generation)

        # Disaggregate to per-generator dispatch
        current_generation = zeros(Float64, length(system.generators.names))
        for (region_idx, gen_idxs) in enumerate(system.region_gen_idxs)
            # Use disaggregation function to distribute regional dispatch
            gen_dispatch = acc.disaggregation_func(
                region_generation[region_idx],
                gen_idxs,
                system,
                state,
                t,
            )

            # Store in global generator array
            for (local_idx, gen_idx) in enumerate(gen_idxs)
                current_generation[gen_idx] = gen_dispatch[local_idx]
            end
        end

        if t < 2
            copy!(acc.previous_generation, current_generation)
            copy!(acc.previous_availability, state.gens_available)
            return
        end

        time_difference = Dates.Minute(system.timestamps[t] - system.timestamps[t - 1])

        # Calculate per-generator ramp violations
        total_violation = 0.0
        for gen_idx in 1:length(system.generators.names)
            generator =
                PSY.get_component(PSY.Generator, acc.sys, system.generators.names[gen_idx])

            # Skip non-dispatchable renewables - they're already accounted for as fixed generation
            if isa(generator, PSY.RenewableNonDispatch)
                continue
            end

            # Get generator ramp limits
            limits = get_generator_ramp_limits(
                generator,
                system,
                gen_idx,
                acc.previous_availability[gen_idx],
                state.gens_available[gen_idx],
                t,
            )

            # Calculate actual ramp rate (MW/min)
            dispatch_change = current_generation[gen_idx] - acc.previous_generation[gen_idx]
            ramp_rate = dispatch_change / time_difference.value

            # Check for violations
            if limits.can_ramp &&
               !(current_generation[gen_idx] ≈ 0.0) &&
               !(acc.previous_generation[gen_idx] ≈ 0.0)
                # Generator is ramping - check against ramp limits
                if ramp_rate > limits.up
                    violation = ramp_rate - limits.up
                    acc.ramp_violation[gen_idx, t, sampleid] = violation
                    acc.ramp_required[gen_idx, t, sampleid] = ramp_rate
                    acc.ramp_limit[gen_idx, t, sampleid] = limits.up
                    total_violation += violation
                elseif -ramp_rate > limits.down
                    violation = -ramp_rate - limits.down
                    acc.ramp_violation[gen_idx, t, sampleid] = violation
                    acc.ramp_required[gen_idx, t, sampleid] = -ramp_rate  # Store as positive (magnitude)
                    acc.ramp_limit[gen_idx, t, sampleid] = limits.down
                    total_violation += violation
                end
            end

            # Record unavailability
            if !state.gens_available[gen_idx]
                acc.generator_unavailability[gen_idx, t, sampleid] = true
            end
        end

        # Store total violation across all generators
        if total_violation > 0.0
            acc.total_ramp_violation[t, sampleid] = total_violation
        end

        # Update previous state for next time step
        copy!(acc.previous_generation, current_generation)
        copy!(acc.previous_availability, state.gens_available)

    catch e
        println("ERROR in record! function:")
        println("  Exception: ", e)
        println("  Sample ID: ", sampleid)
        println("  Time step: ", t)
        println("  Error type: ", typeof(e))

        # Print field names available for debugging
        try
            println("  Available fields in problem: ", fieldnames(typeof(problem)))
        catch
            println("  Could not get problem fieldnames")
        end

        try
            println("  Available fields in state: ", fieldnames(typeof(state)))
        catch
            println("  Could not get state fieldnames")
        end

        # Re-throw the error so it's visible
        rethrow(e)
    end

    return
end

function get_generator_region_dispatch(
    system::PRASCore.SystemModel,
    state::PRASCore.Simulations.SystemState,
    problem::PRASCore.Simulations.DispatchProblem,
    t::Int,
)
    dispatch = zeros(Float64, length(system.regions))
    edges = problem.region_unused_edges
    for (region_idx, edge_idx) in enumerate(edges)
        gen_idxs = system.region_gen_idxs[region_idx]
        dispatch[region_idx] =
            PRASCore.Simulations.available_capacity(
                state.gens_available,
                system.generators,
                gen_idxs,
                t,
            ) - problem.fp.edges[edge_idx].flow
    end

    return dispatch
end

function get_generator_fixed_dispatch(
    system::PRASCore.SystemModel,
    sys::PSY.System,
    state::PRASCore.Simulations.SystemState,
    t::Int,
)
    dispatch = zeros(Float64, length(system.regions))
    for region_idx in 1:length(system.regions)
        gen_idxs = system.region_gen_idxs[region_idx]
        for gen_idx in gen_idxs
            if !state.gens_available[gen_idx]
                continue
            end
            name = system.generators.names[gen_idx]
            if isa(PSY.get_component(PSY.Generator, sys, name), PSY.RenewableNonDispatch)
                dispatch[region_idx] += system.generators.capacity[gen_idx, t]
            end
        end
    end
    return dispatch
end

"""
    reset!(acc::RampViolationsAccumulator, sampleid::Int)

Reset accumulator for next simulation sample.
"""
function PRASCore.Simulations.reset!(::RampViolationsAccumulator, ::Int)
    return
end

function count_outage_transitions(result::RampViolationsResult)
    # Build a dictionary to track unavailability by (gen_idx, time, sample)
    unavail_dict = Dict{Tuple{Int64, Int64, Int64}, Bool}()

    for i in eachindex(result.generator_unavailability.idx)
        idx = result.generator_unavailability.idx[i]
        time = result.generator_unavailability.time[i]
        sampleid = result.generator_unavailability.sampleid[i]
        is_unavail = result.generator_unavailability.value[i]

        unavail_dict[(idx, time, sampleid)] = is_unavail
    end

    outage_counts = Dict{Int64, Int64}()
    sample_ids = unique(result.generator_unavailability.sampleid)

    for sample_id in sample_ids
        total_outages = 0
        for gen_idx in 1:length(result.generators)
            for t in 2:length(result.timestamps)
                was_available = !get(unavail_dict, (gen_idx, t - 1, sample_id), false)
                is_available = !get(unavail_dict, (gen_idx, t, sample_id), false)
                if was_available && !is_available
                    total_outages += 1
                end
            end
        end
        outage_counts[sample_id] = total_outages
    end

    return outage_counts
end

"""
    add_asset_status_single_sample!(
        sys::PSY.System, 
        results::SPIOutageResult, 
        template::RATemplate,
        sample_idx::Int
    )

Modified version of add_asset_status! that applies a specific sample rather than the worst.

# Arguments

  - `sys`: PowerSystems system to modify
  - `results`: PRAS outage results containing availability data
  - `template`: Resource adequacy template
  - `sample_idx`: Specific sample index to apply
"""
function add_asset_status_single_sample!(
    sys::PSY.System,
    results::SPIOutageResult,
    template::RATemplate,
    sample_idx::Int,
)
    # Time series timestamps
    all_ts = PSY.get_time_series_multiple(sys, x -> (typeof(x) <: PSY.StaticTimeSeries))
    ts_timestamps = TimeSeries.timestamp(first(all_ts).data)

    for result in
        [results.gen_availability, results.stor_availability, results.gen_stor_availability]
        device_ramodel = get_device_ramodel(typeof(result))
        gens_to_formula = build_component_to_formulation(
            device_ramodel.model,
            sys,
            template.device_models,
        )

        for gen in keys(gens_to_formula)
            pras_gen_names = getfield(result, device_ramodel.key)
            if (gen.name in pras_gen_names)
                ts_forced_outage = PSY.TimeSeriesForcedOutage(;
                    outage_status_scenario="ImportanceSample_$(sample_idx)",
                )
                PSY.add_supplemental_attribute!(sys, gen, ts_forced_outage)

                availability_data = TimeSeries.TimeArray(
                    ts_timestamps,
                    getindex.(result[gen.name, :], sample_idx),
                )
                availability_timeseries =
                    PSY.SingleTimeSeries("availability", availability_data)

                PSY.add_time_series!(sys, ts_forced_outage, availability_timeseries)
                @debug "Added availability time series sample $(sample_idx) to $(gen.name)."
            end
        end
    end
end

#=
REMAINING WORKFLOW IMPLEMENTATION OUTLINE:

1. PRAS SIMULATION & ANALYSIS
   - Run PRAS sequential Monte Carlo with n_samples (e.g., 10,000)
   - For each sample: extract shortfall status and generator dispatch patterns
   - Compute ramp violations using compute_ramp_violations()
   - Store sample results: (sample_idx, shortfall_flag, ramp_metrics)

2. IMPORTANCE SAMPLING
   - Compute importance weights using compute_importance_weights()
   - Sample subset for Sienna simulation (e.g., 1,000) using weights P(i) ∝ R_i + c
   - Higher ramp violations get higher probability of selection

3. SIENNA SIMULATION SETUP
   - For each selected sample:
     * Copy original PowerSystems system
     * Apply outage pattern using add_asset_status_single_sample!()
     * Run economic dispatch/unit commitment simulation
     * Check for shortfall events (load shedding)

4. BIAS ESTIMATION
   - Compare PRAS vs Sienna shortfall outcomes for same outage patterns
   - Compute weighted bias metrics accounting for importance sampling:
     * P(Sienna shortfall | PRAS no shortfall) - measures PRAS under-prediction
     * P(PRAS shortfall | Sienna no shortfall) - measures PRAS over-prediction
   - Key insight: Bias(i) / P(i) should be approximately constant if R_i correlates with bias

5. DISTRIBUTED COMPUTATION
   - Split PRAS simulation across compute nodes
   - Save intermediate results to files for reproducibility
   - Use DVC or similar for workflow management
   - Aggregate results from multiple nodes for final bias estimates

6. RESULT VALIDATION
   - Bootstrap confidence intervals for bias estimates
   - Sensitivity analysis on importance sampling constant c
   - Correlation analysis between ramp violations and actual bias
=#
