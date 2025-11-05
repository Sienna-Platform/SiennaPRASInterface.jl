#!/usr/bin/env julia

"""
RTS-GMLC Line Overloading Analysis Script

This script runs power flow analysis during Monte Carlo resource adequacy assessment
on the RTS-GMLC system to identify and visualize transmission line overloading patterns.

Features:
- DC power flow with line rating violation tracking
- Comprehensive heatmap visualizations showing spatial-temporal patterns
- Distribution analysis of overload severity and frequency
- Correlation analysis with unserved energy metrics
- Temporal pattern identification

Results are visualized using Plots.jl and saved to the scripts/ directory.

Usage:
    julia --project=. scripts/run_line_overloading.jl
"""

using SiennaPRASInterface
using PowerSystems
using PowerSystemCaseBuilder
using PowerFlows
using Dates
using Statistics
using Plots
using CSV
using DataFrames

# Import PRAS types
import PRASCore: SequentialMonteCarlo, Shortfall, ShortfallSamples, EUE, assess, LOLE, val

# Set up convenient aliases
const PSY = PowerSystems
const PSCB = PowerSystemCaseBuilder
const PFS = PowerFlows

# Include helper function to load RTS-GMLC system
include("rts_gmlc.jl")

#######################
# Simulation Parameters
#######################

const NUM_SAMPLES = 1000
const RANDOM_SEED = 1234
const OUTPUT_DIR = "."

println("="^80)
println("RTS-GMLC Line Overloading Analysis")
println("="^80)
println("Samples: $NUM_SAMPLES")
println("Random seed: $RANDOM_SEED")
println()

#######################
# Load RTS-GMLC System
#######################

println("Loading RTS-GMLC Day-Ahead system...")
sys = get_rts_gmlc_outage("DA")

# Optional: Scale load to stress the system
loads = PSY.get_components(PSY.StaticLoad, sys)
for load in loads
    current_base_power = PSY.get_base_power(load)
    new_base_power = current_base_power * 1.10  # 10% load increase
    PSY.set_base_power!(load, new_base_power)
end

println("System loaded successfully!")
println("  Number of areas: $(length(PSY.get_components(PSY.Area, sys)))")
println("  Number of branches: $(length(PSY.get_components(PSY.ACBranch, sys)))")
println("  Load scaling: 110%")
println()

#######################
# Set Up Simulation
#######################

println("Setting up Monte Carlo simulation with power flow...")

# Create Monte Carlo method
method = SequentialMonteCarlo(; samples=NUM_SAMPLES, seed=RANDOM_SEED)

# Create power flow result spec (DC power flow for speed)
line_overload_spec = PowerFlowWithOverloads(sys, PFS.DCPowerFlow())

println("Simulation configured:")
println("  Method: Sequential Monte Carlo")
println("  Power flow: DC Power Flow")
println("  Aggregation: By Area")
println()

#######################
# Run Assessment
#######################

println("Running resource adequacy assessment with power flow...")
println("This may take several minutes...")
println()

start_time = time()
shortfall, line_overload = assess(
    sys,
    PSY.Area,
    method,
    ShortfallSamples(),
    line_overload_spec
)
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

println("Reliability Metrics:")
println("  Loss of Load Expectation (LOLE): $(round(lole, digits=4)) events/period")
println("  Expected Unserved Energy (EUE): $(round(eue_val, digits=2)) MWh")
println()

# Line overload metrics
n_overloads = count_overload_events(line_overload)
convergence_rate = line_overload.convergence_rate

println("Power Flow Statistics:")
println("  Convergence rate: $(round(100 * convergence_rate, digits=2))%")
println()

println("Line Overload Metrics:")
println("  Total overload events: $n_overloads")

