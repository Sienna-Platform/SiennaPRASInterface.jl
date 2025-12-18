"""
Add default data to a system from `OUTAGE_INFO_FILE` (ERCOT data).
"""
function add_default_data!(sys::PSY.System, outage_info_file=OUTAGE_INFO_FILE)
    @warn "No forced outage data available in the Sienna/Data PowerSystems System. Using generic outage data ..."
    df_outage = DataFrames.DataFrame(
        CSV.File(
            outage_info_file,
            types=Dict(:tech => String, :PrimeMovers => String, :ThermalFuels => String),
            missingstring="NA",
        ),
    )

    outage_values = outage_data[]
    for row in eachrow(df_outage)
        if ismissing(row.ThermalFuels)
            push!(
                outage_values,
                outage_data(
                    PSY.PrimeMovers(row.PrimeMovers),
                    row.ThermalFuels,
                    row.NameplateLimit_MW,
                    (row.FOR / 100),
                    row.MTTR,
                ),
            )
        else
            push!(
                outage_values,
                outage_data(
                    PSY.PrimeMovers(row.PrimeMovers),
                    PSY.ThermalFuels(row.ThermalFuels),
                    row.NameplateLimit_MW,
                    (row.FOR / 100),
                    row.MTTR,
                ),
            )
        end
    end

    # Add min capacity fields to outage_data objects
    add_min_capacity!(outage_values)
    # Adding generic data to components in the System
    for outage_val in outage_values
        λ, μ = rate_to_probability(outage_val.FOR, outage_val.MTTR)
        transition_data = PSY.GeometricDistributionForcedOutage(;
            mean_time_to_recovery=outage_val.MTTR,
            outage_transition_probability=λ,
        )

        comps = if ismissing(outage_val.fuel)
            PSY.get_components(
                x -> (
                    PSY.get_prime_mover_type(x) == outage_val.prime_mover &&
                    outage_val.min_capacity <=
                    PSY.get_max_active_power(x) <
                    outage_val.max_capacity
                ),
                PSY.Generator,
                sys,
            )
        else
            PSY.get_components(
                x -> (
                    PSY.get_prime_mover_type(x) == outage_val.prime_mover &&
                    PSY.get_fuel(x) == outage_val.fuel &&
                    outage_val.min_capacity <=
                    PSY.get_max_active_power(x) <
                    outage_val.max_capacity
                ),
                PSY.ThermalGen,
                sys,
            )
        end

        for comp in comps
            PSY.add_supplemental_attribute!(sys, comp, transition_data)
        end
    end
end

function add_to_load_matrix!(
    formulation::StaticLoadPRAS,
    load::PSY.Device,
    s2p_meta::S2P_metadata,
    load_row,
)
    load_row .+=
        PSY.get_time_series_values(PSY.SingleTimeSeries, load, formulation.max_active_power)
end

"""
    $(TYPEDSIGNATURES)

Extract region load as a matrix of Int64 values.
"""
function get_region_loads(
    s2p_meta::S2P_metadata,
    regions,
    loads_to_formulations::Dict{PSY.Device, LoadPRAS},
)
    region_load = zeros(Float64, length(regions), s2p_meta.N)
    aggregation = Dict(region => i for (i, region) in enumerate(regions))

    for (load, formulation) in loads_to_formulations
        index = aggregation[PSY.get_area(PSY.get_bus(load))]
        add_to_load_matrix!(formulation, load, s2p_meta, view(region_load, index, :))
    end
    return floor.(Int, region_load)
end

# Generator must not have HydroEenergyReservoir or have 0 max active power or be a hybrid system
"""
    $(TYPEDSIGNATURES)

Extraction of generators using formulation dictionary to create a list of generators
and appropriate indices for PRAS. Note that objects with 0 max active power are excluded.
"""
function get_generator_region_indices(
    sys::PSY.System,
    s2p_meta::S2P_metadata,
    regions,
    component_to_formulation::Dict{PowerSystems.Device, GeneratorPRAS},
)
    lumped_gens_to_formula, nonlumped_gens_to_formula =
        filter_component_to_formulation(component_to_formulation)
    gens = Array{PSY.Device}[]
    start_id = Array{Int64}(undef, length(regions))
    region_gen_idxs = Array{UnitRange{Int64}, 1}(undef, length(regions))

    reg_wind_gens = Array{PSY.Device}[]
    reg_pv_gens = Array{PSY.Device}[]
    for (idx, region) in enumerate(regions)
        wind_gs = filter(
            x -> (
                (PSY.get_prime_mover_type(x) == PSY.PrimeMovers.WT) &&
                (get_aggregation_function(region)(x.bus) == region)
            ),
            collect(keys(lumped_gens_to_formula)),
        )
        pv_gs = filter(
            x -> (
                (PSY.get_prime_mover_type(x) == PSY.PrimeMovers.PVe) &&
                (get_aggregation_function(region)(x.bus) == region)
            ),
            collect(keys(lumped_gens_to_formula)),
        )
        gs = filter(
            x -> (
                (get_aggregation_function(region)(x.bus) == region) &&
                !(iszero(PSY.get_max_active_power(x))) &&
                PSY.IS.get_uuid(x) ∉ s2p_meta.hs_uuids
            ),
            collect(keys(nonlumped_gens_to_formula)),
        )
        # To ensure reproducability when testing
        sort!(gs, by=g -> g.name)
        push!(gens, gs)
        push!(reg_wind_gens, wind_gs)
        push!(reg_pv_gens, pv_gs)

        if (idx == 1)
            start_id[idx] = 1
        else
            if (length(reg_wind_gens[idx - 1]) > 0 && length(reg_pv_gens[idx - 1]) > 0)
                start_id[idx] = start_id[idx - 1] + length(gens[idx - 1]) + 2
            elseif (length(reg_wind_gens[idx - 1]) > 0 || length(reg_pv_gens[idx - 1]) > 0)
                start_id[idx] = start_id[idx - 1] + length(gens[idx - 1]) + 1
            else
                start_id[idx] = start_id[idx - 1] + length(gens[idx - 1])
            end
        end

        if (length(reg_wind_gens[idx]) > 0 && length(reg_pv_gens[idx]) > 0)
            region_gen_idxs[idx] = range(start_id[idx], length=length(gens[idx]) + 2)
        elseif (length(reg_wind_gens[idx]) > 0 || length(reg_pv_gens[idx]) > 0)
            region_gen_idxs[idx] = range(start_id[idx], length=length(gens[idx]) + 1)
        else
            region_gen_idxs[idx] = range(start_id[idx], length=length(gens[idx]))
        end
    end
    lumped_mapping = Dict{String, Vector{PSY.Device}}()
    for (gen, region, reg_wind_gen, reg_pv_gen) in
        zip(gens, regions, reg_wind_gens, reg_pv_gens)
        if (length(reg_wind_gen) > 0)
            # Wind
            temp_lumped_wind_gen = PSY.RenewableDispatch(nothing)
            PSY.set_name!(temp_lumped_wind_gen, "Lumped_Wind_" * PSY.get_name(region))
            PSY.set_prime_mover_type!(temp_lumped_wind_gen, PSY.PrimeMovers.WT)
            push!(lumped_mapping, "Lumped_Wind_" * PSY.get_name(region) => reg_wind_gen)
            push!(gen, temp_lumped_wind_gen)
        end
        if (length(reg_pv_gen) > 0)
            # PV
            temp_lumped_pv_gen = PSY.RenewableDispatch(nothing)
            PSY.set_name!(temp_lumped_pv_gen, "Lumped_PV_" * PSY.get_name(region))
            PSY.set_prime_mover_type!(temp_lumped_pv_gen, PSY.PrimeMovers.PVe)
            push!(lumped_mapping, "Lumped_PV_" * PSY.get_name(region) => reg_pv_gen)
            push!(gen, temp_lumped_pv_gen)
        end
    end
    gen = reduce(vcat, gens)
    return gen, region_gen_idxs, lumped_mapping
