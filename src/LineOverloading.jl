"""
Line overloading metrics for power flow analysis during PRAS simulations.

This module tracks transmission line overloading during assess_with_powerflow
simulations by comparing power flows (from PowerFlowData) against line ratings.

THREAD SAFETY: Each thread gets its own PowerFlowData instance stored in the
accumulator. These instances are kept alive until after all threads complete to
prevent concurrent finalizer execution (which could crash KLU/sparse matrix libraries).
"""

using PowerSystems
using PRASCore
import PowerFlows

const PSY = PowerSystems
const PFS = PowerFlows

"""
    PowerFlowWithOverloads <: PRASCore.Results.ResultSpec

Result specification for running power flow during PRAS simulation and tracking line overloads.

# Arguments
- `sys::PSY.System`: PowerSystems system
- `power_flow_evaluator::PFS.PowerFlowEvaluationModel`: Power flow method (DCPowerFlow, ACPowerFlow, etc.)
- `disaggregation_func::DisaggregationFunction`: Function to disaggregate regional dispatch to generator-level dispatch (default: proportional_disaggregation)
"""
struct PowerFlowWithOverloads <: PRASCore.Results.ResultSpec
    sys::PSY.System
    power_flow_evaluator::PFS.PowerFlowEvaluationModel
    disaggregation_func::Function

    function PowerFlowWithOverloads(
        sys::PSY.System,
        power_flow_evaluator::PFS.PowerFlowEvaluationModel;
        disaggregation_func=proportional_disaggregation,
    )
        return new(sys, power_flow_evaluator, disaggregation_func)
    end
end

"""
    PowerFlowWithOverloadsAccumulator <: PRASCore.Results.ResultAccumulator

Accumulator that holds PowerFlowData instance and tracks line overloads.

Each thread gets its own accumulator with its own PowerFlowData. During merge!,
all PowerFlowData instances are collected into `all_pf_data` to keep them alive.
In finalize(), they are moved to the result structure where they stay until the
user is done with the results. This prevents concurrent finalizer execution.

# Fields
- `sys::PSY.System`: PowerSystems system
- `power_flow_evaluator::PFS.PowerFlowEvaluationModel`: Power flow method
- `disaggregation_func::Function`: Function to disaggregate regional dispatch to generator-level dispatch
- `pf_data::PFS.PowerFlowData`: PowerFlowData instance for this thread
- `all_pf_data::Vector{PFS.PowerFlowData}`: Collection of PowerFlowData from all threads (built during merge)
- `branch_names::Vector{String}`: Ordered branch names from PowerFlowData
- `line_idx::Vector{Int}`: Line index for each overload event
- `timestep::Vector{Int}`: Timestep for each overload event
- `sample_id::Vector{Int}`: Sample ID for each overload event
- `overload_mw::Vector{Float64}`: Overload magnitude (MW over rating)
- `flow_mw::Vector{Float64}`: Actual flow magnitude (MW/MVA)
- `rating_mw::Vector{Float64}`: Line rating (MW/MVA)
- `pf_converged::Vector{Bool}`: Convergence status per solve
"""
mutable struct PowerFlowWithOverloadsAccumulator <:
               PRASCore.Results.ResultAccumulator{PowerFlowWithOverloads}
    sys::PSY.System
    power_flow_evaluator::PFS.PowerFlowEvaluationModel
    disaggregation_func::Function
    pf_data::PFS.PowerFlowData  # This thread's PowerFlowData
    all_pf_data::Vector{PFS.PowerFlowData}  # Collect all PowerFlowData during merge
    branch_names::Vector{String}
    line_idx::Vector{Int}
    timestep::Vector{Int}
    sample_id::Vector{Int}
    overload_mw::Vector{Float64}
    flow_mw::Vector{Float64}
    rating_mw::Vector{Float64}
    pf_converged::Vector{Bool}
    generators_cache::Vector{PSY.Generator}  # Cache of generator objects
    ramp_limits_cache::Vector{Union{Nothing, NamedTuple{(:up, :down), Tuple{Float64, Float64}}}}  # Cache of ramp limits
