@testset "Test RTS-GMLC Time Series" begin
    rts_da_sys =
        PSCB.build_system(PSCB.SPISystems, "RTS_GMLC_Hourly with TimeSeries Outage Data")

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
        PSY.has_time_series.(
            PSY.get_supplemental_attributes(PSY.GeometricDistributionForcedOutage, pjm_sys)
        ),
    )
end

@testset "Test TimeSeriesForcedOutage Avaialability Time Series Generation - RTS" begin
    rts_sys = PSCB.build_system(PSCB.SPISystems, "RTS_GMLC_Hourly with Static Outage Data")
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
            PSY.GeometricDistributionForcedOutage,
        ),
    )

    @test all(
        PSY.has_time_series.(
            PSY.get_supplemental_attributes(PSY.GeometricDistributionForcedOutage, rts_sys)
        ),
    )
end