end

"""
    $(TYPEDSIGNATURES)

Extraction of storage devices using formulation dictionary to create a list of storage
devices and appropriate indices for PRAS.
"""
function get_storage_region_indices(
    sys::PSY.System,
    s2p_meta::S2P_metadata,
    regions,
    component_to_formulation::Dict{PSY.Device, StoragePRAS},
)
    stors = Array{PSY.Device}[]
    start_id = Array{Int64}(undef, length(regions))
    region_stor_idxs = Array{UnitRange{Int64}, 1}(undef, length(regions))

    for (idx, region) in enumerate(regions)
        reg_stor_comps =
            get_available_components_in_aggregation_topology(PSY.Storage, sys, region)
        stor = filter(
            x ->
                haskey(component_to_formulation, x) &&
                    PSY.IS.get_uuid(x) ∉ s2p_meta.hs_uuids,
            reg_stor_comps,
        )
        # To ensure reproducability when testing
        sort!(stor, by=s -> s.name)
        push!(stors, stor)
        idx == 1 ? start_id[idx] = 1 :
        start_id[idx] = start_id[idx - 1] + length(stors[idx - 1])
        region_stor_idxs[idx] = range(start_id[idx], length=length(stors[idx]))
    end
    return reduce(vcat, stors), region_stor_idxs
end

"""
    $(TYPEDSIGNATURES)

Extract components with a generator storage formulation.
"""
function get_gen_storage_region_indices(
    sys::PSY.System,
    regions,
    component_to_formulation::Dict{PSY.Device, GeneratorStoragePRAS},
)
    gen_stors = Array{PSY.Device}[]
    start_id = Array{Int64}(undef, length(regions))
    region_genstor_idxs = Array{UnitRange{Int64}, 1}(undef, length(regions))

    for (idx, region) in enumerate(regions)
        reg_gen_stor_comps =
            get_available_components_in_aggregation_topology(PSY.Generator, sys, region)
        gs = filter(x -> haskey(component_to_formulation, x), reg_gen_stor_comps)
        # To ensure reproducability when testing
        sort!(gs, by=g -> g.name)
        push!(gen_stors, gs)
        idx == 1 ? start_id[idx] = 1 :
        start_id[idx] = start_id[idx - 1] + length(gen_stors[idx - 1])
        region_genstor_idxs[idx] = range(start_id[idx], length=length(gen_stors[idx]))
    end
    return reduce(vcat, gen_stors), region_genstor_idxs
end

"""
Turn a time series into an Array of floored ints
"""
function get_pras_array_from_timeseries(device::PSY.Device, name)
    return floor.(Int, PSY.get_time_series_values(PSY.SingleTimeSeries, device, name))
end

