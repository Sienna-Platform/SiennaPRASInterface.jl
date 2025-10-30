using Test
using SiennaPRASInterface
using PowerSystems
using TimeSeries
using Dates
import PowerSystemCaseBuilder
import PowerFlows
import CSV
import DataFrames

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

@testset "PowerFlowWithOverloads basic functionality" begin
    # Use only 24 hours of data for fast testing
    rts_da_sys = get_short_duration_system("DA", 24)

    # Create a DC power flow evaluator
    power_flow_evaluator = PFS.DCPowerFlow()

    # Create template
    template = SiennaPRASInterface.RATemplate(
        PSY.Area,
        deepcopy(SiennaPRASInterface.DEFAULT_DEVICE_MODELS),
    )

    # Define simulation parameters with small sample size for testing
    method = SiennaPRASInterface.SequentialMonteCarlo(samples=2, seed=1, threaded=false)

    @testset "PowerFlowWithOverloads returns results" begin
        results = SiennaPRASInterface.assess(
            rts_da_sys,
            template,
            method,
            SiennaPRASInterface.Shortfall(),
            SiennaPRASInterface.PowerFlowWithOverloads(rts_da_sys, power_flow_evaluator),
        )

        @test length(results) == 2
        shortfall, line_overload = results

        @test shortfall isa SiennaPRASInterface.PRASCore.Results.ShortfallResult
        @test line_overload isa SiennaPRASInterface.LineOverloadResult

        # Test that we can compute metrics
        @test 0.0 <= line_overload.convergence_rate <= 1.0

        # Test utility functions
        n_events = SiennaPRASInterface.count_overload_events(line_overload)
        @test n_events >= 0

        prob = SiennaPRASInterface.overload_probability(line_overload)
        @test 0.0 <= prob <= 1.0

        println("Line overload results:")
        println("  Convergence rate: $(line_overload.convergence_rate)")
        println("  Total overload events: $n_events")
        println("  Overload probability: $prob")

        if n_events > 0
            most_overloaded = SiennaPRASInterface.get_most_overloaded_lines(line_overload, 5)
            println("  Most overloaded lines:")
            for (name, count, max_overload) in most_overloaded
                println("    $name: $count events, max overload = $(round(max_overload, digits=2)) MW")
            end
        end
    end

    # @testset "PowerFlowWithOverloads with AC power flow" begin
    #     # Test with AC power flow as well
    #     ac_pf = PFS.ACPowerFlow()

    #     results = SiennaPRASInterface.assess(
    #         rts_da_sys,
    #         template,
    #         method,
    #         SiennaPRASInterface.PowerFlowWithOverloads(rts_da_sys, ac_pf),
    #     )

    #     @test length(results) == 1
    #     line_overload = results[1]

    #     @test line_overload isa SiennaPRASInterface.LineOverloadResult
    #     @test line_overload.n_samples == 2
    #     @test 0.0 <= line_overload.convergence_rate <= 1.0

    #     println("\nAC Power Flow results:")
    #     println("  Convergence rate: $(line_overload.convergence_rate)")
    #     println("  Total overload events: $(SiennaPRASInterface.count_overload_events(line_overload))")
    # end
end

@testset "Line overload probability calculations" begin
    rts_da_sys = get_short_duration_system("DA", 24)
    power_flow_evaluator = PFS.DCPowerFlow()
    template = SiennaPRASInterface.RATemplate(
        PSY.Area,
        deepcopy(SiennaPRASInterface.DEFAULT_DEVICE_MODELS),
    )

    method = SiennaPRASInterface.SequentialMonteCarlo(samples=10, seed=42, threaded=false)

    results = SiennaPRASInterface.assess(
        rts_da_sys,
        template,
        method,
        SiennaPRASInterface.PowerFlowWithOverloads(rts_da_sys, power_flow_evaluator),
    )

    line_overload = results[1]

    @testset "Probability metrics" begin
        overall_prob = SiennaPRASInterface.overload_probability(line_overload)
        @test 0.0 <= overall_prob <= 1.0

        # Test individual line probabilities if there are overloads
        if SiennaPRASInterface.count_overload_events(line_overload) > 0
            most_overloaded = SiennaPRASInterface.get_most_overloaded_lines(line_overload, 1)
            if !isempty(most_overloaded)
                line_name = most_overloaded[1][1]
                line_prob = SiennaPRASInterface.line_overload_probability(line_overload, line_name)
                @test 0.0 < line_prob <= 1.0
                @test line_prob <= overall_prob  # Individual line prob <= overall prob

                println("\nProbability analysis:")
                println("  Overall overload probability: $(round(overall_prob, digits=4))")
                println("  Most overloaded line '$line_name': $(round(line_prob, digits=4))")
            end
        end
    end
end
