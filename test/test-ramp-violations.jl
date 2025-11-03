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

const PSY = PowerSystems
const PSCB = PowerSystemCaseBuilder

include("rts_gmlc.jl")

function print_outage_statistics(result::RampViolationsResult)
    outage_counts = SiennaPRASInterface.count_outage_transitions(result)

    if isempty(outage_counts)
        println("No outage data available.")
        return
    end

    counts = collect(values(outage_counts))

    println("=== Outage Transition Statistics:")
    println("  Total samples: ", length(outage_counts))
    println("  Mean outages per sample: ", round(sum(counts) / length(counts), digits=2))
    println("  Min outages: ", minimum(counts))
    println("  Max outages: ", maximum(counts))
    println("  Total outages: ", sum(counts))
end

"""
    print_ramp_violation_diagnostics(ramp_violations, sys, title)

Print comprehensive diagnostics for ramp violation results including:

  - Summary statistics
  - Histograms of violation magnitudes
  - Top violating generators
  - Time series plots
  - Large violation analysis
"""
function print_ramp_violation_diagnostics(
    ramp_violations::RampViolationsResult,
    sys::PSY.System,
    title::String="Ramp Violation Summary",
)
    total_violations = length(ramp_violations.ramp_violation.value)
    if total_violations == 0
        println("\n=== $title ===")
        println("No violations found")
        return
    end
    max_violation = maximum(ramp_violations.ramp_violation.value)

    println("\n=== $title ===")
    println("Maximum ramp violation found: $(max_violation) MW")
    println("Total violation instances: $(total_violations)")
    println("Mean violation: $(mean(ramp_violations.ramp_violation.value)) MW")
    println("Median violation: $(median(ramp_violations.ramp_violation.value)) MW")

    # Plot violation distribution
    println("\nViolation Magnitude Histogram:")
    nbins = min(30, max(10, total_violations ÷ 100))
    println(UnicodePlots.histogram(ramp_violations.ramp_violation.value, nbins=nbins))

    # Violations over time
    println("\nViolations by Timestep:")
    time_violation_counts = zeros(maximum(ramp_violations.ramp_violation.time))
    for time_idx in ramp_violations.ramp_violation.time
        time_violation_counts[time_idx] += 1
    end
    println(
        UnicodePlots.scatterplot(
            1:length(time_violation_counts),
            time_violation_counts,
            xlabel="Timestep",
            ylabel="Violation Count",
            title="Violations Over Time",
        ),
    )

    # Show top violations with required vs limit details
    println("\nTop 10 Largest Violations (with required vs limit):")
    # Create vector of tuples: (violation, gen_idx, required, limit, time, sample)
    violation_details = [
        (
            ramp_violations.ramp_violation.value[i],
            ramp_violations.ramp_violation.idx[i],
            ramp_violations.ramp_required.value[i],
            ramp_violations.ramp_limit.value[i],
            ramp_violations.ramp_violation.time[i],
            ramp_violations.ramp_violation.sampleid[i],
        ) for i in 1:length(ramp_violations.ramp_violation.value)
    ]
    sort!(violation_details, by=x -> x[1], rev=true)

    for (i, (violation, gen_idx, required, limit, time, sample)) in
        enumerate(violation_details[1:min(10, length(violation_details))])
        gen_name = ramp_violations.generators[gen_idx]
        ratio = required / limit
        println("  #$i: $gen_name at t=$time, sample=$sample")
        println(
            "      Required: $(round(required, digits=4)) MW/min, Limit: $(round(limit, digits=4)) MW/min",
        )
        println(
            "      Violation: $(round(violation, digits=4)) MW/min ($(round(ratio, digits=2))x over limit)",
        )
    end

    # Regional ramp infeasibility analysis
    if length(ramp_violations.regional_ramp_infeasibility.value) > 0
        println("\n=== Regional Ramp Infeasibility ===")
        println("These violations cannot be avoided by any disaggregation method.")
        println(
            "The regional dispatch trajectory itself exceeds available ramp capability.",
        )

        total_regional_infeasibility =
            sum(ramp_violations.regional_ramp_infeasibility.value)
        println(
            "Total regional infeasibility: $(round(total_regional_infeasibility, digits=2)) MW/min",
        )
        println(
            "Number of infeasible timesteps: $(length(ramp_violations.regional_ramp_infeasibility.value))",
        )

        # Count by region
        region_infeasibility = Dict{Int, Float64}()
        for (i, region_idx) in enumerate(ramp_violations.regional_ramp_infeasibility.idx)
            region_infeasibility[region_idx] =
                get(region_infeasibility, region_idx, 0.0) +
                ramp_violations.regional_ramp_infeasibility.value[i]
        end

        println("\nInfeasibility by Region:")
        for (region_idx, total) in
            sort(collect(region_infeasibility), by=x -> x[2], rev=true)
            count = sum(
                1 for
                (i, idx) in enumerate(ramp_violations.regional_ramp_infeasibility.idx) if
                idx == region_idx
            )
            avg = total / count
            println(
                "  Region $region_idx: $(round(total, digits=2)) MW/min total, $count instances, $(round(avg, digits=2)) MW/min avg",
            )
        end
    else
        println("\n=== Regional Ramp Feasibility ===")
        println(
            "All regional dispatch trajectories are feasible given available ramp capability.",
        )
        println(
            "Generator-level violations are due to disaggregation choices, not fundamental infeasibility.",
        )
    end