"""
    $(TYPEDSIGNATURES)

Apply GeneratorPRAS to process all generators objects
into rows in PRAS matrices:
- Capacity, λ, μ

Negative max active power will translate into zeros for time series data.
"""
function process_generators(
    gen::Array{PSY.Device},
    s2p_meta::S2P_metadata,
    component_to_formulation::Dict{PowerSystems.Device, GeneratorPRAS},
    lumped_mapping::Dict{String, Vector{PSY.Device}},
)
    gen_names, gen_categories = if isempty(gen)
        String[], String[]
    else
        PSY.get_name.(gen), get_generator_category.(gen)
    end

    n_gen = length(gen_names)

    gen_cap_array = Matrix{Int64}(undef, n_gen, s2p_meta.N)
    λ_gen = Matrix{Float64}(undef, n_gen, s2p_meta.N)
    μ_gen = Matrix{Float64}(undef, n_gen, s2p_meta.N)

    #FIXME This should use a component map instead.
    for (idx, g) in enumerate(gen)
        if haskey(lumped_mapping, g.name)
            reg_gens_DA = lumped_mapping[g.name]
            gen_cap_array[idx, :] =
                round.(
                    Int,
                    sum([
                        PSY.get_time_series_values(
                            PSY.SingleTimeSeries,
                            reg_gen,
                            get_max_active_power(component_to_formulation[reg_gen]),
                        ) for reg_gen in reg_gens_DA
                    ]),
                )
        else
            if (PSY.has_time_series(
                g,
                PSY.SingleTimeSeries,
                get_max_active_power(component_to_formulation[g]),
            ))
                gen_cap_array[idx, :] = get_pras_array_from_timeseries(
                    g,
                    get_max_active_power(component_to_formulation[g]),
                )
                if !(all(gen_cap_array[idx, :] .>= 0))
                    @warn "There are negative values in max active time series data for $(PSY.get_name(g)) of type $(gen_categories[idx]) is negative. Using zeros for time series data."
                    gen_cap_array[idx, :] = zeros(Int, s2p_meta.N)
                end
            else
                if (PSY.get_max_active_power(g) > 0)
                    gen_cap_array[idx, :] =
                        fill.(floor.(Int, PSY.get_max_active_power(g)), 1, s2p_meta.N)
                else
                    @warn "Max active power for $(PSY.get_name(g)) of type $(gen_categories[idx]) is negative. Using zeros for time series data."
                    gen_cap_array[idx, :] = zeros(Int, s2p_meta.N) # to handle components with negative active power (usually UNAVAIALABLE)
                end
            end
        end

        λ_gen[idx, :], μ_gen[idx, :] = if haskey(lumped_mapping, g.name)
            get_outage_time_series_data(g, s2p_meta)
        else
            get_outage_time_series_data(g, s2p_meta, component_to_formulation[g])
        end
    end

    return PRASCore.Generators{
        s2p_meta.N,
        s2p_meta.pras_timestep,
        s2p_meta.pras_resolution,
        PRASCore.MW,
    }(
        gen_names,
        gen_categories,
        gen_cap_array,
        λ_gen,
        μ_gen,
    )
end

function assign_to_stor_matrices!(
    ::EnergyReservoirSoC,
    s::PSY.Device,
    s2p_meta::S2P_metadata,
    charge_cap_array,
    discharge_cap_array,
    energy_cap_array,
    chrg_eff_array,
    dischrg_eff_array,
)
    fill!(charge_cap_array, floor(Int, PSY.get_input_active_power_limits(s).max))
    fill!(discharge_cap_array, floor(Int, PSY.get_output_active_power_limits(s).max))
    fill!(
        energy_cap_array,
        floor(Int, PSY.get_storage_level_limits(s).max * PSY.get_storage_capacity(s)),
    )
    fill!(chrg_eff_array, PSY.get_efficiency(s).in)
    fill!(dischrg_eff_array, PSY.get_efficiency(s).out)
end

"""
    $(TYPEDSIGNATURES)

Apply StoragePRAS to process all storage objects
"""
function process_storage(
    stor::Array{PSY.Device},
    s2p_meta::S2P_metadata,
    component_to_formulation::Dict{PSY.Device, StoragePRAS},
)
    stor_names, stor_categories = if isempty(stor)
        String[], String[]
    else
        PSY.get_name.(stor), get_generator_category.(stor)
    end

    n_stor = length(stor_names)

    stor_charge_cap_array = Matrix{Int64}(undef, n_stor, s2p_meta.N)
    stor_discharge_cap_array = Matrix{Int64}(undef, n_stor, s2p_meta.N)
    stor_energy_cap_array = Matrix{Int64}(undef, n_stor, s2p_meta.N)
    stor_chrg_eff_array = Matrix{Float64}(undef, n_stor, s2p_meta.N)
    stor_dischrg_eff_array = Matrix{Float64}(undef, n_stor, s2p_meta.N)
    λ_stor = Matrix{Float64}(undef, n_stor, s2p_meta.N)
    μ_stor = Matrix{Float64}(undef, n_stor, s2p_meta.N)

    for (idx, s) in enumerate(stor)
        assign_to_stor_matrices!(
            component_to_formulation[s],
            s,
            s2p_meta,
            view(stor_charge_cap_array, idx, :),
            view(stor_discharge_cap_array, idx, :),
            view(stor_energy_cap_array, idx, :),
            view(stor_chrg_eff_array, idx, :),
            view(stor_dischrg_eff_array, idx, :),
        )

        λ_stor[idx, :], μ_stor[idx, :] =
            get_outage_time_series_data(s, s2p_meta, component_to_formulation[s])
    end

    stor_cryovr_eff = ones(n_stor, s2p_meta.N)   # Not currently available/ defined in PowerSystems

    return PRASCore.Storages{
        s2p_meta.N,
        s2p_meta.pras_timestep,
        s2p_meta.pras_resolution,
        PRASCore.MW,
        PRASCore.MWh,
    }(
        stor_names,
        stor_categories,
        stor_charge_cap_array,
        stor_discharge_cap_array,
        stor_energy_cap_array,
        stor_chrg_eff_array,
        stor_dischrg_eff_array,
        stor_cryovr_eff,
        λ_stor,
        μ_stor,
    )
end