end

"""
    PRASCore.Results.accumulator(system, nsamples, spec::PowerFlowWithOverloads)

Create an accumulator for power flow with overload tracking.

Each thread will get its own accumulator (and thus its own PowerFlowData).
The PowerFlowData is stored in all_pf_data to keep it alive.
"""
function PRASCore.Results.accumulator(
    pras_system::PRASCore.SystemModel,
    nsamples::Int,
    spec::PowerFlowWithOverloads,
)
    # Create PowerFlowData for this thread with ALL timesteps for batching
    num_timesteps = length(pras_system.timestamps)
    pf_data = PFS.PowerFlowData(spec.power_flow_evaluator, spec.sys; time_steps=num_timesteps)

    # Extract branch names in order from branch_lookup
    branch_names = sort(collect(keys(pf_data.branch_lookup)), by=k -> pf_data.branch_lookup[k])

    # Build generator cache once during initialization
    generators_cache = [
        PSY.get_component(PSY.Generator, spec.sys, name) for
        name in pras_system.generators.names
    ]

    # Build ramp limits cache
    ramp_limits_cache = Vector{Union{Nothing, NamedTuple{(:up, :down), Tuple{Float64, Float64}}}}(undef, length(pras_system.generators.names))
    for (i, gen) in enumerate(generators_cache)
        if isa(gen, Union{PSY.ThermalGen, PSY.HydroDispatch})
            limits = PSY.get_ramp_limits(gen)
            ramp_limits_cache[i] = (up=limits.up, down=limits.down)
        else
            ramp_limits_cache[i] = nothing
        end
    end

    return PowerFlowWithOverloadsAccumulator(
        spec.sys,
        spec.power_flow_evaluator,
        spec.disaggregation_func,
        pf_data,
        [pf_data],  # Start with this thread's PowerFlowData
        branch_names,
        Int[],
        Int[],
        Int[],
        Float64[],
        Float64[],
        Float64[],
        Bool[],
        generators_cache,
        ramp_limits_cache,
    )
end

"""
    PRASCore.Results.merge!(x::PowerFlowWithOverloadsAccumulator, y::PowerFlowWithOverloadsAccumulator)

Merge two accumulators (for combining results from multiple threads).

CRITICAL: We collect y's PowerFlowData into x's all_pf_data vector to keep it alive.
This prevents concurrent finalizer execution on KLU factorizations and other C-backed
data structures. All PowerFlowData instances stay alive until the final result is
garbage collected by the user.
"""
function PRASCore.Results.merge!(
    x::PowerFlowWithOverloadsAccumulator,
    y::PowerFlowWithOverloadsAccumulator,
)
    # Merge data vectors
    append!(x.line_idx, y.line_idx)
    append!(x.timestep, y.timestep)
    append!(x.sample_id, y.sample_id)
    append!(x.overload_mw, y.overload_mw)
    append!(x.flow_mw, y.flow_mw)
    append!(x.rating_mw, y.rating_mw)
    append!(x.pf_converged, y.pf_converged)

    # CRITICAL: Keep y's PowerFlowData alive by adding to collection
    # This prevents concurrent finalizer execution
    append!(x.all_pf_data, y.all_pf_data)

    return nothing
end

PRASCore.Results.accumulatortype(::PowerFlowWithOverloads) = PowerFlowWithOverloadsAccumulator

