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

    # Only show percentiles if we have enough data
    if total_violations >= 10
        println(
            "90th percentile: $(quantile(ramp_violations.ramp_violation.value, 0.9)) MW",
        )
        println(
            "99th percentile: $(quantile(ramp_violations.ramp_violation.value, 0.99)) MW",
        )
    end

    # Plot violation distribution
    println("\nViolation Magnitude Histogram:")
    nbins = min(30, max(10, total_violations ÷ 100))
    println(UnicodePlots.histogram(ramp_violations.ramp_violation.value, nbins=nbins))

    # Plot log-scale for better visibility if there's a long tail
    if max_violation > 10 * median(ramp_violations.ramp_violation.value)
        println("\nLog-scale Violation Histogram:")
        log_violations = log10.(ramp_violations.ramp_violation.value .+ 1e-6)
        println(UnicodePlots.histogram(log_violations, nbins=nbins, xlabel="log10(MW)"))
    end

    # Count violations per generator
    gen_violation_counts = Dict{Int, Int}()
    gen_violation_sums = Dict{Int, Float64}()
    for (i, gen_idx) in enumerate(ramp_violations.ramp_violation.idx)
        gen_violation_counts[gen_idx] = get(gen_violation_counts, gen_idx, 0) + 1
        gen_violation_sums[gen_idx] =
            get(gen_violation_sums, gen_idx, 0.0) + ramp_violations.ramp_violation.value[i]
    end

    # Top generators by total violation
    println("\nTop 10 Generators by Total Violation (MW):")
    sorted_gens_by_sum = sort(collect(gen_violation_sums), by=x -> x[2], rev=true)[1:min(
        10,
        length(gen_violation_sums),
    )]
    for (gen_idx, total_violation) in sorted_gens_by_sum
        gen_name = ramp_violations.generators[gen_idx]
        count = gen_violation_counts[gen_idx]
        avg_violation = total_violation / count
        println(
            "  $gen_name (idx $gen_idx): $(round(total_violation, digits=2)) MW total, $count violations, $(round(avg_violation, digits=2)) MW avg",
        )
    end

    # Top generators by violation count with ramp limit info
    println("\nTop 10 Generators by Violation Count:")
    sorted_gens_by_count =
        sort(collect(gen_violation_counts), by=x -> x[2], rev=true)[1:min(
            10,
            length(gen_violation_counts),
        )]
    for (gen_idx, count) in sorted_gens_by_count
        gen_name = ramp_violations.generators[gen_idx]
        gen = PSY.get_component(PSY.Generator, sys, gen_name)
        total_violation = gen_violation_sums[gen_idx]
        avg_violation = total_violation / count

        # Get ramp limits if available
        ramp_info = ""
        if isa(gen, Union{PSY.ThermalGen, PSY.HydroDispatch})
            ramp_limits = PSY.get_ramp_limits(gen)
            ramp_info = " (ramp: ↑$(round(ramp_limits.up, digits=4)) ↓$(round(ramp_limits.down, digits=4)) MW/min)"
        elseif isa(gen, PSY.RenewableDispatch)
            ramp_info = " (renewable dispatch)"
        end

        println(
            "  $gen_name (idx $gen_idx): $count violations, $(round(total_violation, digits=2)) MW total, $(round(avg_violation, digits=2)) MW avg$ramp_info",
        )
    end

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

    # Sample-wise violations
    println("\nTotal Violation per Sample:")
    sample_violations = ramp_violations.total_ramp_violation.value
    if length(sample_violations) > 0
        println("  Min: $(round(minimum(sample_violations), digits=2)) MW")
        println("  Max: $(round(maximum(sample_violations), digits=2)) MW")
        println("  Mean: $(round(mean(sample_violations), digits=2)) MW")
        println("  Median: $(round(median(sample_violations), digits=2)) MW")
    end

    # Analysis of large violations
    println("\nAnalysis of Large Violations (> 1 MW):")
    large_violations = filter(x -> x > 1.0, ramp_violations.ramp_violation.value)
    if length(large_violations) > 0
        println("  Count of violations > 1 MW: $(length(large_violations))")
        println(
            "  Percentage of total: $(round(100 * length(large_violations) / total_violations, digits=2))%",
        )
        println("  Mean of large violations: $(round(mean(large_violations), digits=2)) MW")

        # Find generators with large violations
        large_violation_gens = Dict{Int, Int}()
        for (i, val) in enumerate(ramp_violations.ramp_violation.value)
            if val > 1.0
                gen_idx = ramp_violations.ramp_violation.idx[i]
                large_violation_gens[gen_idx] = get(large_violation_gens, gen_idx, 0) + 1
            end
        end

        println("\n  Generators with most large violations (> 1 MW):")
        sorted_large = sort(collect(large_violation_gens), by=x -> x[2], rev=true)[1:min(
            5,
            length(large_violation_gens),
        )]
        for (gen_idx, count) in sorted_large
            gen_name = ramp_violations.generators[gen_idx]
            gen = PSY.get_component(PSY.Generator, sys, gen_name)
            if isa(gen, Union{PSY.ThermalGen, PSY.HydroDispatch})
                ramp_limits = PSY.get_ramp_limits(gen)
                println(
                    "    $gen_name: $count large violations (ramp limits: ↑$(round(ramp_limits.up, digits=4)) ↓$(round(ramp_limits.down, digits=4)) MW/min)",
                )
            else
                println("    $gen_name: $count large violations")
            end
        end
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
            println(
                "WARNING: $(PSY.get_name(gen)) has NaN ramp limits: up=$(limits.up), down=$(limits.down)",
            )
            nan_count += 1
        end
    end
    if nan_count == 0
        println(
            "Modified $modified_count thermal generators with valid ramp limits (skipped synchronous condensers)",
        )
    else
        println("ERROR: $nan_count generators have NaN ramp limits!")
    end
    println("=========================\n")

    for gen in PSY.get_components(PSY.RenewableGen, sys)
        PowerSystems.set_available!(gen, false)
    end
    return sys
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
        # Use the original RTS-GMLC test system
        rts_sys = get_rts_gmlc_outage("DA")

        # Create a sequential Monte Carlo method with a small number of samples for testing
        sequential_monte_carlo = SiennaPRASInterface.SequentialMonteCarlo(samples=2, seed=1)

        # Test that we can run assess() with RampViolations alongside Shortfall
        @testset "assess with RampViolations (proportional)" begin
            shortfalls, ramp_violations = SiennaPRASInterface.assess(
                rts_sys,
                PSY.Area,
                sequential_monte_carlo,
                SiennaPRASInterface.Shortfall(),
                RampViolations(rts_sys),
            )

            # Test that we got the expected result types
            @test shortfalls isa SiennaPRASInterface.PRASCore.Results.ShortfallResult
            @test ramp_violations isa RampViolationsResult

            # Test basic properties of the RampViolationsResult
            @test length(ramp_violations.timestamps) > 0
            @test ramp_violations.ramp_violation isa SiennaPRASInterface.Sparse3DAccumulator
            @test ramp_violations.total_ramp_violation isa
                  SiennaPRASInterface.Sparse2DAccumulator

            # Test that violation data is non-negative (violation magnitude should be >= 0)
            @test all(ramp_violations.ramp_violation.value .> 0.0)
            @test all(ramp_violations.ramp_violation.sampleid .>= 1)
            @test all(ramp_violations.ramp_violation.sampleid .<= 2)

            # Print diagnostics
            print_ramp_violation_diagnostics(
                ramp_violations,
                rts_sys,
                "Ramp Violation Summary (Original RTS-GMLC - Proportional)",
            )

            # With normal RTS ramp limits, violations should exist but structure should be valid
            @test length(ramp_violations.ramp_violation.value) == 0 ||
                  minimum(ramp_violations.ramp_violation.value) > 0.0
        end

        @testset "assess with RampViolations (merit order)" begin
            # Create wrapper function that captures sys in closure
            merit_order_wrapper =
                (region_dispatch, gen_idxs, system, state, t) ->
                    SiennaPRASInterface.merit_order_disaggregation(
                        region_dispatch,
                        gen_idxs,
                        system,
                        state,
                        t,
                        rts_sys,
                    )

            shortfalls, ramp_violations_merit = SiennaPRASInterface.assess(
                rts_sys,
                PSY.Area,
                sequential_monte_carlo,
                SiennaPRASInterface.Shortfall(),
                RampViolations(rts_sys, disaggregation_func=merit_order_wrapper),
            )

            # Test that we got the expected result types
            @test shortfalls isa SiennaPRASInterface.PRASCore.Results.ShortfallResult
            @test ramp_violations_merit isa RampViolationsResult
            @test ramp_violations_merit.ramp_violation isa
                  SiennaPRASInterface.Sparse3DAccumulator
            @test ramp_violations_merit.total_ramp_violation isa
                  SiennaPRASInterface.Sparse2DAccumulator

            # Test that violation data is non-negative (violation magnitude should be >= 0)
            @test all(ramp_violations_merit.ramp_violation.value .> 0.0)
            @test all(ramp_violations_merit.ramp_violation.sampleid .>= 1)
            @test all(ramp_violations_merit.ramp_violation.sampleid .<= 2)

            # Print diagnostics
            print_ramp_violation_diagnostics(
                ramp_violations_merit,
                rts_sys,
                "Ramp Violation Summary (Original RTS-GMLC - Merit Order)",
            )

            @test length(ramp_violations_merit.ramp_violation.value) == 0 ||
                  minimum(ramp_violations_merit.ramp_violation.value) > 0.0
        end

        @testset "assess with RampViolations (ramp-aware)" begin
            # Create wrapper function that captures sys in closure
            ramp_aware_wrapper =
                (region_dispatch, gen_idxs, system, state, t) ->
                    SiennaPRASInterface.ramp_aware_disaggregation(
                        region_dispatch,
                        gen_idxs,
                        system,
                        state,
                        t,
                        rts_sys,
                    )

            shortfalls, ramp_violations_ramp = SiennaPRASInterface.assess(
                rts_sys,
                PSY.Area,
                sequential_monte_carlo,
                SiennaPRASInterface.Shortfall(),
                RampViolations(rts_sys, disaggregation_func=ramp_aware_wrapper),
            )

            # Test that we got the expected result types
            @test shortfalls isa SiennaPRASInterface.PRASCore.Results.ShortfallResult
            @test ramp_violations_ramp isa RampViolationsResult
            @test ramp_violations_ramp.ramp_violation isa
                  SiennaPRASInterface.Sparse3DAccumulator
            @test ramp_violations_ramp.total_ramp_violation isa
                  SiennaPRASInterface.Sparse2DAccumulator

            # Test that violation data is non-negative (violation magnitude should be >= 0)
            @test all(ramp_violations_ramp.ramp_violation.value .> 0.0)
            @test all(ramp_violations_ramp.ramp_violation.sampleid .>= 1)
            @test all(ramp_violations_ramp.ramp_violation.sampleid .<= 2)

            # Print diagnostics
            print_ramp_violation_diagnostics(
                ramp_violations_ramp,
                rts_sys,
                "Ramp Violation Summary (Original RTS-GMLC - Ramp-Aware)",
            )

            @test length(ramp_violations_ramp.ramp_violation.value) == 0 ||
                  minimum(ramp_violations_ramp.ramp_violation.value) > 0.0
        end
    end

    @testset "RampViolations with assess() using modified RTS-GMLC" begin
        # Use our modified RTS-GMLC test system designed for ramp violations
        rts_sys = create_ramp_violation_test_system()

        # Create a sequential Monte Carlo method with a very very small number of samples for testing
        sequential_monte_carlo = SiennaPRASInterface.SequentialMonteCarlo(samples=2, seed=1)

        # Test that we can run assess() with RampViolations alongside Shortfall
        @testset "assess with RampViolations (proportional)" begin
            shortfalls, ramp_violations = SiennaPRASInterface.assess(
                rts_sys,
                PSY.Area,
                sequential_monte_carlo,
                SiennaPRASInterface.Shortfall(),
                RampViolations(rts_sys),
            )

            # Test that we got the expected result types
            @test shortfalls isa SiennaPRASInterface.PRASCore.Results.ShortfallResult
            @test ramp_violations isa RampViolationsResult
            @test ramp_violations.ramp_violation isa SiennaPRASInterface.Sparse3DAccumulator
            @test ramp_violations.total_ramp_violation isa
                  SiennaPRASInterface.Sparse2DAccumulator

            # Test that violation data is non-negative (violation magnitude should be >= 0)
            @test all(ramp_violations.ramp_violation.value .> 0.0)
            @test all(ramp_violations.ramp_violation.sampleid .>= 1)
            @test all(ramp_violations.ramp_violation.sampleid .<= 2)

            # Print diagnostics
            print_ramp_violation_diagnostics(
                ramp_violations,
                rts_sys,
                "Ramp Violation Summary (Modified RTS-GMLC with Tight Limits - Proportional)",
            )

            # We expect to see violations with our tight limits
            @test maximum(ramp_violations.ramp_violation.value) > 0.0
            @test length(ramp_violations.ramp_violation.value) > 0
        end

        @testset "assess with RampViolations (merit order)" begin
            # Create wrapper function that captures sys in closure
            merit_order_wrapper =
                (region_dispatch, gen_idxs, system, state, t) ->
                    SiennaPRASInterface.merit_order_disaggregation(
                        region_dispatch,
                        gen_idxs,
                        system,
                        state,
                        t,
                        rts_sys,
                    )

            shortfalls, ramp_violations_merit = SiennaPRASInterface.assess(
                rts_sys,
                PSY.Area,
                sequential_monte_carlo,
                SiennaPRASInterface.Shortfall(),
                RampViolations(rts_sys, disaggregation_func=merit_order_wrapper),
            )

            # Test that we got the expected result types
            @test shortfalls isa SiennaPRASInterface.PRASCore.Results.ShortfallResult
            @test ramp_violations_merit isa RampViolationsResult
            @test ramp_violations_merit.ramp_violation isa
                  SiennaPRASInterface.Sparse3DAccumulator
            @test ramp_violations_merit.total_ramp_violation isa
                  SiennaPRASInterface.Sparse2DAccumulator

            # Test that violation data is non-negative (violation magnitude should be >= 0)
            @test all(ramp_violations_merit.ramp_violation.value .> 0.0)
            @test all(ramp_violations_merit.ramp_violation.sampleid .>= 1)
            @test all(ramp_violations_merit.ramp_violation.sampleid .<= 2)

            # Print diagnostics
            print_ramp_violation_diagnostics(
                ramp_violations_merit,
                rts_sys,
                "Ramp Violation Summary (Modified RTS-GMLC with Tight Limits - Merit Order)",
            )

            # We expect to see violations with our tight limits
            @test maximum(ramp_violations_merit.ramp_violation.value) > 0.0
            @test length(ramp_violations_merit.ramp_violation.value) > 0
        end

        @testset "assess with RampViolations (ramp-aware)" begin
            # Create wrapper function that captures sys in closure
            ramp_aware_wrapper =
                (region_dispatch, gen_idxs, system, state, t) ->
                    SiennaPRASInterface.ramp_aware_disaggregation(
                        region_dispatch,
                        gen_idxs,
                        system,
                        state,
                        t,
                        rts_sys,
                    )

            shortfalls, ramp_violations_ramp = SiennaPRASInterface.assess(
                rts_sys,
                PSY.Area,
                sequential_monte_carlo,
                SiennaPRASInterface.Shortfall(),
                RampViolations(rts_sys, disaggregation_func=ramp_aware_wrapper),
            )

            # Test that we got the expected result types
            @test shortfalls isa SiennaPRASInterface.PRASCore.Results.ShortfallResult
            @test ramp_violations_ramp isa RampViolationsResult
            @test ramp_violations_ramp.ramp_violation isa
                  SiennaPRASInterface.Sparse3DAccumulator
            @test ramp_violations_ramp.total_ramp_violation isa
                  SiennaPRASInterface.Sparse2DAccumulator

            # Test that violation data is non-negative (violation magnitude should be >= 0)
            @test all(ramp_violations_ramp.ramp_violation.value .> 0.0)
            @test all(ramp_violations_ramp.ramp_violation.sampleid .>= 1)
            @test all(ramp_violations_ramp.ramp_violation.sampleid .<= 2)

            # Print diagnostics
            print_ramp_violation_diagnostics(
                ramp_violations_ramp,
                rts_sys,
                "Ramp Violation Summary (Modified RTS-GMLC with Tight Limits - Ramp-Aware)",
            )

            # We expect to see violations with our tight limits
            @test maximum(ramp_violations_ramp.ramp_violation.value) > 0.0
            @test length(ramp_violations_ramp.ramp_violation.value) > 0
        end
    end
end