"""
    $(TYPEDSIGNATURES)

Apply HybridSystem Formulation to fill in a row of a PRAS Matrix.
Views should be passed in for all arrays.
"""
function assign_to_gen_stor_matrices!(
    formulation::HybridSystemPRAS,
    g_s::PSY.Device,
    s2p_meta::S2P_metadata,
    turbine_to_reservoir_mapping::Dict{PSY.HydroUnit, PSY.HydroReservoir},
    charge_cap_array,
    discharge_cap_array,
    inflow_array,
    energy_cap_array,
    gridinj_cap_array,
    gridwdr_cap_array,
)
    fill!(
        charge_cap_array,
        floor(Int, PSY.get_input_active_power_limits(PSY.get_storage(g_s)).max),
    )
    fill!(
        discharge_cap_array,
        floor(Int, PSY.get_output_active_power_limits(PSY.get_storage(g_s)).max),
    )
    fill!(
        energy_cap_array,
        floor(
            Int,
            PSY.storage_level_limits(PSY.get_storage(g_s)).max *
            PSY.get_storage_capacity(PSY.get_storage(g_s)),
        ),
    )
    fill!(gridinj_cap_array, floor(Int, PSY.get_output_active_power_limits(g_s).max))
    fill!(gridwdr_cap_array, floor(Int, PSY.get_input_active_power_limits(g_s).max))

    if (PSY.has_time_series(
        PSY.get_renewable_unit(g_s),
        PSY.SingleTimeSeries,
        get_max_active_power(formulation),
    ))
        inflow_array .= get_pras_array_from_timeseries(
            PSY.get_renewable_unit(g_s),
            get_max_active_power(formulation),
        )
    else
        fill!(
            inflow_array,
            floor(Int, PSY.get_max_active_power(PSY.get_renewable_unit(g_s))),
        )
    end
end

"""
    $(TYPEDSIGNATURES)

Apply HydroEnergyReservoir Formulation to fill in a row of a PRAS Matrix.
Views should be passed in for all arrays.
"""
# Charging to GeneratorStorage is limited by charge_capacity whether from grid or from 
# inflows. So, that charge_capacity should be at least equal to the inflow timeseries.
# If other constraints exists (penstock?), and need to represented, this could be represented
#  as well.
# Powerflow into grid is limited by grid_injection, which can come from discharge
# and/or exogenous inflow. gridinjcap should be turbine dispatch limit
# Discharge capacity can be the turbine dispatch limit or 
# arbitrarily high because this represents discharge from reservoir to turbine +
# inflows
# Energy capacity can be arbitrarily high in the absence of reservoir limit to 
# ensure month to month energy energy carryover.
# Gridwithdrawl capacity is limited by pump capacity and eventually also by the 
# charge capacity
function assign_to_gen_stor_matrices!(
    formulation::HydroEnergyReservoirPRAS,
    g_s::PSY.Device,
    s2p_meta::S2P_metadata,
    turbine_to_reservoir_mapping::Dict{PSY.HydroUnit, PSY.HydroReservoir},
    charge_cap_array,
    discharge_cap_array,
    inflow_array,
    energy_cap_array,
    gridinj_cap_array,
    gridwdr_cap_array,
)
    if (PSY.has_time_series(g_s))
        if (PSY.has_time_series(
            turbine_to_reservoir_mapping[g_s],
            PSY.SingleTimeSeries,
            get_inflow(formulation),
        ))
            charge_cap_array .= get_pras_array_from_timeseries(
                turbine_to_reservoir_mapping[g_s],
                get_inflow(formulation),
            )
            inflow_array .= charge_cap_array
        else
            fill!(
                charge_cap_array,
                floor(Int, PSY.get_inflow(turbine_to_reservoir_mapping[g_s])),
            )
            fill!(
                inflow_array,
                floor(Int, PSY.get_inflow(turbine_to_reservoir_mapping[g_s])),
            )
        end
        if (PSY.has_time_series(
            turbine_to_reservoir_mapping[g_s],
            PSY.SingleTimeSeries,
            get_storage_capacity(formulation),
        ))
            energy_cap_array .= get_pras_array_from_timeseries(
                turbine_to_reservoir_mapping[g_s],
                get_storage_capacity(formulation),
            )
        else
            fill!(
                energy_cap_array,
                floor(
                    Int,
                    PSY.get_storage_level_limits(turbine_to_reservoir_mapping[g_s]).max,
                ),
            )
        end
        if (PSY.has_time_series(
            g_s,
            PSY.SingleTimeSeries,
            get_max_active_power(formulation),
        ))
            gridinj_cap_array .=
                get_pras_array_from_timeseries(g_s, get_max_active_power(formulation))
            discharge_cap_array .= gridinj_cap_array
        else
            fill!(gridinj_cap_array, floor(Int, PSY.get_max_active_power(g_s)))
            fill!(discharge_cap_array, floor(Int, PSY.get_max_active_power(g_s)))
        end
    else
        fill!(
            charge_cap_array,
            floor(Int, PSY.get_inflow(turbine_to_reservoir_mapping[g_s])),
        )
        fill!(discharge_cap_array, floor(Int, PSY.get_max_active_power(g_s)))
        fill!(
            energy_cap_array,
            floor(Int, PSY.get_storage_level_limits(turbine_to_reservoir_mapping[g_s]).max),
        )
        fill!(inflow_array, floor(Int, PSY.get_inflow(turbine_to_reservoir_mapping[g_s])))
        fill!(gridinj_cap_array, floor(Int, PSY.get_max_active_power(g_s)))
    end
    if (isa(g_s, PSY.HydroPumpTurbine))
        fill!(gridwdr_cap_array, floor(Int, PSY.get_active_power_limits_pump(g_s).max))
    else
        gridwdr_cap_array .= zeros(Int64, s2p_meta.N)
    end
end

