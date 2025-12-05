@testset "Test RTS-GMLC Time Series" begin
    rts_da_sys =
        PSCB.build_system(PSCB.SPISystems, "RTS_GMLC_Hourly with TimeSeries Outage Data")

    num_samples = 100
    sequential_monte_carlo = SiennaPRASInterface.SequentialMonteCarlo(
        samples=num_samples,
        threaded=false,
        verbose=false,
        seed=1,
    )
    shortfall, surplus, storage_energy = SiennaPRASInterface.assess(
        rts_da_sys,
        PSY.Area,
        sequential_monte_carlo,
        SiennaPRASInterface.Shortfall(),
        SiennaPRASInterface.Surplus(),
        SiennaPRASInterface.StorageEnergy(),
    )

    # Access Results
    eue = SiennaPRASInterface.val(SiennaPRASInterface.EUE(shortfall))
    lole = SiennaPRASInterface.val(SiennaPRASInterface.LOLE(shortfall))
    @test (eue - 296000) < 10
    @test (lole - 450) < 10
end

@testset "Test RTS-GMLC Time Series RATemplate" begin
    rts_da_sys =
        PSCB.build_system(PSCB.SPISystems, "RTS_GMLC_Hourly with TimeSeries Outage Data")
    template_1 = SiennaPRASInterface.RATemplate(
        PSY.Area,
        [
            DeviceRAModel(PSY.StaticLoad, StaticLoadPRAS),
            DeviceRAModel(
                PSY.ThermalGen,
                GeneratorPRAS(add_default_transition_probabilities=true),
            ),
        ],
    )
    pras_sys_1 = generate_pras_system(rts_da_sys, template_1)

    for comp in PSY.get_components(PSY.Generator, rts_da_sys)
        if (
            PSY.has_supplemental_attributes(comp, PSY.GeometricDistributionForcedOutage) &&
            PSY.has_time_series(
                first(
                    PSY.get_supplemental_attributes(
                        PSY.GeometricDistributionForcedOutage,
                        comp,
                    ),
                ),
                PSY.SingleTimeSeries,
            )
        )
            comp_supp_attr = first(
                PSY.get_supplemental_attributes(
                    PSY.GeometricDistributionForcedOutage,
                    comp,
                ),
            )

            outage_ts = PSY.get_time_series(
                PSY.SingleTimeSeries,
                comp_supp_attr,
                "outage_probability",
            )
            PSY.remove_time_series!(
                rts_da_sys,
                PSY.SingleTimeSeries,
                comp_supp_attr,
                "outage_probability",
            )
            outage_ts.name = "Outage_Probability"
            PSY.add_time_series!(rts_da_sys, comp_supp_attr, outage_ts)

            recovery_ts = PSY.get_time_series(
                PSY.SingleTimeSeries,
                comp_supp_attr,
                "recovery_probability",
            )
            PSY.remove_time_series!(
                rts_da_sys,
                PSY.SingleTimeSeries,
                comp_supp_attr,
                "recovery_probability",
            )
            recovery_ts.name = "Recovery_Probability"
            PSY.add_time_series!(rts_da_sys, comp_supp_attr, recovery_ts)
        end
    end

    template_2 = SiennaPRASInterface.RATemplate(
        PSY.Area,
        [
            DeviceRAModel(PSY.StaticLoad, StaticLoadPRAS),
            DeviceRAModel(
                PSY.ThermalGen,
                GeneratorPRAS(
                    add_default_transition_probabilities=true,
                    outage_probability="Outage_Probability",
                    recovery_probability="Recovery_Probability",
                ),
            ),
        ],
    )

    pras_sys_2 = generate_pras_system(rts_da_sys, template_2)
    match_count = 0
    for (idx, name) in enumerate(pras_sys_1.generators.names)
        gen_idx = findfirst(pras_sys_2.generators.names .== name)
        if (
            all(pras_sys_2.generators.λ[gen_idx, :] .== pras_sys_1.generators.λ[idx, :]) &&
            all(pras_sys_2.generators.μ[gen_idx, :] .== pras_sys_1.generators.μ[idx, :])
        )
            match_count = match_count + 1
        end
    end
    @test length(pras_sys_2.generators.names) == length(pras_sys_1.generators.names)
    @test match_count == length(pras_sys_1.generators.names)
end

@testset "Test TimeSeriesForcedOutage Avaialability Time Series Generation - PJM" begin
    pjm_sys = PSCB.build_system(PSCB.PSISystems, "two_area_pjm_DA")
    device_models = SiennaPRASInterface.DeviceRAModel[
        DeviceRAModel(PSY.ThermalStandard, GeneratorPRAS),
        DeviceRAModel(
            PSY.RenewableDispatch,
            GeneratorPRAS(lump_renewable_generation=false),
        ),
    ]
    template = SiennaPRASInterface.RATemplate(PSY.Area, device_models)
    sampling_method =
        SiennaPRASInterface.SequentialMonteCarlo(samples=10, seed=1, threaded=false)
    generate_outage_profile!(pjm_sys, template, sampling_method)
    @test all(
        PSY.has_time_series.(
            PSY.get_supplemental_attributes(PSY.GeometricDistributionForcedOutage, pjm_sys)
        ),
    )
end

@testset "Test TimeSeriesForcedOutage Avaialability Time Series Generation - RTS" begin
    rts_sys = PSCB.build_system(PSCB.SPISystems, "RTS_GMLC_Hourly with Static Outage Data")
    template =
        SiennaPRASInterface.RATemplate(PSY.Area, SiennaPRASInterface.DEFAULT_DEVICE_MODELS)
    sampling_method =
        SiennaPRASInterface.SequentialMonteCarlo(samples=10, seed=1, threaded=false)
    generate_outage_profile!(rts_sys, template, sampling_method)
    @test all(
        PSY.has_supplemental_attributes.(
            PSY.get_components(
                x -> PSY.get_max_active_power(x) > 0,
                PSY.Generator,
                rts_sys,
            ),
            PSY.GeometricDistributionForcedOutage,
        ),
    )

    @test all(
        PSY.has_time_series.(
            PSY.get_supplemental_attributes(PSY.GeometricDistributionForcedOutage, rts_sys)
        ),
    )
end
