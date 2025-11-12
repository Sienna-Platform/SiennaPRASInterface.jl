#!/usr/bin/env julia

"""
Ramp Violations Comparison Plotting Script

Load multiple saved ramp violation results and create overlay comparison plots.

Usage:
    julia --project=scripts scripts/plot_ramp_comparisons.jl <result_file1> <result_file2> ... <output_dir>

Arguments:
    result_files... - Paths to results.jld2 files containing ramp_violations data
    output_dir      - Output directory for comparison plots

Example:
    julia --project=scripts scripts/plot_ramp_comparisons.jl \\
        results/ramp_violations/modified_proportional/results.jld2 \\
        results/ramp_violations/modified_merit_order/results.jld2 \\
        results/ramp_violations/modified_ramp_aware/results.jld2 \\
        results/ramp_comparisons/

This will create overlay plots comparing the three disaggregation methods.
"""

using Plots
using Statistics
include("plots.jl")

#######################
# Parse CLI Arguments
#######################

function parse_arguments()
    if length(ARGS) < 3
        error("Usage: julia plot_ramp_comparisons.jl <result_file1> <result_file2> ... <output_dir>\n" *
              "At least 2 result files and an output directory are required.")
    end

    # Last argument is output directory
    output_dir = ARGS[end]

    # All other arguments are result files
    result_files = ARGS[1:end-1]

    # Verify all files exist
    for file in result_files
        if !isfile(file)
            error("Result file not found: $file")
        end
    end

    return result_files, output_dir
end

# Format label for display (e.g., "modified_ramp_aware" -> "Modified Ramp Aware")
function format_label(label::String)
    words = split(label, "_")
    return join([uppercasefirst(w) for w in words], " ")
end

result_files, output_dir = parse_arguments()

#######################
# Load Results
#######################

println("="^80)
println("Loading ramp violation results for comparison...")
println("="^80)
println()

results_list = []
labels = []

for (i, result_file) in enumerate(result_files)
    println("Loading $result_file...")
    data = load_simulation_results(result_file)

    # Verify this file contains ramp_violations
    if !haskey(data, "ramp_violations")
        error("Result file does not contain 'ramp_violations': $result_file\n" *
              "Expected keys: ramp_violations, shortfall\n" *
              "Found keys: $(keys(data))")
    end

    push!(results_list, data)

    # Extract label from directory structure
    # e.g., "results/ramp_violations/modified_proportional/results.jld2" → "Modified Proportional"
    dir_parts = splitpath(dirname(result_file))
    raw_label = length(dir_parts) >= 1 ? dir_parts[end] : "result_$i"
    label = format_label(raw_label)
    push!(labels, label)

    println("  Loaded: $label")
end

println()
println("Loaded $(length(results_list)) result sets")
println()

# Create output directory
mkpath(output_dir)

#######################
# Generate Comparison Plots
#######################

println("="^80)
println("GENERATING COMPARISON PLOTS")
println("="^80)
println()

# Set plot defaults
default(; size=(800, 600), dpi=300, legendfontsize=10, guidefontsize=12, tickfontsize=10)

# Extract data from all results
all_violations = []
all_per_sample = []
all_shortfalls = []

for (result, label) in zip(results_list, labels)
    ramp_result = result["ramp_violations"]
    shortfall_result = result["shortfall"]

    violations = ramp_result.ramp_violation.value

    # Per-sample violation counts
    NUM_SAMPLES = length(unique(ramp_result.ramp_violation.sampleid))
    sample_counts = zeros(Int, NUM_SAMPLES)
    for sampleid in ramp_result.ramp_violation.sampleid
        sample_counts[sampleid] += 1
    end

    # Per-sample unserved energy
    sample_eue = shortfall_result[]

    push!(all_violations, abs.(violations))
    push!(all_per_sample, sample_counts)
    push!(all_shortfalls, sample_eue)
end

# Plot 1: Overlay histogram of violation magnitudes
println("Creating violation magnitude comparison...")
p1 = plot(;
    xlabel="Violation Magnitude (MW/min)",
    ylabel="Count",
    title="Ramp Violation Magnitude Distribution Comparison",
    legend=:topright
)