"""
    PRASCore.Simulations.reset!(acc::PowerFlowWithOverloadsAccumulator, sample_id::Int)

Reset accumulator state between samples. This is called by PRAS after each sample completes.
We need to clear the PowerFlowData arrays to avoid carrying data from one sample to the next.
"""
function PRASCore.Simulations.reset!(acc::PowerFlowWithOverloadsAccumulator, sample_id::Int)
    # Clear PowerFlowData arrays for the next sample
    fill!(acc.pf_data.bus_activepower_injection, 0.0)
    fill!(acc.pf_data.bus_reactivepower_injection, 0.0)
    fill!(acc.pf_data.bus_activepower_withdrawals, 0.0)
    fill!(acc.pf_data.bus_reactivepower_withdrawals, 0.0)
    fill!(acc.pf_data.bus_magnitude, 0.0)
    fill!(acc.pf_data.bus_angles, 0.0)
    fill!(acc.pf_data.branch_activepower_flow_from_to, 0.0)
    fill!(acc.pf_data.branch_reactivepower_flow_from_to, 0.0)
    fill!(acc.pf_data.branch_activepower_flow_to_from, 0.0)
    fill!(acc.pf_data.branch_reactivepower_flow_to_from, 0.0)
    fill!(acc.pf_data.converged, false)

    return nothing
end

"""
    LineOverloadResult{N, L, T, S}

Final result structure containing line overload statistics and power flow convergence data.

IMPORTANT: This struct holds all PowerFlowData instances from all threads. This keeps
them alive until the user is done with the results, preventing concurrent finalizer
execution on C-backed data structures (KLU factorizations, etc.).

# Type Parameters
- `N`: Number of timesteps per sample
- `L`: Length of each timestep
- `T <: Period`: Time period type (Hour, Minute, etc.)
- `S`: Number of samples simulated

# Fields
- `timestamps::StepRange{PRASCore.ZonedDateTime, T}`: Simulation timestamps
- `branch_names::Vector{String}`: Ordered list of branch names
- `line_idx::Vector{Int}`: Line index for each overload event
- `timestep::Vector{Int}`: Timestep for each overload event
- `sample_id::Vector{Int}`: Sample ID for each overload event
- `overload_mw::Vector{Float64}`: Overload magnitude (MW over rating)
- `flow_mw::Vector{Float64}`: Actual flow magnitude (MW/MVA)
- `rating_mw::Vector{Float64}`: Line rating (MW/MVA)
- `convergence_rate::Float64`: Fraction of solves where power flow converged
- `_pf_data::Vector{PFS.PowerFlowData}`: PowerFlowData instances (kept alive to prevent concurrent finalizers)
"""
struct LineOverloadResult{N, L, T <: PRASCore.Period, S}
    timestamps::StepRange{PRASCore.ZonedDateTime, T}
    branch_names::Vector{String}
    line_idx::Vector{Int}
    timestep::Vector{Int}
    sample_id::Vector{Int}
    overload_mw::Vector{Float64}
    flow_mw::Vector{Float64}
    rating_mw::Vector{Float64}
    convergence_rate::Float64
    _pf_data::Vector{PFS.PowerFlowData}  # Keep alive for safe finalization
end

"""
    PRASCore.Results.finalize(acc::PowerFlowWithOverloadsAccumulator, system::PRASCore.SystemModel)

Convert accumulator to final result structure.

The PowerFlowData instances are transferred to the result, where they stay alive
until the user is done with the results. After the result is garbage collected,
the PowerFlowData finalizers can run safely (sequentially, not concurrently).

Note: We infer the number of samples from the maximum sample ID seen in the data.
"""
function PRASCore.Results.finalize(
    acc::PowerFlowWithOverloadsAccumulator,
    system::PRASCore.SystemModel{N, L, T},
) where {N, L, T}
    # Infer number of samples from maximum sample ID (or use nsamples from accumulator)
    S = isempty(acc.sample_id) ? 0 : maximum(acc.sample_id)

    # Calculate convergence rate based on actual solves attempted
    total_solves = length(acc.pf_converged)
    convergence_rate = total_solves > 0 ? count(acc.pf_converged) / total_solves : 0.0

    return LineOverloadResult{N, L, T, S}(
        system.timestamps,
        acc.branch_names,
        acc.line_idx,
        acc.timestep,
        acc.sample_id,
        acc.overload_mw,
        acc.flow_mw,
        acc.rating_mw,
        convergence_rate,
        acc.all_pf_data,  # Transfer PowerFlowData to result to keep alive
    )