"""
    $(TYPEDSIGNATURES)

Apply GeneratorStoragePRAS to create PRAS matrices for generator storage
"""
function process_genstorage(
    gen_stor::Array{PSY.Device},
    s2p_meta::S2P_metadata,
    component_to_formulation::Dict{PSY.Device, GeneratorStoragePRAS};
    turbine_to_reservoir_mapping::Dict{PSY.HydroUnit, PSY.HydroReservoir},
)
    gen_stor_names, gen_stor_categories = if isempty(gen_stor)
        String[], String[]
    else
        PSY.get_name.(gen_stor), get_generator_category.(gen_stor)
    end

    n_genstors = length(gen_stor_names)

    gen_stor_charge_cap_array = Matrix{Int64}(undef, n_genstors, s2p_meta.N)
    gen_stor_discharge_cap_array = Matrix{Int64}(undef, n_genstors, s2p_meta.N)
    gen_stor_enrgy_cap_array = Matrix{Int64}(undef, n_genstors, s2p_meta.N)
    gen_stor_inflow_array = Matrix{Int64}(undef, n_genstors, s2p_meta.N)
    gen_stor_gridinj_cap_array = Matrix{Int64}(undef, n_genstors, s2p_meta.N)
    gen_stor_gridwdr_cap_array = Matrix{Int64}(undef, n_genstors, s2p_meta.N)

    λ_genstors = Matrix{Float64}(undef, n_genstors, s2p_meta.N)
    μ_genstors = Matrix{Float64}(undef, n_genstors, s2p_meta.N)

    for (idx, g_s) in enumerate(gen_stor)
        assign_to_gen_stor_matrices!(
            component_to_formulation[g_s],
            g_s,
            s2p_meta,
            turbine_to_reservoir_mapping,
            view(gen_stor_charge_cap_array, idx, :),
            view(gen_stor_discharge_cap_array, idx, :),
            view(gen_stor_inflow_array, idx, :),
            view(gen_stor_enrgy_cap_array, idx, :),
            view(gen_stor_gridinj_cap_array, idx, :),
            view(gen_stor_gridwdr_cap_array, idx, :),
        )

        λ_genstors[idx, :], μ_genstors[idx, :] =
            get_outage_time_series_data(g_s, s2p_meta, component_to_formulation[g_s])
    end

    # Not currently available/ defined in PowerSystems
    gen_stor_charge_eff = ones(n_genstors, s2p_meta.N)                # Not currently available/ defined in PowerSystems
    gen_stor_discharge_eff = ones(n_genstors, s2p_meta.N)             # Not currently available/ defined in PowerSystems
    gen_stor_cryovr_eff = ones(n_genstors, s2p_meta.N)                # Not currently available/ defined in PowerSystems

    return PRASCore.GeneratorStorages{
        s2p_meta.N,
        s2p_meta.pras_timestep,
        s2p_meta.pras_resolution,
        PRASCore.MW,
        PRASCore.MWh,
    }(
        gen_stor_names,
        gen_stor_categories,
        gen_stor_charge_cap_array,
        gen_stor_discharge_cap_array,
        gen_stor_enrgy_cap_array,
        gen_stor_charge_eff,
        gen_stor_discharge_eff,
        gen_stor_cryovr_eff,
        gen_stor_inflow_array,
        gen_stor_gridwdr_cap_array,
        gen_stor_gridinj_cap_array,
        λ_genstors,
        μ_genstors,
    )
end

"""
    $(TYPEDSIGNATURES)

Apply LinePRAS to create PRAS matrices for lines. Views should be passed in.
"""
function assign_to_line_matrices!(
    ::LinePRAS,
    line::PSY.Branch,
    s2p_meta::S2P_metadata,
    forward_cap,
    backward_cap,
)
    fill!(forward_cap, floor(Int, line_rating(line).forward_capacity))
    fill!(backward_cap, floor(Int, line_rating(line).backward_capacity))
end

"""
    $(TYPEDSIGNATURES)

Create PRAS from sorted lines and formulations.
"""
function process_lines(
    sorted_lines::Vector{PSY.Branch},
    s2p_meta::S2P_metadata,
    lines_to_formulation::Dict{PSY.Device, LinePRAS},
)
    # Lines
    num_lines = length(sorted_lines)
    line_names = (num_lines == 0) ? String[] : PSY.get_name.(sorted_lines)
    line_cats = (num_lines == 0) ? String[] : line_type.(sorted_lines)

    line_forward_cap = Matrix{Int64}(undef, num_lines, s2p_meta.N)
    line_backward_cap = Matrix{Int64}(undef, num_lines, s2p_meta.N)
    line_λ = Matrix{Float64}(undef, num_lines, s2p_meta.N) # Not currently available/ defined in PowerSystems
    line_μ = Matrix{Float64}(undef, num_lines, s2p_meta.N) # Not currently available/ defined in PowerSystems

    for (i, line) in enumerate(sorted_lines)
        assign_to_line_matrices!(
            lines_to_formulation[line],
            line,
            s2p_meta,
            view(line_forward_cap, i, :),
            view(line_backward_cap, i, :),
        )

        line_λ[i, :], line_μ[i, :] = get_outage_time_series_data(line, s2p_meta)
    end

    return PRASCore.Lines{
        s2p_meta.N,
        s2p_meta.pras_timestep,
        s2p_meta.pras_resolution,
        PRASCore.MW,
    }(
        line_names,
        line_cats,
        line_forward_cap,
        line_backward_cap,
        line_λ,
        line_μ,
    )
end

