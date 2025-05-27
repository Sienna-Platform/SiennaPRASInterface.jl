@testset "Test RTS-GMLC Time Series" begin
    rts_da_sys =
        get_rts_gmlc_outage_timeseries(["outage_probability", "recovery_probability"])

    num_samples = 100
    sequential_monte_carlo = SiennaPRASInterface.SequentialMonteCarlo(
        samples=num_samples,
        threaded=true,
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
    @test (eue - 94683.2) < 10000
    @test (lole - 200) < 10
end

@testset "Test RTS-GMLC Time Series RATemplate" begin
    rts_da_sys =
        get_rts_gmlc_outage_timeseries(["outage_probability", "recovery_probability"])
    template = RATemplate(PSY.Area, copy(SiennaPRASInterface.DEFAULT_DEVICE_MODELS))
    pras_sys_1 = generate_pras_system(rts_da_sys, template)
    # TODO We neeed to fix remove_time_series! to work with SupplementalAttribute for this test to work, for now, get_rts_gmlc_outage_timeseries() will take
    # time series names as args.
    #=
    for comp in PSY.get_components(PSY.Generator, rts_da_sys)
        if (PSY.has_supplemental_attributes(comp, PSY.GeometricDistributionForcedOutage) && PSY.has_time_series(first(PSY.get_supplemental_attributes(PSY.GeometricDistributionForcedOutage, comp)), PSY.SingleTimeSeries))
            comp_supp_attr = first(PSY.get_supplemental_attributes(PSY.GeometricDistributionForcedOutage, comp))

            outage_ts = PSY.get_time_series(PSY.SingleTimeSeries, comp_supp_attr, "outage_probability")
            # Need to do this because remove_time_series!() is not defined for SupplementalAttributes?
            PSY.IS.remove_time_series!(rts_da_sys.data.time_series_manager.data_store, PSY.IS.get_uuid(outage_ts))
            PSY.IS.assign_new_uuid_internal!(outage_ts)
            #=
            PSY.remove_time_series!(
                rts_da_sys,
                PSY.SingleTimeSeries,
                comp_supp_attr,
                "outage_probability",
            )
            =#
            outage_ts.name = "Outage_Probability"
            PSY.add_time_series!(rts_da_sys, comp_supp_attr, outage_ts)

            recovery_ts = PSY.get_time_series(PSY.SingleTimeSeries, comp_supp_attr, "recovery_probability")
            # Need to do this because remove_time_series!() is not defined for SupplementalAttributes?
            PSY.IS.remove_time_series!(rts_da_sys.data.time_series_manager.data_store, PSY.IS.get_uuid(recovery_ts))
            PSY.IS.assign_new_uuid_internal!(recovery_ts)
            #=
            PSY.remove_time_series!(
                rts_da_sys,
                PSY.SingleTimeSeries,
                comp_supp_attr,
                "recovery_probability",
            )
            =#
            recovery_ts.name = "Recovery_Probability"
            PSY.add_time_series!(rts_da_sys, comp_supp_attr, recovery_ts)
        end
    end
    =#
    rts_da_sys_1 =
        get_rts_gmlc_outage_timeseries(["Outage_Probability", "Recovery_Probability"])
    problem_template = SiennaPRASInterface.RATemplate(
        PSY.Area,
        [
            SiennaPRASInterface.DeviceRAModel(PSY.Line, SiennaPRASInterface.LinePRAS()),
            SiennaPRASInterface.DeviceRAModel(
                PSY.MonitoredLine,
                SiennaPRASInterface.LinePRAS(),
            ),
            SiennaPRASInterface.DeviceRAModel(
                PSY.TwoTerminalHVDCLine,
                SiennaPRASInterface.LinePRAS(),
            ),
            SiennaPRASInterface.DeviceRAModel(
                PSY.StaticLoad,
                SiennaPRASInterface.StaticLoadPRAS(),
            ),
            SiennaPRASInterface.DeviceRAModel(
                PSY.ThermalGen,
                SiennaPRASInterface.GeneratorPRAS(
                    outage_probability="Outage_Probability",
                    recovery_probability="Recovery_Probability",
                ),
            ),
            SiennaPRASInterface.DeviceRAModel(
                PSY.HydroDispatch,
                SiennaPRASInterface.GeneratorPRAS(),
            ),
            SiennaPRASInterface.DeviceRAModel(
                PSY.RenewableGen,
                SiennaPRASInterface.GeneratorPRAS(),
            ),
            SiennaPRASInterface.DeviceRAModel(
                PSY.EnergyReservoirStorage,
                SiennaPRASInterface.EnergyReservoirLossless(),
            ),
            SiennaPRASInterface.DeviceRAModel(
                PSY.HydroEnergyReservoir,
                SiennaPRASInterface.HydroEnergyReservoirPRAS(),
            ),
        ],
    )
    pras_sys_2 = generate_pras_system(rts_da_sys_1, problem_template)
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
    sampling_method = SiennaPRASInterface.SequentialMonteCarlo(samples=10, seed=1)
    generate_outage_profile!(pjm_sys, template, sampling_method)
    @test all(
        PSY.has_supplemental_attributes.(
            PSY.get_components(PSY.Generator, pjm_sys),
            PSY.TimeSeriesForcedOutage,
        ),
    )
    @test all(
        PSY.has_time_series.(
            PSY.get_supplemental_attributes(PSY.TimeSeriesForcedOutage, pjm_sys)
        ),
    )
end

@testset "Test TimeSeriesForcedOutage Avaialability Time Series Generation - RTS" begin
    rts_sys = get_rts_gmlc_outage("DA")
    template =
        SiennaPRASInterface.RATemplate(PSY.Area, SiennaPRASInterface.DEFAULT_DEVICE_MODELS)
    sampling_method = SiennaPRASInterface.SequentialMonteCarlo(samples=10, seed=1)
    generate_outage_profile!(rts_sys, template, sampling_method)
    @test all(
        PSY.has_supplemental_attributes.(
            PSY.get_components(
                x -> PSY.get_max_active_power(x) > 0,
                PSY.Generator,
                rts_sys,
            ),
            PSY.TimeSeriesForcedOutage,
        ),
    )

    @test all(
        PSY.has_supplemental_attributes.(
            PSY.get_components(PSY.Storage, rts_sys),
            PSY.TimeSeriesForcedOutage,
        ),
    )

    @test all(
        PSY.has_time_series.(
            PSY.get_supplemental_attributes(PSY.TimeSeriesForcedOutage, rts_sys)
        ),
    )
end