colors = [:purple, :orange, :green, :red, :blue, :brown]
for (i, (viols, label)) in enumerate(zip(all_violations, labels))
    if length(viols) > 0
        stephist!(p1, viols, bins=50, label=label, color=colors[mod1(i, length(colors))], linewidth=2)
    end
end

savefig(p1, joinpath(output_dir, "ramp_violations_magnitude_comparison.png"))
println("  Saved: ramp_violations_magnitude_comparison.png")

# Plot 2: Overlay histogram of violations per sample
println("Creating violations per sample comparison...")
p2 = plot(;
    xlabel="Violations per Sample",
    ylabel="Count",
    title="Violations per Sample Distribution Comparison",
    legend=:topright
)

for (i, (counts, label)) in enumerate(zip(all_per_sample, labels))
    stephist!(p2, counts, bins=50, label=label, color=colors[mod1(i, length(colors))], linewidth=2)
end

savefig(p2, joinpath(output_dir, "ramp_violations_per_sample_comparison.png"))
println("  Saved: ramp_violations_per_sample_comparison.png")

# Plot 3: Overlay scatter - violation magnitude vs EUE for each method
println("Creating violation magnitude vs EUE comparison...")

# Calculate per-sample violation magnitude (sum of absolute violations)
all_per_sample_magnitude = []
for (result, label) in zip(results_list, labels)
    ramp_result = result["ramp_violations"]
    NUM_SAMPLES = length(unique(ramp_result.ramp_violation.sampleid))
    sample_magnitudes = zeros(Float64, NUM_SAMPLES)
    for (sampleid, mag) in zip(ramp_result.ramp_violation.sampleid, ramp_result.ramp_violation.value)
        sample_magnitudes[sampleid] += abs(mag)
    end
    push!(all_per_sample_magnitude, sample_magnitudes)
end

p3 = scatter(;
    xlabel="Total Violation Magnitude per Sample (MW/min)",
    ylabel="Unserved Energy per Sample (MWh)",
    title="Violation Magnitude vs EUE Comparison",
    legend=:topright,
    alpha=0.5,
    markersize=3
)

for (i, (mags, eue, label)) in enumerate(zip(all_per_sample_magnitude, all_shortfalls, labels))
    scatter!(p3, mags, eue, label=label, color=colors[mod1(i, length(colors))], alpha=0.5, markersize=3)
end

savefig(p3, joinpath(output_dir, "ramp_violations_vs_eue_comparison.png"))
println("  Saved: ramp_violations_vs_eue_comparison.png")

# Summary statistics table
println()
println("="^80)
println("SUMMARY STATISTICS COMPARISON")
println("="^80)
println()
println(rpad("Method", 30), rpad("Total Viols", 15), rpad("Mean Mag", 15), rpad("Median Mag", 15), "Samples Affected")
println("-" ^90)

for (result, label) in zip(results_list, labels)
    ramp_result = result["ramp_violations"]
    violations = abs.(ramp_result.ramp_violation.value)
    samples_affected = length(unique(ramp_result.ramp_violation.sampleid))

    total = length(violations)
    mean_val = length(violations) > 0 ? mean(violations) : 0.0
    median_val = length(violations) > 0 ? median(violations) : 0.0

    println(rpad(label, 30),
            rpad(string(total), 15),
            rpad(string(round(mean_val, digits=2)), 15),
            rpad(string(round(median_val, digits=2)), 15),
            samples_affected)
end
println("-" ^90)
println()

# Correlation statistics
println("Correlation (Violation Magnitude vs EUE):")
println("-" ^50)
for (mags, eue, label) in zip(all_per_sample_magnitude, all_shortfalls, labels)
    nonzero_mask = (mags .> 0) .| (eue .> 0)
    if sum(nonzero_mask) > 1
        corr = cor(mags[nonzero_mask], eue[nonzero_mask])
        println(rpad(label, 30), "r = $(round(corr, digits=3))")
    else
        println(rpad(label, 30), "insufficient data")
    end
end
println("-" ^50)
println()

println("="^80)
println("COMPARISON COMPLETE")
println("="^80)
println("Comparison plots saved to: $output_dir")
println()