end

"""
    PRASCore.Simulations.record!(
        acc::PowerFlowWithOverloadsAccumulator,
        system::PRASCore.SystemModel,
        state::PRASCore.Simulations.SystemState,
        problem::PRASCore.Simulations.DispatchProblem,
        sampleid::Int,
        t::Int,
    )

Record power flow results and line overloads for current timestep.

BATCHED IMPLEMENTATION:
1. Writes PRAS dispatch to PowerFlowData column t
2. On the LAST timestep, solves power flow for ALL timesteps at once
3. Records any line overloads from all timesteps
"""
function PRASCore.Simulations.record!(
    acc::PowerFlowWithOverloadsAccumulator,
    system::PRASCore.SystemModel,
    state::PRASCore.Simulations.SystemState,
    problem::PRASCore.Simulations.DispatchProblem,
    sampleid::Int,
    t::Int,
)
    num_timesteps = length(system.timestamps)

    # Write PRAS dispatch solution to PowerFlowData column t
    write_output_to_pf_data_column!(
        acc.pf_data,
        problem,
        system,
        acc.sys,
        t,
        state,
        acc.generators_cache,
        acc.ramp_limits_cache,
        acc.disaggregation_func,
    )

    # On the last timestep, solve power flow for ALL timesteps at once
    if t == num_timesteps
        # Solve power flow for all timesteps in one batch
        pf_converged = false
        try
            PFS.solve_powerflow!(acc.pf_data)
            pf_converged = true
        catch e
            # Power flow failed - print error for debugging
            @warn "Power flow failed for sample $sampleid" exception=(e, catch_backtrace())
            pf_converged = false
        end

        # Record convergence for all timesteps
        for _ in 1:num_timesteps
            push!(acc.pf_converged, pf_converged)
        end

        # Record overloads from all timesteps if converged
        if pf_converged
            record_line_overloads_batched!(acc, sampleid, system)
        end
    end

    return nothing
end

"""
    record_line_overloads_batched!(
        acc::PowerFlowWithOverloadsAccumulator,
        sample_id::Int,
        system::PRASCore.SystemModel,
    )

Record line overloads from ALL timesteps in the PowerFlowData (batched version).
"""
function record_line_overloads_batched!(
    acc::PowerFlowWithOverloadsAccumulator,
    sample_id::Int,
    system::PRASCore.SystemModel,
)
    pf_data = acc.pf_data
    num_timesteps = length(system.timestamps)

    # Check if this is AC power flow (has reactive power data)
    has_reactive = !all(iszero, pf_data.branch_reactivepower_flow_from_to)

    # Check each branch for overloads across ALL timesteps
    for (branch_name, branch_idx) in pf_data.branch_lookup
        # Get the branch from PowerSystems
        branch = PSY.get_component(PSY.ACBranch, acc.sys, branch_name)
        if isnothing(branch)
            continue
        end

        # Get rating (in system natural units = MW or MVA)
        rating = PSY.get_rating(branch)

        if rating <= 0.0
            continue  # Skip branches with no rating
        end

        # Check all timesteps for this branch
        for t in 1:num_timesteps
            # Get flows for timestep t
            p_from_to = pf_data.branch_activepower_flow_from_to[branch_idx, t]
            p_to_from = pf_data.branch_activepower_flow_to_from[branch_idx, t]

            # Calculate flow magnitude
            if has_reactive
                q_from_to = pf_data.branch_reactivepower_flow_from_to[branch_idx, t]
                q_to_from = pf_data.branch_reactivepower_flow_to_from[branch_idx, t]
                # AC power flow: use apparent power S = sqrt(P^2 + Q^2)
                s_from_to = sqrt(p_from_to^2 + q_from_to^2)
                s_to_from = sqrt(p_to_from^2 + q_to_from^2)
                flow_magnitude = max(s_from_to, s_to_from)
            else
                # DC power flow: use active power only
                flow_magnitude = max(abs(p_from_to), abs(p_to_from))
            end

            # Check for overload
            overload = flow_magnitude - rating
            if overload > 1e-6  # Small tolerance to avoid numerical noise
                push!(acc.line_idx, branch_idx)
                push!(acc.timestep, t)
                push!(acc.sample_id, sample_id)
                push!(acc.overload_mw, overload)
                push!(acc.flow_mw, flow_magnitude)
                push!(acc.rating_mw, rating)
            end
        end
    end

    return nothing
