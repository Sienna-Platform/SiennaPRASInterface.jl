#!/usr/bin/env julia

"""
RTS-GMLC Resource Adequacy Simulation Script

This script runs a comprehensive resource adequacy assessment on the RTS-GMLC system
using Monte Carlo simulation with multi-threading. It tracks:
- Shortfall events and probabilities
- Expected Unserved Energy (EUE)
- Ramp constraint violations

Results are visualized using Plots.jl and saved to the current directory.

Usage:
    julia --project=scripts scripts/run_rts_simulation.jl
"""

using SiennaPRASInterface
using PowerSystems
using PowerSystemCaseBuilder
using Dates
using Statistics
using TimeSeries
using Plots
using CSV
using DataFrames

# Import PRAS types
import PRASCore: SequentialMonteCarlo, Shortfall, ShortfallSamples, EUE, assess, LOLE, val

# Set up convenient aliases
const PSY = PowerSystems
const PSCB = PowerSystemCaseBuilder

# Include helper function to load RTS-GMLC system
include("rts_gmlc.jl")

#######################
# Simulation Parameters
#######################

const NUM_SAMPLES = 1000
const RANDOM_SEED = 1234
const OUTPUT_DIR = "."

println("="^80)
println("RTS-GMLC Resource Adequacy Simulation")
println("="^80)
println("Samples: $NUM_SAMPLES")
println("Random seed: $RANDOM_SEED")
println()

#######################
# Load RTS-GMLC System
#######################

println("Loading RTS-GMLC Day-Ahead system...")
sys = get_rts_gmlc_outage("DA")
println("System loaded successfully!")
println()

#######################
# Set Up Simulation
#######################

println("Setting up Monte Carlo simulation...")

# Create Monte Carlo method with threading
method = SequentialMonteCarlo(; samples=NUM_SAMPLES, seed=RANDOM_SEED)

# Create result specifications with merit order disaggregation
ramp_spec = RampViolations(sys)

println("Simulation configured:")
println("  Method: Sequential Monte Carlo")
println("  Aggregation: By Area")
println()

#######################
# Run Assessment
#######################

println("Running resource adequacy assessment...")
println()

start_time = time()
shortfall, ramp_violations = assess(sys, PSY.Area, method, ShortfallSamples(), ramp_spec)
elapsed_time = time() - start_time

println("Assessment completed in $(round(elapsed_time, digits=2)) seconds")
println()

#######################
# Process Results
#######################

println("="^80)
println("RESULTS SUMMARY")
println("="^80)
println()

# Shortfall metrics
lole = val(LOLE(shortfall))
eue_val = val(EUE(shortfall))

println("Loss of Load Expectation (LOLE): $(round(lole, digits=4)) events/period")
println("Expected Unserved Energy (EUE): $(round(eue_val, digits=2)) MWh")
println()

# Ramp violation metrics
violations = ramp_violations.ramp_violation.value
n_violations = length(violations)
println("Ramp Violations:")
println("  Total violations: $n_violations")

if n_violations > 0
    max_violation = maximum(abs.(violations))
    mean_violation = mean(abs.(violations))
    median_violation = median(abs.(violations))

    println("  Maximum violation: $(round(max_violation, digits=4)) MW/min")
    println("  Mean violation: $(round(mean_violation, digits=4)) MW/min")
    println("  Median violation: $(round(median_violation, digits=4)) MW/min")

    # Count violations per sample
    sample_ids = ramp_violations.ramp_violation.sampleid
    samples_with_violations = length(unique(sample_ids))
    println("  Samples with violations: $samples_with_violations / $NUM_SAMPLES")

    # Top 5 generators with most violations
    gen_indices = ramp_violations.ramp_violation.idx
    gen_names = ramp_violations.generators
    gen_counts = Dict{String, Int}()
    for idx in gen_indices
        gen_name = gen_names[idx]
        gen_counts[gen_name] = get(gen_counts, gen_name, 0) + 1
    end

    println()
    println("  Top 5 generators with violations:")
    sorted_gens = sort(collect(gen_counts), by=x -> x[2], rev=true)
    for (i, (gen, count)) in enumerate(sorted_gens[1:min(5, length(sorted_gens))])
        println("    $i. $gen: $count violations")
    end
else
    println("  No ramp violations detected!")
end
println()

#######################
# Generate Plots
#######################

println("="^80)
println("GENERATING PLOTS")
println("="^80)
println()

# Set plot defaults for publication quality
default(; size=(800, 600), dpi=300, legendfontsize=10, guidefontsize=12, tickfontsize=10)