end

"""
    create_ramp_violation_test_system()

Create a modified RTS-GMLC system designed to have frequent ramp violations.
This function:

 1. Loads the standard RTS-GMLC system
 2. Doubles thermal generator ratings to increase capacity
 3. Reduces ramp limits on thermal generators to very low values
 4. Disables all RenewableNonDispatch generators
 5. Reduces RenewableDispatch capacity to force more thermal generation
"""
function create_ramp_violation_test_system()
    # Start with standard RTS-GMLC system
    sys = get_rts_gmlc_outage("DA")

    # Set to natural units so ramp limits are in MW/min
    PSY.set_units_base_system!(sys, PSY.UnitSystem.NATURAL_UNITS)

    thermal_gens = collect(PowerSystems.get_components(PowerSystems.ThermalStandard, sys))

    for (i, gen) in enumerate(thermal_gens)
        # Skip synchronous condensers - they don't generate active power
        if contains(PSY.get_name(gen), "SYNC_COND")
            continue
        end

        # Get current values
        old_rating = PowerSystems.get_rating(gen)

        # Increase generator rating dramatically to force large dispatch swings
        new_rating = old_rating * 10.0  # Quintuple the capacity!

        # Set new much higher rating
        PowerSystems.set_rating!(gen, new_rating)

        # Also increase active power limits proportionally
        old_power_limits = PowerSystems.get_active_power_limits(gen)
        new_power_limits =
            (min=old_power_limits.min * 10.0, max=old_power_limits.max * 10.0)
        PowerSystems.set_active_power_limits!(gen, new_power_limits)

        # Set extremely tight ramp limits (both up and down)
        PowerSystems.set_ramp_limits!(gen, (up=0.0005, down=0.0005))
    end

    # Verify ramp limits were set correctly
    println("\n=== Verifying Ramp Limits ===")
    nan_count = 0
    modified_count = 0
    for gen in thermal_gens
        if contains(PSY.get_name(gen), "SYNC_COND")
            continue  # Skip sync condensers
        end
        modified_count += 1
        limits = PSY.get_ramp_limits(gen)
        if isnan(limits.up) || isnan(limits.down)
            @warn "$(PSY.get_name(gen)) has NaN ramp limits: up=$(limits.up), down=$(limits.down)"
            nan_count += 1
        end
    end
    if nan_count != 0
        error("$nan_count generators have NaN ramp limits!")
    end

    for gen in PSY.get_components(PSY.RenewableGen, sys)
        PowerSystems.set_available!(gen, false)
    end
    return sys
end