end

# Utility functions for analyzing results

"""
    count_overload_events(result::LineOverloadResult)

Count total number of line overload events across all samples and timesteps.
"""
count_overload_events(result::LineOverloadResult) = length(result.overload_mw)

"""
    get_most_overloaded_lines(result::LineOverloadResult, n::Int=10)

Get the lines with the most overload events.

# Returns
- Vector of tuples: (branch_name, count, max_overload_mw)
"""
function get_most_overloaded_lines(result::LineOverloadResult, n::Int=10)
    # Count events per line
    line_counts = Dict{String, Tuple{Int, Float64}}()  # (count, max_overload)

    for i in eachindex(result.line_idx)
        branch_name = result.branch_names[result.line_idx[i]]
        overload = result.overload_mw[i]

        if haskey(line_counts, branch_name)
            count, max_overload = line_counts[branch_name]
            line_counts[branch_name] = (count + 1, max(max_overload, overload))
        else
            line_counts[branch_name] = (1, overload)
        end
    end

    # Sort by count (descending)
    sorted = sort(
        collect(line_counts),
        by = x -> x[2][1],
        rev = true,
    )

    # Return top n
    return [(name, count, max_overload) for (name, (count, max_overload)) in first(sorted, min(n, length(sorted)))]
end

"""
    overload_probability(result::LineOverloadResult{N, L, T, S})

Calculate the probability of any line overload occurring.

Returns the fraction of (sample, timestep) pairs where at least one overload occurred
(considering only converged power flow solves).
"""
function overload_probability(result::LineOverloadResult{N, L, T, S}) where {N, L, T, S}
    if result.convergence_rate == 0.0
        return 0.0  # No converged samples
    end

    # Find unique (sample_id, timestep) pairs with overloads
    overload_pairs = Set{Tuple{Int, Int}}()
    for i in eachindex(result.sample_id)
        push!(overload_pairs, (result.sample_id[i], result.timestep[i]))
    end

    # Total converged (sample, timestep) pairs (S=samples, N=timesteps)
    n_converged = round(Int, S * N * result.convergence_rate)

    return length(overload_pairs) / n_converged
end

"""
    line_overload_probability(result::LineOverloadResult{N, L, T, S}, branch_name::String)

Calculate the probability that a specific line is overloaded.

Returns the fraction of (sample, timestep) pairs where the specified line was overloaded
(considering only converged power flow solves).
"""
function line_overload_probability(result::LineOverloadResult{N, L, T, S}, branch_name::String) where {N, L, T, S}
    if result.convergence_rate == 0.0
        return 0.0
    end

    # Find the line index
    line_idx = findfirst(==(branch_name), result.branch_names)
    if isnothing(line_idx)
        error("Branch '$branch_name' not found in results")
    end

    # Find unique (sample_id, timestep) pairs for this line
    overload_pairs = Set{Tuple{Int, Int}}()
    for i in eachindex(result.line_idx)
        if result.line_idx[i] == line_idx
            push!(overload_pairs, (result.sample_id[i], result.timestep[i]))
        end
    end

    # Total converged (sample, timestep) pairs (S=samples, N=timesteps)
    n_converged = round(Int, S * N * result.convergence_rate)

    return length(overload_pairs) / n_converged
end