"""
    $(TYPEDSIGNATURES)

Create PRAS interfaces from PRAS Lines
"""
function build_interfaces_from_lines(
    line_forward_cap::Matrix{Int64},
    line_backward_cap::Matrix{Int64},
    interface_reg_idxs::Vector{Tuple{Int64, Int64}},
    interface_line_idxs::Vector{UnitRange{Int64}},
    s2p_meta::S2P_metadata,
)
    num_interfaces = length(interface_line_idxs)
    interface_forward_capacity_array = Matrix{Int64}(undef, num_interfaces, s2p_meta.N)
    interface_backward_capacity_array = Matrix{Int64}(undef, num_interfaces, s2p_meta.N)
    for (i, line_indices) in enumerate(interface_line_idxs)
        interface_forward_capacity_array[i, :] =
            sum(line_forward_cap[line_indices, :], dims=1)
        interface_backward_capacity_array[i, :] =
            sum(line_backward_cap[line_indices, :], dims=1)
    end

    return PRASCore.Interfaces{s2p_meta.N, PRASCore.MW}(
        first.(interface_reg_idxs),
        last.(interface_reg_idxs),
        interface_forward_capacity_array,
        interface_backward_capacity_array,
    )
end

"""
    $(TYPEDSIGNATURES)

Add flow limits of an Sienna interface to an existing PRAS interface
"""
function add_to_interface!(
    ::AreaInterchangeLimit,
    interface,
    s2p_meta,
    forward_row,
    backward_row,
)
    forward_row .+= floor(Int, PSY.get_flow_limits(interface).from_to)
    backward_row .+= floor(Int, PSY.get_flow_limits(interface).to_from)
end

"""
    $(TYPEDSIGNATURES)

Process interfaces using a formulation dictionary to create PRAS matrices.
"""
function process_interfaces(
    interface_reg_idxs::Vector{Tuple{Int64, Int64}},
    regions,
    s2p_meta::S2P_metadata,
    interfaces_to_formulation::Dict{PSY.Device, InterfacePRAS},
)
    num_interfaces = length(interface_reg_idxs)
    interface_forward_capacity = zeros(Int64, num_interfaces, s2p_meta.N)
    interface_backward_capacity = zeros(Int64, num_interfaces, s2p_meta.N)
    regions_to_idx = Dict(
        (regions[idx1], regions[idx2]) => i for
        (i, (idx1, idx2)) in enumerate(interface_reg_idxs)
    )

    for (interface, formulation) in interfaces_to_formulation
        area_arc = (PSY.get_from_area(interface), PSY.get_to_area(interface))
        if haskey(regions_to_idx, area_arc)
            forward_row = view(interface_forward_capacity, regions_to_idx[area_arc], :)
            backward_row = view(interface_backward_capacity, regions_to_idx[area_arc], :)
        elseif haskey(regions_to_idx, reverse(area_arc))
            area_arc = reverse(area_arc)
            forward_row = view(interface_backward_capacity, regions_to_idx[area_arc], :)
            backward_row = view(interface_forward_capacity, regions_to_idx[area_arc], :)
        else
            error("Interface $(PSY.get_name(interface)) does not have any lines.")
        end
        add_to_interface!(formulation, interface, s2p_meta, forward_row, backward_row)
    end

    return PRASCore.Interfaces{s2p_meta.N, PRASCore.MW}(
        first.(interface_reg_idxs),
        last.(interface_reg_idxs),
        interface_forward_capacity,
        interface_backward_capacity,
    )
end

