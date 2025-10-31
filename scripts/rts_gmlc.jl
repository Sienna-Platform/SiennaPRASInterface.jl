"""
Use PSCB to build RTS-GMLC System and add outage data
as a Supplemental Attribute
"""
function get_rts_gmlc_outage(sys_type::String)
    sys_name = "RTS_GMLC_$(sys_type)_sys"
    rts_sys = PSCB.build_system(PSCB.PSISystems, sys_name)

    ###########################################
    # Parse the gen.csv and add OutageData
    # SupplementalAttribute to components for
    # which we have this data
    ###########################################
    gen_for_data = CSV.read(
        joinpath(@__DIR__, "..", "test", "descriptors", "gen.csv"),
        DataFrames.DataFrame,
    )

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
