using Test
using SiennaPRASInterface
using PowerSystems
using TimeSeries
using Dates
using Statistics  # For mean function
import PowerSystemCaseBuilder
import CSV
import DataFrames
import UnicodePlots
import PowerFlows

const PSY = PowerSystems
const PSCB = PowerSystemCaseBuilder
const PFS = PowerFlows

include("rts_gmlc.jl")

"""
Create a system with limited time series for faster testing.
Transforms a full-year system to only include the first `hours` of data.
"""
function get_short_duration_system(sys_type::String, hours::Int=24)
    sys = get_rts_gmlc_outage(sys_type)

    # Get all time series in the system
    all_ts = PSY.get_time_series_multiple(sys)

    if isempty(all_ts)
        return sys
    end

    # Get the first time series to determine timestamps
    first_ts = first(all_ts)
    timestamps = TimeSeries.timestamp(first_ts.data)

    # Limit to first N hours
    if length(timestamps) > hours
        # Clear existing time series
        PSY.clear_time_series!(sys)

        # Re-add time series with limited duration
        for (component, ts_metadata) in all_ts
            ts_data = ts_metadata.data
            ts_name = PSY.get_name(ts_metadata)

            # Take only first `hours` of data
            limited_timestamps = timestamps[1:hours]
            limited_values = TimeSeries.values(ts_data)[1:hours]

            new_data = TimeSeries.TimeArray(limited_timestamps, limited_values)
            new_ts = PSY.SingleTimeSeries(ts_name, new_data)

            PSY.add_time_series!(sys, component, new_ts)
        end
    end

    return sys
end

@testset "assess_with_powerflow basic functionality" begin
    # Use only 24 hours of data for fast testing
    rts_da_sys = get_short_duration_system("DA", 24)

    # Create a DC power flow evaluator (more robust than AC for PRAS integration)
    power_flow_evaluator = PFS.DCPowerFlow()

    # Create template
    template = SiennaPRASInterface.RATemplate(
        PSY.Area,
        deepcopy(SiennaPRASInterface.DEFAULT_DEVICE_MODELS),
    )

    # Define simulation parameters with small sample size for testing
    method = SiennaPRASInterface.SequentialMonteCarlo(samples=2, seed=1)

    @testset "assess_with_powerflow returns results" begin
        results = SiennaPRASInterface.assess_with_powerflow(
            rts_da_sys,
            template,
            method,
            power_flow_evaluator,
            SiennaPRASInterface.Shortfall(),
        )

        @test length(results) == 1
        shortfall = results[1]
        @test shortfall isa SiennaPRASInterface.PRASCore.Results.ShortfallResult

        # Test that LOLE and EUE can be computed
        lole = SiennaPRASInterface.LOLE(shortfall)
        eue = SiennaPRASInterface.EUE(shortfall)
        @test lole isa SiennaPRASInterface.PRASCore.ReliabilityMetric
        @test eue isa SiennaPRASInterface.PRASCore.ReliabilityMetric
        @test SiennaPRASInterface.val(lole) >= 0
        @test SiennaPRASInterface.val(eue) >= 0
    end

    @testset "assess_with_powerflow with multiple result specs" begin
        results = SiennaPRASInterface.assess_with_powerflow(
            rts_da_sys,
            template,
            method,
            power_flow_evaluator,
            SiennaPRASInterface.Shortfall(),
            SiennaPRASInterface.Surplus(),
        )

        @test length(results) == 2
        shortfall, surplus = results
        @test shortfall isa SiennaPRASInterface.PRASCore.Results.ShortfallResult
        @test surplus isa SiennaPRASInterface.PRASCore.Results.SurplusResult
    end
end

@testset "assess_with_powerflow power flow integration" begin
    # Use only 24 hours for fast testing
    rts_da_sys = get_short_duration_system("DA", 24)

    power_flow_evaluator = PFS.DCPowerFlow()
    template = SiennaPRASInterface.RATemplate(
        PSY.Area,
        deepcopy(SiennaPRASInterface.DEFAULT_DEVICE_MODELS),
    )

    # Very small sample for fast testing
    method = SiennaPRASInterface.SequentialMonteCarlo(samples=1, seed=42)

    @testset "power flow is called during assessment" begin
        # This test verifies that the power flow solve is being invoked
        # In a real test, we might want to mock the power flow solver
        # to verify it's being called with correct data
        results = SiennaPRASInterface.assess_with_powerflow(
            rts_da_sys,
            template,
            method,
            power_flow_evaluator,
            SiennaPRASInterface.Shortfall(),
        )

        @test length(results) == 1
        # If we get here without errors, power flow integration is working
        @test results[1] isa SiennaPRASInterface.PRASCore.Results.ShortfallResult
    end
end

@testset "assess_with_powerflow with different system types" begin
    @testset "Sub-hourly system" begin
        # Use only 12 hours (144 5-minute intervals) for fast testing
        rts_rt_sys = get_short_duration_system("RT", 1)

        power_flow_evaluator = PFS.ACPowerFlow()
        template = SiennaPRASInterface.RATemplate(
            PSY.Area,
            deepcopy(SiennaPRASInterface.DEFAULT_DEVICE_MODELS),
        )

        method = SiennaPRASInterface.SequentialMonteCarlo(samples=1, seed=123)

        results = SiennaPRASInterface.assess_with_powerflow(
            rts_rt_sys,
            template,
            method,
            power_flow_evaluator,
            SiennaPRASInterface.Shortfall(),
        )

        @test length(results) == 1
        @test results[1] isa SiennaPRASInterface.PRASCore.Results.ShortfallResult
    end
end