if n_overloads > 0
    max_overload = maximum(line_overload.overload_mw)
    mean_overload = mean(line_overload.overload_mw)
    median_overload = median(line_overload.overload_mw)

    println("  Maximum overload: $(round(max_overload, digits=2)) MW")
    println("  Mean overload: $(round(mean_overload, digits=2)) MW")
    println("  Median overload: $(round(median_overload, digits=2)) MW")

    # Count samples with overloads
    samples_with_overloads = length(unique(line_overload.sample_id))
    println("  Samples with overloads: $samples_with_overloads / $NUM_SAMPLES")

    # Overall overload probability
    prob_overload = overload_probability(line_overload)
    println("  Probability of any overload: $(round(100 * prob_overload, digits=2))%")

    # Top 5 lines by overload count
    top_lines = get_most_overloaded_lines(line_overload, 5)
    println()
    println("  Top 5 most overloaded lines:")
    for (i, (line_name, count, max_ov)) in enumerate(top_lines)
        println("    $i. $line_name: $count events (max: $(round(max_ov, digits=2)) MW)")
    end
else
    println("  No line overloads detected!")
end
println()

#######################
# Generate Plots
#######################

println("="^80)
println("GENERATING VISUALIZATIONS")
println("="^80)
println()

# Set plot defaults for publication quality
default(; size=(800, 600), dpi=300, legendfontsize=10, guidefontsize=12, tickfontsize=10)

