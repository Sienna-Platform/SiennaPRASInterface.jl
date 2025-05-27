"""
Use PSCB to build RTS-GMLC System and add outage data
as a Supplmental Attribute
"""
function get_rts_gmlc_outage(sys_type::String)
    sys_name = "RTS_GMLC_$(sys_type)_sys"
    rts_sys = PSCB.build_system(PSCB.PSISystems, sys_name)

    ###########################################
    # Parse the gen.csv and add OutageData
    # SupplementalAttribute to components for
    # which we have this data
    ###########################################
    gen_for_data = CSV.read(joinpath(@__DIR__, "descriptors/gen.csv"), DataFrames.DataFrame)

    for row in DataFrames.eachrow(gen_for_data)
        λ, μ = SiennaPRASInterface.rate_to_probability(row.FOR, row["MTTR Hr"])
        transition_data = PSY.GeometricDistributionForcedOutage(;
            mean_time_to_recovery=row["MTTR Hr"],
            outage_transition_probability=λ,
        )
        comp = PSY.get_component(PSY.Generator, rts_sys, row["GEN UID"])

        if !isnothing(comp)
            PSY.add_supplemental_attribute!(rts_sys, comp, transition_data)
            @debug "Added outage data supplemental attribute to $(row["GEN UID"]) generator"
        else
            @warn "$(row["GEN UID"]) generator doesn't exist in the System."
        end
    end
    return rts_sys
end

function get_rts_gmlc_outage_timeseries(ts_names::Vector{String})
    rts_da_sys = get_rts_gmlc_outage("DA")
    rts_test_outage_ts_data = CSV.read(
        joinpath(@__DIR__, "RTS_Test_Outage_Time_Series_Data.csv"),
        DataFrames.DataFrame,
    )

    # Time series timestamps
    filter_func = x -> (typeof(x) <: PSY.StaticTimeSeries)
    all_ts = PSY.get_time_series_multiple(rts_da_sys, filter_func)
    ts_timestamps = TimeSeries.timestamp(first(all_ts).data)
    first_timestamp = first(ts_timestamps)

    # Add λ and μ time series 
    for row in DataFrames.eachrow(rts_test_outage_ts_data)
        comp = PSY.get_component(PSY.Generator, rts_da_sys, row.Unit)
        λ_vals = Float64[]
        μ_vals = Float64[]
        for i in range(0, length=12)
            next_timestamp = first_timestamp + Dates.Month(i)
            λ, μ = SiennaPRASInterface.rate_to_probability(row[3 + i], 48)
            append!(λ_vals, fill(λ, (Dates.daysinmonth(next_timestamp) * 24)))
            append!(μ_vals, fill(μ, (Dates.daysinmonth(next_timestamp) * 24)))
        end
        PSY.add_time_series!(
            rts_da_sys,
            first(
                PSY.get_supplemental_attributes(
                    PSY.GeometricDistributionForcedOutage,
                    comp,
                ),
            ),
            PSY.SingleTimeSeries(ts_names[1], TimeSeries.TimeArray(ts_timestamps, λ_vals)),
        )
        PSY.add_time_series!(
            rts_da_sys,
            first(
                PSY.get_supplemental_attributes(
                    PSY.GeometricDistributionForcedOutage,
                    comp,
                ),
            ),
            PSY.SingleTimeSeries(ts_names[2], TimeSeries.TimeArray(ts_timestamps, μ_vals)),
        )
        @info "Added outage probability and recovery probability time series to supplemental attribute of $(row["Unit"]) generator"
    end
    return rts_da_sys
end