if n_violations > 0
    # Plot 1: Histogram of violation magnitudes
    println("Creating histogram of ramp violation magnitudes...")
    abs_violations = abs.(violations)

    p1 = histogram(
        abs_violations,
        bins=50,
        xlabel="Violation Magnitude (MW/min)",
        ylabel="Frequency",
        title="Distribution of Ramp Violations\n(RTS-GMLC, $NUM_SAMPLES samples)",
        legend=false,
        color=:steelblue,
        alpha=0.7,
    )

    histogram_file = joinpath(OUTPUT_DIR, "ramp_violations_histogram.png")
    savefig(p1, histogram_file)
    println("  Saved: $histogram_file")

    # Plot 2: Violations over time
    println("Creating time series plot of violations...")
    timesteps = ramp_violations.ramp_violation.time

    # Count violations per timestep
    timestep_counts = Dict{Int, Int}()
    for t in timesteps
        timestep_counts[t] = get(timestep_counts, t, 0) + 1
    end

    sorted_timesteps = sort(collect(keys(timestep_counts)))
    counts = [timestep_counts[t] for t in sorted_timesteps]

    p2 = scatter(
        sorted_timesteps,
        counts,
        xlabel="Time Step",
        ylabel="Number of Violations",
        title="Ramp Violations Over Time\n(RTS-GMLC, $NUM_SAMPLES samples)",
        legend=false,
        color=:coral,
        alpha=0.6,
        markersize=4,
    )

    timeseries_file = joinpath(OUTPUT_DIR, "ramp_violations_timeseries.png")
    savefig(p2, timeseries_file)
    println("  Saved: $timeseries_file")

    # Plot 3: Top 10 generators by violation count
    println("Creating bar plot of top generators...")
    sorted_gens = sort(collect(gen_counts), by=x -> x[2], rev=true)
    top_10 = sorted_gens[1:min(10, length(sorted_gens))]

    gen_labels = [x[1] for x in top_10]
    gen_violation_counts = [x[2] for x in top_10]

    p3 = bar(
        gen_labels,
        gen_violation_counts,
        xlabel="Generator",
        ylabel="Violation Count",
        title="Top 10 Generators by Ramp Violations\n(RTS-GMLC, $NUM_SAMPLES samples)",
        legend=false,
        color=:indianred,
        alpha=0.7,
        xrotation=45,
    )

    generators_file = joinpath(OUTPUT_DIR, "ramp_violations_generators.png")
    savefig(p3, generators_file)
    println("  Saved: $generators_file")
else
    println("No violations to plot!")
end

# Plot 4: Per-sample Lost Load vs Ramp Violations
println("Creating per-sample correlation plot...")

# Get per-sample unserved energy (MWh) - shortfall[] returns vector of EUE per sample
sample_eue = shortfall[]

# Compute per-sample ramp violation counts
sample_ramp_count = zeros(Int, NUM_SAMPLES)
if n_violations > 0
    for i in 1:n_violations
        sample_id = ramp_violations.ramp_violation.sampleid[i]
        sample_ramp_count[sample_id] += 1
    end
end

p4 = scatter(
    sample_ramp_count,
    sample_eue,
    xlabel="Ramp Violations per Sample (count)",
    ylabel="Unserved Energy per Sample (MWh)",
    title="Lost Load vs Ramp Violations\n(RTS-GMLC, $NUM_SAMPLES samples)",
    legend=false,
    color=:purple,
    alpha=0.5,
    markersize=4,
)

correlation_file = joinpath(OUTPUT_DIR, "lostload_vs_ramp_violations.png")
savefig(p4, correlation_file)
println("  Saved: $correlation_file")

# Plot 5: Distribution of violations per sample
println("Creating histogram of violations per sample...")

# Filter out samples with zero violations for summary stats on samples with violations
samples_with_viols = sample_ramp_count[sample_ramp_count .> 0]

p5 = histogram(
    sample_ramp_count,
    bins=50,
    xlabel="Number of Ramp Violations per Sample",
    ylabel="Number of Samples",
    title="Distribution of Ramp Violations per Sample\n(RTS-GMLC, $NUM_SAMPLES samples)",
    legend=false,
    color=:teal,
    alpha=0.7,
)

# Add vertical line for median (of all samples)
median_violations = median(sample_ramp_count)
vline!(
    p5,
    [median_violations],
    linewidth=2,
    linestyle=:dash,
    color=:red,
    label="Median = $(round(median_violations, digits=1))",
)

# Add annotation with summary stats
if length(samples_with_viols) > 0
    mean_viols = mean(sample_ramp_count)
    median_all = median(sample_ramp_count)
    max_viols = maximum(sample_ramp_count)
    pct_with_viols = 100 * length(samples_with_viols) / NUM_SAMPLES

    annotate!(
        p5,
        maximum(sample_ramp_count) * 0.6,
        maximum(ylims(p5)) * 0.85,
        text(
            "Mean: $(round(mean_viols, digits=1))\nMedian: $(round(median_all, digits=1))\nMax: $max_viols\n$(round(pct_with_viols, digits=1))% with violations",
            10,
            :left,
        ),
    )
end

sample_dist_file = joinpath(OUTPUT_DIR, "ramp_violations_per_sample.png")
savefig(p5, sample_dist_file)
println("  Saved: $sample_dist_file")

println()
println("="^80)
println("SIMULATION COMPLETE")
println("="^80)
println("Results and plots saved to: $OUTPUT_DIR")
println()
