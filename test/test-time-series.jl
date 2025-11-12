@testset "Test RTS-GMLC Time Series" begin
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
            PSY.SingleTimeSeries(
                "outage_probability",
                TimeSeries.TimeArray(ts_timestamps, λ_vals),
            ),
        )
        PSY.add_time_series!(
            rts_da_sys,
            first(
                PSY.get_supplemental_attributes(
                    PSY.GeometricDistributionForcedOutage,
                    comp,
                ),
            ),
            PSY.SingleTimeSeries(
                "recovery_probability",
                TimeSeries.TimeArray(ts_timestamps, μ_vals),
            ),
        )
        @info "Added outage probability and recovery probability time series to supplemental attribute of $(row["Unit"]) generator"
    end

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
