#!/usr/bin/env julia

"""
Line Overload Comparison Plotting Script

Load multiple saved line overload results and create overlay comparison plots.

Usage:
    julia --project=scripts scripts/plot_line_comparisons.jl <result_file1> <result_file2> ... <output_dir>

Arguments:
    result_files... - Paths to results.jld2 files containing line_overload data
    output_dir      - Output directory for comparison plots

Example:
    julia --project=scripts scripts/plot_line_comparisons.jl \\
        results/line_overloading/modified_proportional/results.jld2 \\
        results/line_overloading/modified_merit_order/results.jld2 \\
        results/line_overloading/modified_ramp_aware/results.jld2 \\
        results/line_comparisons/

This will create overlay plots comparing the three disaggregation methods.
"""

using Plots
using Statistics
using SiennaPRASInterface
using StatsPlots
include("plots.jl")

#######################
# Parse CLI Arguments
#######################

function parse_arguments()
    if length(ARGS) < 3
        error(
            "Usage: julia plot_line_comparisons.jl <result_file1> <result_file2> ... <output_dir>\n" *
            "At least 2 result files and an output directory are required.",
        )
    end

    # Last argument is output directory
    output_dir = ARGS[end]

    # All other arguments are result files
    result_files = ARGS[1:(end - 1)]

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
println("Loading line overload results for comparison...")
println("="^80)
println()

results_list = []
labels = []

for (i, result_file) in enumerate(result_files)
    println("Loading $result_file...")
    data = load_simulation_results(result_file)

    # Verify this file contains line_overload
    if !haskey(data, "line_overload")
        error(
            "Result file does not contain 'line_overload': $result_file\n" *
            "Expected keys: line_overload, shortfall\n" *
            "Found keys: $(keys(data))",
        )
    end

    push!(results_list, data)

    # Extract label from directory structure
    # e.g., "results/line_overloading/modified_proportional/results.jld2" → "Modified Proportional"
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
all_overloads = []
all_per_sample = []
all_shortfalls = []
all_convergence_rates = []

for (result, label) in zip(results_list, labels)
    overload_result = result["line_overload"]
    shortfall_result = result["shortfall"]

    overloads = overload_result.overload_mw

    # Per-sample overload counts
    NUM_SAMPLES = length(unique(overload_result.sample_id))
    sample_counts = zeros(Int, NUM_SAMPLES)
    for sampleid in overload_result.sample_id
        sample_counts[sampleid] += 1
    end

    # Per-sample unserved energy
    sample_eue = shortfall_result[]

    push!(all_overloads, overloads)
    push!(all_per_sample, sample_counts)
    push!(all_shortfalls, sample_eue)
    push!(all_convergence_rates, overload_result.convergence_rate)
end

# Plot 1: Overlay histogram of overload magnitudes
println("Creating overload magnitude comparison...")
p1 = plot(;
    xlabel="Overload Magnitude (MW over rating)",
    ylabel="Count",
    title="Line Overload Magnitude Distribution Comparison",
    legend=:topright,
)

colors = [:purple, :orange, :green, :red, :blue, :brown]
for (i, (overloads, label)) in enumerate(zip(all_overloads, labels))
    if length(overloads) > 0
        stephist!(
            p1,
            overloads,
            bins=50,
            label=label,
            color=colors[mod1(i, length(colors))],
            linewidth=2,
        )
    end
end

savefig(p1, joinpath(output_dir, "line_overload_magnitude_comparison.png"))
println("  Saved: line_overload_magnitude_comparison.png")

# Plot 2: Overlay histogram of overloads per sample
println("Creating overloads per sample comparison...")

# Calculate per-sample overload magnitude (sum of MW over rating)
all_per_sample_magnitude = []
for (result, label) in zip(results_list, labels)
    overload_result = result["line_overload"]
    NUM_SAMPLES = length(unique(overload_result.sample_id))
    sample_magnitudes = zeros(Float64, NUM_SAMPLES)
    for (sampleid, mag) in zip(overload_result.sample_id, overload_result.overload_mw)
        sample_magnitudes[sampleid] += mag
    end
    push!(all_per_sample_magnitude, sample_magnitudes)
end

p2 = plot(;
    xlabel="Total Overloads (MW) per Sample",
    ylabel="Count",
    title="Overloads per Sample Distribution Comparison",
    legend=:topright,
)

for (i, (counts, label)) in enumerate(zip(all_per_sample_magnitude, labels))
    stephist!(
        p2,
        counts,
        bins=50,
        label=label,
        color=colors[mod1(i, length(colors))],
        linewidth=2,
    )
end

savefig(p2, joinpath(output_dir, "line_overload_per_sample_comparison.png"))
println("  Saved: line_overload_per_sample_comparison.png")

# Plot 3: Overlay scatter - overload magnitude vs EUE for each method
println("Creating overload magnitude vs EUE comparison...")

p3 = scatter(;
    xlabel="Total Overload Magnitude per Sample (MW)",
    ylabel="Unserved Energy per Sample (MWh)",
    title="Overload Magnitude vs EUE Comparison",
    legend=:topright,
    alpha=0.5,
    markersize=3,
)

