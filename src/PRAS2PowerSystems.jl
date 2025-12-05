"""
    $(TYPEDSIGNATURES)

Analyze resource adequacy using Monte Carlo simulation and add the asset status from the worst sample
to PSY.GeometricDistributionForcedOutage of the component.

# Arguments

  - `sys::PSY.System`: PowerSystems.jl system model
  - `template::RATemplate`: PRAS problem template
  - `method::PRASCore.SequentialMonteCarlo`: Simulation method to use

# Returns

 - PSY System with asset availability times series added to PSY.GeometricDistributionForcedOutage for all components for which asset status is available
"""
function generate_outage_profile!(
    sys::PSY.System,
    template::RATemplate,
    method::PRASCore.SequentialMonteCarlo,
)
    pras_system = generate_pras_system(sys, template)
    results = PRASCore.assess(pras_system, method, OUTAGE_RESULT_SPEC...)
    add_asset_status!(sys, SPIOutageResult(results), template)
    return sys
end

"""
    generate_outage_profile!(
        sys::PSY.System,
        aggregation::Type{AT},
        method::PRASCore.SequentialMonteCarlo,
    ) where {AT <: PSY.AggregationTopology, RM <: PRASCore.Results.ReliabilityMetric}

Analyze resource adequacy using Monte Carlo simulation and add the asset status from the worst sample
to PSY.GeometricDistributionForcedOutage of the component.

# Arguments

  - `sys::PSY.System`: PowerSystems.jl system model
  - `aggregation::Type{AT}`: Aggregation topology to use in translating to PRAS
  - `method::PRASCore.SequentialMonteCarlo`: Simulation method to use

# Returns

  - PSY System with asset availability times series added to PSY.GeometricDistributionForcedOutage for all components for which asset status is available
"""
function generate_outage_profile!(
    sys::PSY.System,
    aggregation::Type{AT},
    method::PRASCore.SequentialMonteCarlo,
) where {AT <: PSY.AggregationTopology}
    template = RATemplate(aggregation, DEFAULT_DEVICE_MODELS)
    sys = generate_outage_profile!(sys, template, method)
    return sys
end

"""
    $(TYPEDSIGNATURES)

Analyze resource adequacy using Monte Carlo simulation and add the asset status from the worst sample
to PSY.GeometricDistributionForcedOutage of the component.

Uses default template with PSY.Area AggregationTopology.

# Arguments

  - `sys::PSY.System`: PowerSystems.jl system model
  - `method::PRASCore.SequentialMonteCarlo`: Simulation method to use

# Returns

    - PSY System with asset availability times series added to PSY.GeometricDistributionForcedOutage for all components for which asset status is available
"""
function generate_outage_profile!(sys::PSY.System, method::PRASCore.SequentialMonteCarlo)
    sys = generate_outage_profile!(sys, DEFAULT_TEMPLATE, method)
    return sys
end

"""
    $(TYPEDSIGNATURES)

Add the asset status from the worst sample to GeometricDistributionForcedOutage of the component.

# Arguments

  - `sys::PSY.System`: PowerSystems.jl system model
  - `results::T`: SPIOutageResult
  - `template::RATemplate`: PRAS problem template
  
# Returns

    - PSY System with asset availability times series added to PSY.GeometricDistributionForcedOutage for all components for which asset status is available
"""
function add_asset_status!(sys::PSY.System, results::SPIOutageResult, template::RATemplate)
    # Time series timestamps
    static_ts_summary = PSY.get_static_time_series_summary_table(sys)
    s2p_meta = S2P_metadata(static_ts_summary)
    step = s2p_meta.pras_resolution(s2p_meta.pras_timestep)
    finish_datetime =
        s2p_meta.first_timestamp + s2p_meta.pras_resolution((s2p_meta.N - 1) * step)
    ts_timestamps = collect(StepRange(s2p_meta.first_timestamp, step, finish_datetime))

    shortfall_samples = results.shortfall_samples

    sample_idx = argmax(shortfall_samples[])

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
                if (PSY.has_supplemental_attributes(
                    PSY.GeometricDistributionForcedOutage,
                    gen,
                ))
                    availability_data = TimeSeries.TimeArray(
                        ts_timestamps,
                        getindex.(result[gen.name, :], sample_idx),
                    )
                    availability_timeseries = PSY.SingleTimeSeries(
                        "WorstShortfallSample_Availability_$(gen.name)",
                        availability_data,
                    )

                    PSY.add_time_series!(
                        sys,
                        first(
                            PSY.get_supplemental_attributes(
                                PSY.GeometricDistributionForcedOutage,
                                gen,
                            ),
                        ),
                        availability_timeseries,
                    )
                    @debug "Added availability time series to TimeSeriesForcedOutage supplemental attribute of $(gen.name)."
                else
                    @debug "Asset availability time series is available for $(gen.name) of $(typeof(gen)) type, but this generator doesn't have a GeometricDistributionForcedOutage SupplementalAttribute associated with it. "
                end
            else
                @debug "Asset availability time series not available for $(gen.name) of $(typeof(gen)) type. This generator either has zero max active power or was lumped based on the formulation."
            end
        end
    end
end