"""
    $(TYPEDSIGNATURES)

Use a RATemplate to create a PRAS system from a Sienna system.

# Arguments

- `sys::PSY.System`: Sienna PowerSystems System
- `template::RATemplate`: RATemplate
- `export_location::Union{Nothing, String}`: Export location for PRAS SystemModel

# Returns

- `PRASCore.SystemModel`: PRAS SystemModel

# Examples

```julia
generate_pras_system(sys, template)
```

Note that the original system will only be set to NATURAL_UNITS.
"""
function generate_pras_system(
    sys::PSY.System,
    template::RATemplate,
    export_location::Union{Nothing, String}=nothing,
)::PRASCore.SystemModel

    # PRAS needs Sienna\Data PowerSystems.jl System to be in NATURAL_UNITS
    PSY.set_units_base_system!(sys, PSY.UnitSystem.NATURAL_UNITS)

    # Check if any GeometricDistributionForcedOutage objects exist in the System
    outages = PSY.get_supplemental_attributes(PSY.GeometricDistributionForcedOutage, sys)

    # If no GeometricDistributionForcedOutage objects exist, add them to relevant components in the System
    if isempty(outages)
        add_default_data!(sys)
    end
    #######################################################
    # PRAS timestamps
    # Need this to select timeseries values of interest
    # TODO: Is it okay to assume each System will have a
    # SingleTimeSeries?
    #######################################################
    # Ensure Sienna/Data System has static time series
    ts_counts = PSY.get_time_series_counts(sys)
    if iszero(ts_counts.static_time_series_count)
        error(
            "System doesn't have any StaticTimeSeries. Other TimeSeries types are not suitable for resource adequacy analysis.",
        )
    end

    static_ts_summary = PSY.get_static_time_series_summary_table(sys)
    s2p_meta = S2P_metadata(static_ts_summary)

    start_datetime_tz = TimeZones.ZonedDateTime(s2p_meta.first_timestamp, TimeZones.tz"UTC")
    step = s2p_meta.pras_resolution(s2p_meta.pras_timestep)
    finish_datetime_tz =
        start_datetime_tz + s2p_meta.pras_resolution((s2p_meta.N - 1) * step)
    my_timestamps = StepRange(start_datetime_tz, step, finish_datetime_tz)

    @info "The first timestamp of PRAS System being built is : $(start_datetime_tz) and last timestamp is : $(finish_datetime_tz) "
    #######################################################
    # Ensure no double counting of HybridSystem subcomponents
    # TODO: Not sure if we need this anymore.
    #######################################################
    dup_uuids = Base.UUID[]
    h_s_comps = PSY.get_available_components(PSY.HybridSystem, sys)
    for h_s in h_s_comps
        push!(dup_uuids, PSY.IS.get_uuid.(PSY._get_components(h_s))...)
    end
    # Add HybridSystem sub component UUIDs to s2p_meta
    if !(isempty(dup_uuids))
        s2p_meta.hs_uuids = dup_uuids
    end
    #######################################################
    # PRAS Regions - Areas in PowerSystems.jl
    #######################################################
    @info "Processing $(template.aggregation) objects in Sienna/Data PowerSystems System... "
    regions = collect(PSY.get_components(template.aggregation, sys))
    if !(length(regions) == 0)
        @info "The Sienna/Data PowerSystems System has $(length(regions)) regions based on PSY AggregationTopology : $(template.aggregation)."
    else
        error(
            "No regions in the Sienna/Data PowerSystems System. Cannot proceed with the process of making a PRAS SystemModel.",
        )
    end

    loads_to_formula = build_component_to_formulation(LoadPRAS, sys, template.device_models)
    region_load = get_region_loads(s2p_meta, regions, loads_to_formula)
    new_regions =
        PRASCore.Regions{s2p_meta.N, PRASCore.MW}(PSY.get_name.(regions), region_load)

    @info "Processing Generators in PSY System... "
    gens_to_formula =
        build_component_to_formulation(GeneratorPRAS, sys, template.device_models)
    gens, region_gen_idxs, lumped_mapping =
        get_generator_region_indices(sys, s2p_meta, regions, gens_to_formula)

    # Add SupplementalAttribute if get_add_default_transition_probabilities is true
    # Ignoring lumped generators here because they don't need the attribute added
    for g in gens
        haskey(lumped_mapping, g.name) && continue
        if (
            get_add_default_transition_probabilities(gens_to_formula[g]) && isempty(
                PSY.get_supplemental_attributes(PSY.GeometricDistributionForcedOutage, g),
            )
        )
            PSY.add_supplemental_attribute!(sys, g, DEFAULT_OUTAGE_DATA_SUPP_ATTR)
        end
    end

    new_generators = process_generators(gens, s2p_meta, gens_to_formula, lumped_mapping)

    # **TODO Future : time series for storage devices
    @info "Processing Storages in PSY System... "
    stors_to_formula =
        build_component_to_formulation(StoragePRAS, sys, template.device_models)
    stors, region_stor_idxs =
        get_storage_region_indices(sys, s2p_meta, regions, stors_to_formula)

    # Add SupplementalAttribute if get_add_default_transition_probabilities is true
    for s in stors
        if (
            get_add_default_transition_probabilities(stors_to_formula[s]) && isempty(
                PSY.get_supplemental_attributes(PSY.GeometricDistributionForcedOutage, s),
            )
        )
            PSY.add_supplemental_attribute!(sys, s, DEFAULT_OUTAGE_DATA_SUPP_ATTR)
        end
    end

    new_storage = process_storage(stors, s2p_meta, stors_to_formula)

    # **TODO Consider all combinations of HybridSystem (Currently only works for DER+ESS)
    @info "Processing GeneratorStorages in PSY System... "
    gen_stors_to_formula =
        build_component_to_formulation(GeneratorStoragePRAS, sys, template.device_models)
    gen_stors, region_genstor_idxs =
        get_gen_storage_region_indices(sys, regions, gen_stors_to_formula)
    
    ##TODO Check if HydroEnergyReservoir formulation is being used

    # Add SupplementalAttribute if get_add_default_transition_probabilities is true
    for g_s in gen_stors
        if (
            get_add_default_transition_probabilities(gen_stors_to_formula[g_s]) && isempty(
                PSY.get_supplemental_attributes(PSY.GeometricDistributionForcedOutage, g_s),
            )
        )
            PSY.add_supplemental_attribute!(sys, g_s, DEFAULT_OUTAGE_DATA_SUPP_ATTR)
        end
    end

    # Turbine to Reservoir Mapping
    turbine_to_reservoir_mapping = get_turbine_to_reservoir_mapping(sys)
    new_gen_stors = process_genstorage(
        gen_stors,
        s2p_meta,
        gen_stors_to_formula,
        turbine_to_reservoir_mapping=turbine_to_reservoir_mapping,
    )

    #######################################################
    # Network
    #######################################################
    if (length(regions) > 1)
        #######################################################
        # PRAS Lines
        #######################################################
        @info "Collecting all inter regional lines in Sienna/Data PowerSystems System..."

        lines_to_formulation =
            build_component_to_formulation(LinePRAS, sys, template.device_models)
        lines = collect(
            PSY.Branch,
            filter(
                x -> !(x.arc.from.area.name == x.arc.to.area.name),
                keys(lines_to_formulation),
            ),
        )
        # To ensure reproducability when testing
        sort!(lines, by=l -> l.name)
        # Sorting here let's us better control the interface/line link
        sorted_lines, interface_reg_idxs, interface_line_idxs =
            get_sorted_lines(lines, PSY.get_name.(regions))
        @assert length(sorted_lines) == length(lines)
        @assert length(interface_reg_idxs) == length(interface_line_idxs)  # num_interfaces
        @assert sum(length.(interface_line_idxs)) == length(lines)
        @assert issorted(interface_line_idxs, lt=(x1, x2) -> x1.stop < x2.start)
        new_lines = process_lines(sorted_lines, s2p_meta, lines_to_formulation)

        interfaces_to_formulation =
            build_component_to_formulation(InterfacePRAS, sys, template.device_models)
        if !isempty(interfaces_to_formulation)
            interfaces = process_interfaces(
                interface_reg_idxs,
                regions,
                s2p_meta,
                interfaces_to_formulation,
            )
        else
            interfaces = build_interfaces_from_lines(
                new_lines.forward_capacity,
                new_lines.backward_capacity,
                interface_reg_idxs,
                interface_line_idxs,
                s2p_meta,
            )
        end

        pras_system = PRASCore.SystemModel(
            new_regions,
            interfaces,
            new_generators,
            region_gen_idxs,
            new_storage,
            region_stor_idxs,
            new_gen_stors,
            region_genstor_idxs,
            new_lines,
            interface_line_idxs,
            my_timestamps,
        )

        @info "Successfully built a PRAS SystemModel of type $(typeof(pras_system))."
        export_pras_system(pras_system, export_location::Union{Nothing, String})

        return pras_system

    else
        load_vector = vec(sum(region_load, dims=1))
        pras_system = PRASCore.SystemModel(
            new_generators,
            new_storage,
            new_gen_stors,
            my_timestamps,
            load_vector,
        )

        @info "Successfully built a PRAS SystemModel of type $(typeof(pras_system))."

        export_pras_system(pras_system, export_location::Union{Nothing, String})

        return pras_system
    end