for (i, (mags, eue, label)) in
    enumerate(zip(all_per_sample_magnitude, all_shortfalls, labels))
    scatter!(
        p3,
        mags,
        eue,
        label=label,
        color=colors[mod1(i, length(colors))],
        alpha=0.5,
        markersize=3,
    )
end

savefig(p3, joinpath(output_dir, "line_overload_vs_eue_comparison.png"))
println("  Saved: line_overload_vs_eue_comparison.png")

# Plot 4: Compare most overloaded lines across methods
println("Creating top overloaded lines comparison...")

# Get top 5 most overloaded lines for each method
all_top_lines = []
for (result, label) in zip(results_list, labels)
    overload_result = result["line_overload"]
    top_lines = SiennaPRASInterface.get_most_overloaded_lines(overload_result, 5)
    push!(all_top_lines, top_lines)
end

# Find common lines across all methods
all_line_names = Set{String}()
for top_lines in all_top_lines
    for (name, _, _) in top_lines
        push!(all_line_names, name)
    end
end

# For each common line, plot its overload count across methods
if length(all_line_names) > 0
    # Get total overload count for each line across all methods
    line_total_counts = Dict{String, Int}()
    for name in all_line_names
        total_count = 0
        for (j, label) in enumerate(labels)
            overload_result = results_list[j]["line_overload"]
            for (k, branch_name) in enumerate(overload_result.branch_names)
                if branch_name == name
                    total_count += sum(overload_result.line_idx .== k)
                end
            end
        end
        line_total_counts[name] = total_count
    end

    # Sort by total count and select top lines
    sorted_lines = sort(collect(line_total_counts), by=x -> x[2], rev=true)
    top_common_lines = [x[1] for x in sorted_lines[1:min(10, length(sorted_lines))]]

    # Create grouped bar chart - counts for each method
    counts_matrix = zeros(Int, length(top_common_lines), length(labels))
    for (j, label) in enumerate(labels)
        overload_result = results_list[j]["line_overload"]
        for (i, line_name) in enumerate(top_common_lines)
            # Count overloads for this line
            count = 0
            for (k, name) in enumerate(overload_result.branch_names)
                if name == line_name
                    count += sum(overload_result.line_idx .== k)
                end
            end
            counts_matrix[i, j] = count
        end
    end

    # Shorten line names for display
    short_names = []
    for name in top_common_lines
        parts = split(name, "-")
        if length(parts) >= 2
            short_name = join(parts[(end - 1):end], "-")
        else
            short_name = name
        end
        push!(short_names, short_name)
    end

    p4 = groupedbar(
        counts_matrix,
        bar_position=:dodge,
        xlabel="Line",
        ylabel="Overload Count",
        title="Top Overloaded Lines Comparison",
        xticks=(1:length(top_common_lines), short_names),
        xrotation=45,
        label=permutedims(labels),
        legend=:topright,
        size=(1000, 600),
        bottom_margin=15Plots.mm,
        left_margin=10Plots.mm,
    )

    savefig(p4, joinpath(output_dir, "line_overload_top_lines_comparison.png"))
    println("  Saved: line_overload_top_lines_comparison.png")
end

# Summary statistics table
println()
println("="^80)
println("SUMMARY STATISTICS COMPARISON")
println("="^80)
println()
println(
    rpad("Method", 30),
    rpad("Total OLs", 12),
    rpad("Mean Mag", 12),
    rpad("Median Mag", 12),
    rpad("Conv Rate", 12),
    "Samples",
)
println("-"^90)

for (result, label, conv_rate) in zip(results_list, labels, all_convergence_rates)
    overload_result = result["line_overload"]
    overloads = overload_result.overload_mw
    samples_affected = length(unique(overload_result.sample_id))

    total = length(overloads)
    mean_val = length(overloads) > 0 ? mean(overloads) : 0.0
    median_val = length(overloads) > 0 ? median(overloads) : 0.0

    println(
        rpad(label, 30),
        rpad(string(total), 12),
        rpad(string(round(mean_val, digits=2)), 12),
        rpad(string(round(median_val, digits=2)), 12),
        rpad(string(round(100 * conv_rate, digits=1)) * "%", 12),
        samples_affected,
    )
end
println("-"^90)
println()

# Correlation statistics
println("Correlation (Overload Magnitude vs EUE):")
println("-"^50)
for (mags, eue, label) in zip(all_per_sample_magnitude, all_shortfalls, labels)
    nonzero_mask = (mags .> 0) .| (eue .> 0)
    if sum(nonzero_mask) > 1
        corr = cor(mags[nonzero_mask], eue[nonzero_mask])
        println(rpad(label, 30), "r = $(round(corr, digits=3))")
    else
        println(rpad(label, 30), "insufficient data")
    end
end
println("-"^50)
println()

println("="^80)
println("COMPARISON COMPLETE")
println("="^80)
println("Comparison plots saved to: $output_dir")
println()