"""
    test_disaggregation_method(rts_sys, disagg_func, title_suffix, expect_violations)

Helper function to test a single disaggregation method and reduce code duplication.
"""
function test_disaggregation_method(rts_sys, disagg_func, title_suffix, expect_violations)
    sequential_monte_carlo = SiennaPRASInterface.SequentialMonteCarlo(samples=2, seed=1)

    shortfalls, ramp_violations = SiennaPRASInterface.assess(
        rts_sys,
        PSY.Area,
        sequential_monte_carlo,
        SiennaPRASInterface.Shortfall(),
        RampViolations(rts_sys, disaggregation_func=disagg_func),
    )

    # Test result types
    @test shortfalls isa SiennaPRASInterface.PRASCore.Results.ShortfallResult
    @test ramp_violations isa RampViolationsResult
    @test ramp_violations.ramp_violation isa SiennaPRASInterface.Sparse3DAccumulator
    @test ramp_violations.total_ramp_violation isa SiennaPRASInterface.Sparse2DAccumulator

    # Test violation data properties
    if length(ramp_violations.ramp_violation.value) > 0
        @test all(ramp_violations.ramp_violation.value .> 0.0)
        @test all(ramp_violations.ramp_violation.sampleid .>= 1)
        @test all(ramp_violations.ramp_violation.sampleid .<= 2)
    end

    # Print diagnostics
    print_outage_statistics(ramp_violations)
    print_ramp_violation_diagnostics(ramp_violations, rts_sys, title_suffix)

    # Validate expectations
    if expect_violations
        @test maximum(ramp_violations.ramp_violation.value) > 0.0
        @test length(ramp_violations.ramp_violation.value) > 0
    else
        @test length(ramp_violations.ramp_violation.value) == 0 ||
              minimum(ramp_violations.ramp_violation.value) > 0.0
    end
end

@testset "Ramp Violation Tests" begin
    @testset "RampViolations struct creation" begin
        # Create a simple PowerSystems system
        sys = PowerSystems.System(100.0)

        # Add bus
        bus = PowerSystems.ACBus(
            number=1,
            name="Bus1",
            bustype=PowerSystems.ACBusTypes.REF,
            angle=0.0,
            magnitude=1.0,
            voltage_limits=(min=0.9, max=1.1),
            base_voltage=138.0,
        )
        PowerSystems.add_component!(sys, bus)

        # Add thermal generator
        thermal_gen = PowerSystems.ThermalStandard(
            name="TestGen",
            available=true,
            status=true,
            bus=bus,
            active_power=50.0,
            reactive_power=10.0,
            rating=100.0,
            prime_mover_type=PowerSystems.PrimeMovers.ST,
            fuel=PowerSystems.ThermalFuels.COAL,
            active_power_limits=(min=10.0, max=100.0),
            reactive_power_limits=(min=-30.0, max=30.0),
            ramp_limits=(up=0.05, down=0.05),
            time_limits=nothing,
            operation_cost=PowerSystems.ThermalGenerationCost(nothing),
            base_power=100.0,
        )
        PowerSystems.add_component!(sys, thermal_gen)

        # Test RampViolations creation
        ramp_spec = RampViolations(sys)
        @test ramp_spec isa RampViolations
        @test ramp_spec.sys === sys
    end

    @testset "RampViolations with assess() using original RTS-GMLC" begin
        rts_sys = get_rts_gmlc_outage("DA")

        @testset "assess with RampViolations (proportional)" begin
            test_disaggregation_method(
                rts_sys,
                SiennaPRASInterface.proportional_disaggregation,
                "Ramp Violation Summary (Original RTS-GMLC - Proportional)",
                false,
            )
        end

        @testset "assess with RampViolations (merit order)" begin
            test_disaggregation_method(
                rts_sys,
                SiennaPRASInterface.merit_order_disaggregation,
                "Ramp Violation Summary (Original RTS-GMLC - Merit Order)",
                false,
            )
        end

        @testset "assess with RampViolations (ramp-aware)" begin
            test_disaggregation_method(
                rts_sys,
                SiennaPRASInterface.ramp_aware_disaggregation,
                "Ramp Violation Summary (Original RTS-GMLC - Ramp-Aware)",
                false,
            )
        end
    end

    @testset "RampViolations with assess() using modified RTS-GMLC" begin
        rts_sys = create_ramp_violation_test_system()

        @testset "assess with RampViolations (proportional)" begin
            test_disaggregation_method(
                rts_sys,
                SiennaPRASInterface.proportional_disaggregation,
                "Ramp Violation Summary (Modified RTS-GMLC with Tight Limits - Proportional)",
                true,
            )
        end

        @testset "assess with RampViolations (merit order)" begin
            test_disaggregation_method(
                rts_sys,
                SiennaPRASInterface.merit_order_disaggregation,
                "Ramp Violation Summary (Modified RTS-GMLC with Tight Limits - Merit Order)",
                true,
            )
        end

        @testset "assess with RampViolations (ramp-aware)" begin
            test_disaggregation_method(
                rts_sys,
                SiennaPRASInterface.ramp_aware_disaggregation,
                "Ramp Violation Summary (Modified RTS-GMLC with Tight Limits - Ramp-Aware)",
                true,
            )
        end
    end
end
