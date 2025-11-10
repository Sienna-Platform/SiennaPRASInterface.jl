"""
Use PSCB to build RTS-GMLC System and add outage data
as a Supplemental Attribute

Arguments:
- sys_type: String - System type, e.g. "DA" for Day-Ahead
- modified: Bool - If true, use modified_RTS_GMLC; if false, use standard RTS_GMLC with 10% load increase
"""
function get_rts_gmlc_outage(sys_type::String; modified::Bool=true)
    sys_name = modified ? "modified_RTS_GMLC_$(sys_type)_sys" : "RTS_GMLC_$(sys_type)_sys"
    rts_sys = PSCB.build_system(PSCB.PSISystems, sys_name)

    # For unmodified systems, increase load by 10% to stress the system
    if !modified
        loads = PSY.get_components(PSY.StaticLoad, rts_sys)
        for load in loads
            current_base_power = PSY.get_base_power(load)
            new_base_power = current_base_power * 1.10
            PSY.set_base_power!(load, new_base_power)
        end
    end

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