end

const DEFAULT_DEVICE_MODELS = [
    DeviceRAModel(PSY.Line, LinePRAS),
    DeviceRAModel(PSY.MonitoredLine, LinePRAS),
    DeviceRAModel(PSY.TwoTerminalGenericHVDCLine, LinePRAS),
    DeviceRAModel(PSY.StaticLoad, StaticLoadPRAS),
    DeviceRAModel(PSY.ThermalGen, GeneratorPRAS),
    DeviceRAModel(PSY.RenewableGen, GeneratorPRAS),
    DeviceRAModel(PSY.HydroDispatch, GeneratorPRAS),
    DeviceRAModel(PSY.EnergyReservoirStorage, EnergyReservoirSoC),
    DeviceRAModel(PSY.HybridSystem, HybridSystemPRAS),
    DeviceRAModel(PSY.HydroTurbine, HydroEnergyReservoirPRAS),
    DeviceRAModel(PSY.HydroPumpTurbine, HydroEnergyReservoirPRAS),
]

const _LUMPED_RENEWABLE_DEVICE_MODELS = [
    DeviceRAModel(PSY.Line, LinePRAS),
    DeviceRAModel(PSY.MonitoredLine, LinePRAS),
    DeviceRAModel(PSY.TwoTerminalGenericHVDCLine, LinePRAS),
    DeviceRAModel(PSY.StaticLoad, StaticLoadPRAS),
    DeviceRAModel(PSY.ThermalGen, GeneratorPRAS),
    DeviceRAModel(PSY.RenewableGen, GeneratorPRAS, lump_renewable_generation=true),
    DeviceRAModel(PSY.HydroDispatch, GeneratorPRAS),
    DeviceRAModel(PSY.EnergyReservoirStorage, EnergyReservoirSoC),
    DeviceRAModel(PSY.HybridSystem, HybridSystemPRAS),
    DeviceRAModel(PSY.HydroTurbine, HydroEnergyReservoirPRAS),
    DeviceRAModel(PSY.HydroPumpTurbine, HydroEnergyReservoirPRAS),
]

const DEFAULT_TEMPLATE = RATemplate(PSY.Area, DEFAULT_DEVICE_MODELS)

"""
    $(TYPEDSIGNATURES)

Sienna/Data PowerSystems.jl System is the input and an object of PRAS SystemModel is returned.
...

# Arguments

  - `sys::PSY.System`: Sienna/Data PowerSystems.jl System
  - `aggregation<:PSY.AggregationTopology`: "PSY.Area" (or) "PSY.LoadZone" {Optional}
  - `lump_region_renewable_gens::Bool`: Whether to lumps PV and Wind generators in a region because usually these generators don't have FOR data {Optional}
  - `export_location::String`: Export location of the .pras file
    ...

# Returns

    - `PRASCore.SystemModel`: PRAS SystemModel object

# Examples

```julia-repl
julia> generate_pras_system(psy_sys, PSY.Area)
PRAS SystemModel
```
"""
function generate_pras_system(
    sys::PSY.System,
    aggregation::Type{AT},
    lump_region_renewable_gens::Bool=false,
    export_location::Union{Nothing, String}=nothing,
)::PRASCore.SystemModel where {AT <: PSY.AggregationTopology}
    if lump_region_renewable_gens
        template = RATemplate(aggregation, _LUMPED_RENEWABLE_DEVICE_MODELS)
    else
        template = RATemplate(aggregation, DEFAULT_DEVICE_MODELS)
    end
    generate_pras_system(sys, template, export_location)
end

"""
    generate_pras_system(sys_location::String, aggregation; kwargs...)

Generate a PRAS SystemModel from a Sienna/Data PowerSystems System JSON file.

# Arguments

  - `sys_location::String`: Location of the Sienna/Data PowerSystems System JSON file
  - `aggregation::Type{AT}`: Aggregation topology type
  - `lump_region_renewable_gens::Bool`: Lumping of region renewable generators
  - `export_location::Union{Nothing, String}`: Export location of the .pras file

# Returns

  - `PRASCore.SystemModel`: PRAS SystemModel
"""
function generate_pras_system(
    sys_location::String,
    aggregation::Type{AT},
    lump_region_renewable_gens=false,
    export_location::Union{Nothing, String}=nothing,
) where {AT <: PSY.AggregationTopology}
    @info "Running checks on the Sienna/Data PowerSystems System location provided ..."
    runchecks(sys_location)

    @info "The Sienna/Data PowerSystems System is being de-serialized from the System JSON ..."
    sys = try
        PSY.System(sys_location; time_series_read_only=true, runchecks=false)
    catch
        error(
            "Sienna/Data PowerSystems System could not be de-serialized using the location of JSON provided. Please check the location and make sure you have permission to access time_series_storage.h5",
        )
    end

    generate_pras_system(sys, aggregation, lump_region_renewable_gens, export_location)
end