if n_overloads > 0
    # Extract dimensions
    num_timesteps = length(line_overload.timestamps)
    num_lines = length(line_overload.branch_names)

    # PRIORITY: HEATMAP VISUALIZATIONS

    # Heatmap 1: Overload count (samples × timesteps)
    println("Creating heatmap: Overload count (samples × timesteps)...")

    # Build count matrix
    overload_count_matrix = zeros(Int, NUM_SAMPLES, num_timesteps)
    for i in 1:n_overloads
        s = line_overload.sample_id[i]
        t = line_overload.timestep[i]
        overload_count_matrix[s, t] += 1
    end

    # Plot with log scale
    heatmap_data_count = log10.(overload_count_matrix .+ 1)
    p1 = heatmap(
        1:num_timesteps,
        1:NUM_SAMPLES,
        heatmap_data_count,
        xlabel="Time Step",
        ylabel="Sample ID",
        title="Line Overload Count Heatmap\n(RTS-GMLC, $NUM_SAMPLES samples)",
        colorbar_title="log10(Count+1)",
        color=:viridis,
        aspect_ratio=:auto,
        size=(1000, 600),
        left_margin=10Plots.mm,
        right_margin=10Plots.mm,
        top_margin=10Plots.mm,
        bottom_margin=10Plots.mm,
    )

    count_heatmap_file = joinpath(OUTPUT_DIR, "line_overload_count_heatmap.png")
    savefig(p1, count_heatmap_file)
    println("  Saved: $count_heatmap_file")

    # Heatmap 2: Overload magnitude (samples × timesteps)
    println("Creating heatmap: Overload magnitude (samples × timesteps)...")

    # Build magnitude matrix
    overload_magnitude_matrix = zeros(Float64, NUM_SAMPLES, num_timesteps)
    for i in 1:n_overloads
        s = line_overload.sample_id[i]
        t = line_overload.timestep[i]
        overload_magnitude_matrix[s, t] += line_overload.overload_mw[i]
    end

    # Plot with log scale
    heatmap_data_mag = log10.(overload_magnitude_matrix .+ 0.01)
    p2 = heatmap(
        1:num_timesteps,
        1:NUM_SAMPLES,
        heatmap_data_mag,
        xlabel="Time Step",
        ylabel="Sample ID",
        title="Line Overload Magnitude Heatmap\n(RTS-GMLC, $NUM_SAMPLES samples)",
        colorbar_title="log10(MW+0.01)",
        color=:plasma,
        aspect_ratio=:auto,
        size=(1000, 600),
        left_margin=10Plots.mm,
        right_margin=10Plots.mm,
        top_margin=10Plots.mm,
        bottom_margin=10Plots.mm,
    )

    mag_heatmap_file = joinpath(OUTPUT_DIR, "line_overload_magnitude_heatmap.png")
    savefig(p2, mag_heatmap_file)
    println("  Saved: $mag_heatmap_file")

    # Heatmap 3: Line-specific overload count (lines × timesteps)
    println("Creating heatmap: Per-line overload count (lines × timesteps)...")

    # Build line × timestep matrix (aggregated across samples)
    line_timestep_matrix = zeros(Int, num_lines, num_timesteps)
    for i in 1:n_overloads
        line_idx = line_overload.line_idx[i]
        t = line_overload.timestep[i]
        line_timestep_matrix[line_idx, t] += 1
    end

    # Sort lines by total overload count for better visualization
    line_total_counts = sum(line_timestep_matrix, dims=2)[:, 1]
    sorted_indices = sortperm(line_total_counts, rev=true)

    # Show top 30 most overloaded lines
    top_n_lines = min(30, num_lines)
    top_line_indices = sorted_indices[1:top_n_lines]
    top_line_names = [line_overload.branch_names[i] for i in top_line_indices]

    # Extract and plot
    line_timestep_subset = line_timestep_matrix[top_line_indices, :]
    heatmap_data_line = log10.(line_timestep_subset .+ 1)

    p3 = heatmap(
        1:num_timesteps,
        1:top_n_lines,
        heatmap_data_line,
        xlabel="Time Step",
        ylabel="Line Index (sorted by count)",
        title="Per-Line Overload Count (Top $top_n_lines Lines)\n(RTS-GMLC, aggregated across samples)",
        colorbar_title="log10(Count+1)",
        color=:thermal,
        aspect_ratio=:auto,
        size=(1000, 600),
        left_margin=10Plots.mm,
        right_margin=10Plots.mm,
        top_margin=10Plots.mm,
        bottom_margin=10Plots.mm,
    )

    line_heatmap_file = joinpath(OUTPUT_DIR, "line_overload_by_line_heatmap.png")
    savefig(p3, line_heatmap_file)
    println("  Saved: $line_heatmap_file")

    # Heatmap 4: Per-sample overload count (lines × samples)
    println("Creating heatmap: Per-line per-sample overload count...")

    # Build line × sample matrix
    line_sample_matrix = zeros(Int, num_lines, NUM_SAMPLES)
    for i in 1:n_overloads
        line_idx = line_overload.line_idx[i]
        s = line_overload.sample_id[i]
        line_sample_matrix[line_idx, s] += 1
    end

    # Use same top lines as before
    line_sample_subset = line_sample_matrix[top_line_indices, :]
    heatmap_data_line_sample = log10.(line_sample_subset .+ 1)

    p4 = heatmap(
        1:NUM_SAMPLES,
        1:top_n_lines,
        heatmap_data_line_sample,
        xlabel="Sample ID",
        ylabel="Line Index (sorted by count)",
        title="Per-Line Per-Sample Overload Count (Top $top_n_lines Lines)\n(RTS-GMLC)",
        colorbar_title="log10(Count+1)",
        color=:inferno,
        aspect_ratio=:auto,
        size=(1000, 600),
        left_margin=10Plots.mm,
        right_margin=10Plots.mm,
        top_margin=10Plots.mm,
        bottom_margin=10Plots.mm,
    )

    line_sample_heatmap_file = joinpath(OUTPUT_DIR, "line_overload_by_line_sample_heatmap.png")
    savefig(p4, line_sample_heatmap_file)
    println("  Saved: $line_sample_heatmap_file")

    # DISTRIBUTION & RANKING PLOTS

    # Plot 5: Histogram of overload magnitudes
    println("Creating histogram: Overload magnitudes...")

    p5 = histogram(
        line_overload.overload_mw,
        bins=50,
        xlabel="Overload Magnitude (MW over rating)",
        ylabel="Frequency",
        title="Distribution of Line Overload Magnitudes\n(RTS-GMLC, $NUM_SAMPLES samples)",
        legend=false,
        color=:steelblue,
        alpha=0.7,
    )

    overload_hist_file = joinpath(OUTPUT_DIR, "line_overload_magnitude_histogram.png")
    savefig(p5, overload_hist_file)
    println("  Saved: $overload_hist_file")

    # Plot 6: Bar chart of top 15 most overloaded lines
    println("Creating bar chart: Top 15 most overloaded lines...")

    top_15_lines = get_most_overloaded_lines(line_overload, 15)
    line_labels = [x[1] for x in top_15_lines]
    line_counts = [x[2] for x in top_15_lines]

    p6 = bar(
        line_labels,
        line_counts,
        xlabel="Transmission Line",
        ylabel="Overload Event Count",
        title="Top 15 Lines by Overload Frequency\n(RTS-GMLC, $NUM_SAMPLES samples)",
        legend=false,
        color=:indianred,
        alpha=0.7,
        xrotation=45,
        size=(1000, 600),
        bottom_margin=15Plots.mm,
    )

    top_lines_file = joinpath(OUTPUT_DIR, "line_overload_top_lines.png")
    savefig(p6, top_lines_file)
    println("  Saved: $top_lines_file")

    # Plot 7: Histogram of overloads per sample
    println("Creating histogram: Overloads per sample...")

    # Compute per-sample overload counts
    sample_overload_count = zeros(Int, NUM_SAMPLES)
    for i in 1:n_overloads
        sample_id = line_overload.sample_id[i]
        sample_overload_count[sample_id] += 1
    end

    p7 = histogram(
        sample_overload_count,
        bins=50,
        xlabel="Number of Line Overloads per Sample",
        ylabel="Number of Samples",
        title="Distribution of Line Overloads per Sample\n(RTS-GMLC, $NUM_SAMPLES samples)",
        legend=false,
        color=:teal,
        alpha=0.7,
    )

    # Add stats annotation
    samples_with_viols = sample_overload_count[sample_overload_count .> 0]
    if length(samples_with_viols) > 0
        mean_overloads = mean(sample_overload_count)
        median_overloads = median(sample_overload_count)
        max_overloads = maximum(sample_overload_count)
        pct_with_overloads = 100 * length(samples_with_viols) / NUM_SAMPLES

        annotate!(
            p7,
            maximum(sample_overload_count) * 0.6,
            maximum(ylims(p7)) * 0.85,
            text(
                "Mean: $(round(mean_overloads, digits=1))\nMedian: $(round(median_overloads, digits=1))\nMax: $max_overloads\n$(round(pct_with_overloads, digits=1))% with overloads",
                10,
                :left,
            ),
        )
    end

    sample_dist_file = joinpath(OUTPUT_DIR, "line_overload_per_sample_histogram.png")
    savefig(p7, sample_dist_file)
    println("  Saved: $sample_dist_file")

    # CORRELATION WITH RELIABILITY METRICS

    # Plot 8: Scatter - overloads vs unserved energy (per sample)
    println("Creating scatter plot: Overloads vs. unserved energy...")

    # Get per-sample unserved energy
    sample_eue = shortfall[]

    p8 = scatter(
        sample_overload_count,
        sample_eue,
        xlabel="Line Overloads per Sample (count)",
        ylabel="Unserved Energy per Sample (MWh)",
        title="Unserved Energy vs Line Overloads\n(RTS-GMLC, $NUM_SAMPLES samples)",
        legend=false,
        color=:purple,
        alpha=0.5,
        markersize=4,
    )

    correlation_file = joinpath(OUTPUT_DIR, "line_overload_vs_eue.png")
    savefig(p8, correlation_file)
    println("  Saved: $correlation_file")

    # Plot 9: Scatter - max overload magnitude vs unserved energy
    println("Creating scatter plot: Max overload magnitude vs. unserved energy...")

    # Compute per-sample max overload magnitude
    sample_max_overload = zeros(Float64, NUM_SAMPLES)
    for i in 1:n_overloads
        sample_id = line_overload.sample_id[i]
        sample_max_overload[sample_id] = max(
            sample_max_overload[sample_id],
            line_overload.overload_mw[i]
        )
    end

    p9 = scatter(
        sample_max_overload,
        sample_eue,
        xlabel="Max Line Overload per Sample (MW)",
        ylabel="Unserved Energy per Sample (MWh)",
        title="Unserved Energy vs Max Line Overload\n(RTS-GMLC, $NUM_SAMPLES samples)",
        legend=false,
        color=:orange,
        alpha=0.5,
        markersize=4,
    )

    max_correlation_file = joinpath(OUTPUT_DIR, "line_overload_max_vs_eue.png")
    savefig(p9, max_correlation_file)
    println("  Saved: $max_correlation_file")

    # Plot 10: Line overload probability ranking
    println("Creating bar chart: Line overload probability ranking...")

    # Calculate probability for top 15 lines
    top_15_lines = get_most_overloaded_lines(line_overload, 15)
    line_names_prob = [x[1] for x in top_15_lines]
    line_probs = [
        100 * line_overload_probability(line_overload, name)
        for name in line_names_prob
    ]

    p10 = bar(
        line_names_prob,
        line_probs,
        xlabel="Transmission Line",
        ylabel="Overload Probability (%)",
        title="Line Overload Probability (Top 15 Lines)\n(RTS-GMLC, $NUM_SAMPLES samples)",
        legend=false,
        color=:coral,
        alpha=0.7,
        xrotation=45,
        size=(1000, 600),
        bottom_margin=15Plots.mm,
    )

    prob_file = joinpath(OUTPUT_DIR, "line_overload_probability.png")
    savefig(p10, prob_file)
    println("  Saved: $prob_file")

    # TEMPORAL ANALYSIS

    # Plot 11: Time series - overload events per timestep
    println("Creating time series: Overload events per timestep...")

    # Count overloads per timestep (aggregated across samples)
    overloads_per_timestep = zeros(Int, num_timesteps)
    for i in 1:n_overloads
        t = line_overload.timestep[i]
        overloads_per_timestep[t] += 1
    end

    p11 = plot(
        1:num_timesteps,
        overloads_per_timestep,
        xlabel="Time Step",
        ylabel="Overload Events",
        title="Line Overload Events Over Time\n(RTS-GMLC, aggregated across $NUM_SAMPLES samples)",
        legend=false,
        color=:darkblue,
        linewidth=2,
        size=(1000, 500),
    )

    temporal_count_file = joinpath(OUTPUT_DIR, "line_overload_temporal_count.png")
    savefig(p11, temporal_count_file)
    println("  Saved: $temporal_count_file")

    # Plot 12: Time series - average overload magnitude per timestep
    println("Creating time series: Average overload magnitude per timestep...")

    # Sum magnitudes per timestep
    magnitude_per_timestep = zeros(Float64, num_timesteps)
    count_per_timestep = zeros(Int, num_timesteps)
    for i in 1:n_overloads
        t = line_overload.timestep[i]
        magnitude_per_timestep[t] += line_overload.overload_mw[i]
        count_per_timestep[t] += 1
    end

    # Calculate average (avoid division by zero)
    avg_magnitude_per_timestep = similar(magnitude_per_timestep)
    for t in 1:num_timesteps
        if count_per_timestep[t] > 0
            avg_magnitude_per_timestep[t] = magnitude_per_timestep[t] / count_per_timestep[t]
        else
            avg_magnitude_per_timestep[t] = 0.0
        end
    end

    p12 = plot(
        1:num_timesteps,
        avg_magnitude_per_timestep,
        xlabel="Time Step",
        ylabel="Average Overload Magnitude (MW)",
        title="Average Line Overload Magnitude Over Time\n(RTS-GMLC, when overloads occur)",
        legend=false,
        color=:darkred,
        linewidth=2,
        size=(1000, 500),
    )

    temporal_mag_file = joinpath(OUTPUT_DIR, "line_overload_temporal_magnitude.png")
    savefig(p12, temporal_mag_file)
    println("  Saved: $temporal_mag_file")

    # ADDITIONAL INSIGHTS

    # Plot 13: Flow utilization distribution
    println("Creating histogram: Flow utilization distribution...")

    # Calculate flow/rating ratio for all overload events
    utilization_ratios = line_overload.flow_mw ./ line_overload.rating_mw

    p13 = histogram(
        utilization_ratios,
        bins=50,
        xlabel="Flow / Rating Ratio",
        ylabel="Frequency",
        title="Transmission Line Utilization During Overloads\n(RTS-GMLC, $NUM_SAMPLES samples)",
        legend=false,
        color=:forestgreen,
        alpha=0.7,
    )

    # Add vertical line at 1.0 (rating limit)
    vline!(
        p13,
        [1.0],
        linewidth=2,
        linestyle=:dash,
        color=:red,
        label="Rating Limit",
    )

    utilization_file = joinpath(OUTPUT_DIR, "line_overload_utilization.png")
    savefig(p13, utilization_file)
    println("  Saved: $utilization_file")

    # CORRELATION ANALYSIS

    println()
    println("Correlation Analysis:")

    # Correlation between overload count and EUE
    nonzero_mask = (sample_overload_count .> 0) .| (sample_eue .> 0)
    if sum(nonzero_mask) > 1
        count_eue_corr = cor(sample_overload_count[nonzero_mask], sample_eue[nonzero_mask])
        println("  Correlation (overload count vs EUE): $(round(count_eue_corr, digits=3))")
    end

    # Correlation between max overload magnitude and EUE
    if sum(sample_max_overload .> 0) > 1
        mag_nonzero_mask = (sample_max_overload .> 0) .| (sample_eue .> 0)
        mag_eue_corr = cor(sample_max_overload[mag_nonzero_mask], sample_eue[mag_nonzero_mask])
        println("  Correlation (max overload vs EUE): $(round(mag_eue_corr, digits=3))")
    end

    # Samples with high overloads but low EUE
    high_overload_threshold = quantile(sample_overload_count[sample_overload_count .> 0], 0.75)
    if sum(sample_eue .> 0) > 0
        low_eue_threshold = quantile(sample_eue[sample_eue .> 0], 0.25)
        high_ov_low_eue = sum(
            (sample_overload_count .>= high_overload_threshold) .&
            (sample_eue .<= low_eue_threshold)
        )
        println("  Samples with high overloads but low EUE: $high_ov_low_eue")
        println("    (May indicate overloads don't always cause shortfall)")
    end

    println()

else
    println("No line overloads detected - no plots to generate!")
end

#######################
# Summary Statistics
#######################

println("="^80)
println("SUMMARY STATISTICS")
println("="^80)
println()
println("Power Flow:")
println("  Convergence rate: $(round(100 * convergence_rate, digits=2))%")
println("  Total solves: $(NUM_SAMPLES * length(line_overload.timestamps))")
println()

if n_overloads > 0
    samples_affected = length(unique(line_overload.sample_id))
    lines_affected = length(unique(line_overload.line_idx))
    timesteps_affected = length(unique(line_overload.timestep))

    println("Overload Statistics:")
    println("  Total overload events: $n_overloads")
    println("  Samples affected: $samples_affected / $NUM_SAMPLES ($(round(100 * samples_affected / NUM_SAMPLES, digits=1))%)")
    println("  Lines affected: $lines_affected / $(length(line_overload.branch_names))")
    println("  Timesteps affected: $timesteps_affected / $(length(line_overload.timestamps))")
    println("  Overall overload probability: $(round(100 * overload_probability(line_overload), digits=2))%")
    println()

    println("Top 5 Critical Lines:")
    top_5 = get_most_overloaded_lines(line_overload, 5)
    for (i, (name, count, max_ov)) in enumerate(top_5)
        prob = line_overload_probability(line_overload, name)
        println("  $i. $name")
        println("     Events: $count, Max: $(round(max_ov, digits=2)) MW, Prob: $(round(100 * prob, digits=2))%")
    end
end

println()
println("="^80)
println("ANALYSIS COMPLETE")
println("="^80)
println("Plots saved to: $OUTPUT_DIR")
println()
