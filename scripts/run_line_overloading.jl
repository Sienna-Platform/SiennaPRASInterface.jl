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

Results are visualized using Plots.jl and saved to the specified output directory.

Usage:
    julia --project=scripts --threads=auto scripts/run_line_overloading.jl <system> <disaggregation> <output_dir>

Arguments:
    system          - System variant: "unmodified" or "modified" (default: "modified")
    disaggregation  - Disaggregation method: "proportional", "merit_order", or "ramp_aware" (default: "ramp_aware")
    output_dir      - Output directory for plots and reports (default: "results/line_overloading")

Examples:
    julia --project=scripts --threads=auto scripts/run_line_overloading.jl unmodified proportional results/line_unmodified_proportional
    julia --project=scripts --threads=auto scripts/run_line_overloading.jl modified merit_order results/line_modified_merit
    julia --project=scripts --threads=auto scripts/run_line_overloading.jl modified ramp_aware results/line_modified_ramp_aware
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

function parse_arguments()
    # Default values
    system_variant = "modified"
    disaggregation_method = "proportional"
    output_dir = "results/line_overloading"

    # Parse command line arguments
    if length(ARGS) >= 1
        system_variant = lowercase(ARGS[1])
        if !(system_variant in ["unmodified", "modified"])
            error(
                "Invalid system variant: '$system_variant'. Must be 'unmodified' or 'modified'",
            )
        end
    end

    if length(ARGS) >= 2
        disaggregation_method = lowercase(ARGS[2])
        if !(disaggregation_method in ["proportional", "merit_order", "ramp_aware"])
            error(
                "Invalid disaggregation method: '$disaggregation_method'. Must be 'proportional', 'merit_order', or 'ramp_aware'",
            )
        end
    end

    if length(ARGS) >= 3
        output_dir = ARGS[3]
    end

    return system_variant, disaggregation_method, output_dir
end

function get_disaggregation_function(method::String, sys::PSY.System)
    if method == "proportional"
        return SiennaPRASInterface.proportional_disaggregation
    elseif method == "merit_order"
        # Wrap merit_order_disaggregation to include sys argument
        return SiennaPRASInterface.merit_order_disaggregation
    elseif method == "ramp_aware"
        return SiennaPRASInterface.ramp_aware_disaggregation
    else
        error("Unknown disaggregation method: $method")
    end
end

system_variant, disaggregation_method, output_dir = parse_arguments()

const NUM_SAMPLES = 1000
const RANDOM_SEED = 1234

# Create output directory if it doesn't exist
mkpath(output_dir)

# Open report file for writing
report_file = joinpath(output_dir, "report.txt")
report_io = open(report_file, "w")

# Helper function to print to both console and report file
function report_println(args...)
    println(args...)
    println(report_io, args...)
    flush(report_io)
end

report_println("="^80)
report_println("RTS-GMLC Line Overloading Analysis")
report_println("="^80)
report_println("Configuration:")
report_println("  System variant: $system_variant")
report_println("  Disaggregation method: $disaggregation_method")
report_println("  Output directory: $output_dir")
report_println("  Samples: $NUM_SAMPLES")
report_println("  Random seed: $RANDOM_SEED")
report_println()

#######################
# Load RTS-GMLC System
#######################

report_println("Loading RTS-GMLC Day-Ahead system...")
use_modified = (system_variant == "modified")
sys = get_rts_gmlc_outage("DA"; modified=use_modified)

report_println("System loaded successfully!")
report_println(
    "  System type: $(use_modified ? "modified" : "unmodified (10% load increase)") RTS-GMLC",
)
report_println("  Number of areas: $(length(PSY.get_components(PSY.Area, sys)))")
report_println("  Number of branches: $(length(PSY.get_components(PSY.ACBranch, sys)))")
report_println()

#######################
# Set Up Simulation
#######################

report_println("Setting up Monte Carlo simulation with power flow...")

# Create Monte Carlo method
method = SequentialMonteCarlo(; samples=NUM_SAMPLES, seed=RANDOM_SEED)

# Get disaggregation function
disagg_func = get_disaggregation_function(disaggregation_method, sys)

# Create power flow result spec (DC power flow for speed)
line_overload_spec = PowerFlowWithOverloads(sys, PFS.DCPowerFlow(); disaggregation_func=disagg_func)

report_println("Simulation configured:")
report_println("  Method: Sequential Monte Carlo")
report_println("  Power flow: DC Power Flow")
report_println("  Disaggregation: $disaggregation_method")
report_println("  Aggregation: By Area")
report_println()

#######################
# Run Assessment
#######################

report_println("Running resource adequacy assessment with power flow...")
report_println("This may take several minutes...")
report_println()

start_time = time()
shortfall, line_overload =
    assess(sys, PSY.Area, method, ShortfallSamples(), line_overload_spec)
elapsed_time = time() - start_time

report_println("Assessment completed in $(round(elapsed_time, digits=2)) seconds")
report_println()

#######################
# Process Results
#######################

report_println("="^80)
report_println("RESULTS SUMMARY")
report_println("="^80)
report_println()

# Shortfall metrics
lole = val(LOLE(shortfall))
eue_val = val(EUE(shortfall))

report_println("Reliability Metrics:")
report_println("  Loss of Load Expectation (LOLE): $(round(lole, digits=4)) events/period")
report_println("  Expected Unserved Energy (EUE): $(round(eue_val, digits=2)) MWh")
report_println()

# Line overload metrics
n_overloads = count_overload_events(line_overload)
convergence_rate = line_overload.convergence_rate

report_println("Power Flow Statistics:")
report_println("  Convergence rate: $(round(100 * convergence_rate, digits=2))%")
report_println()

report_println("Line Overload Metrics:")
report_println("  Total overload events: $n_overloads")

if n_overloads > 0
    max_overload = maximum(line_overload.overload_mw)
    mean_overload = mean(line_overload.overload_mw)
    median_overload = median(line_overload.overload_mw)

    report_println("  Maximum overload: $(round(max_overload, digits=2)) MW")
    report_println("  Mean overload: $(round(mean_overload, digits=2)) MW")
    report_println("  Median overload: $(round(median_overload, digits=2)) MW")

    # Count samples with overloads
    samples_with_overloads = length(unique(line_overload.sample_id))
    report_println("  Samples with overloads: $samples_with_overloads / $NUM_SAMPLES")

    # Overall overload probability
    prob_overload = overload_probability(line_overload)
    report_println(
        "  Probability of any overload: $(round(100 * prob_overload, digits=2))%",
    )

    # Top 5 lines by overload count
    top_lines = get_most_overloaded_lines(line_overload, 5)
    report_println()
    report_println("  Top 5 most overloaded lines:")
    for (i, (line_name, count, max_ov)) in enumerate(top_lines)
        report_println(
            "    $i. $line_name: $count events (max: $(round(max_ov, digits=2)) MW)",
        )
    end
else
    report_println("  No line overloads detected!")
end
report_println()

#######################
# Generate Plots
#######################

report_println("="^80)
report_println("GENERATING VISUALIZATIONS")
report_println("="^80)
report_println()

# Set plot defaults for publication quality
default(; size=(800, 600), dpi=300, legendfontsize=10, guidefontsize=12, tickfontsize=10)

if n_overloads > 0
    # Extract dimensions
    num_timesteps = length(line_overload.timestamps)
    num_lines = length(line_overload.branch_names)

    # PRIORITY: HEATMAP VISUALIZATIONS

    # Heatmap 1: Overload count (samples × timesteps)
    report_println("Creating heatmap: Overload count (samples × timesteps)...")

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

    count_heatmap_file = joinpath(output_dir, "line_overload_count_heatmap.png")
    savefig(p1, count_heatmap_file)
    report_println("  Saved: $count_heatmap_file")

    # Heatmap 2: Overload magnitude (samples × timesteps)
    report_println("Creating heatmap: Overload magnitude (samples × timesteps)...")

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

    mag_heatmap_file = joinpath(output_dir, "line_overload_magnitude_heatmap.png")
    savefig(p2, mag_heatmap_file)
    report_println("  Saved: $mag_heatmap_file")

    # Heatmap 3: Line-specific overload count (lines × timesteps)
    report_println("Creating heatmap: Per-line overload count (lines × timesteps)...")

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

    line_heatmap_file = joinpath(output_dir, "line_overload_by_line_heatmap.png")
    savefig(p3, line_heatmap_file)
    report_println("  Saved: $line_heatmap_file")

    # Heatmap 4: Per-sample overload count (lines × samples)
    report_println("Creating heatmap: Per-line per-sample overload count...")

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

    line_sample_heatmap_file =
        joinpath(output_dir, "line_overload_by_line_sample_heatmap.png")
    savefig(p4, line_sample_heatmap_file)
    report_println("  Saved: $line_sample_heatmap_file")

    # DISTRIBUTION & RANKING PLOTS

    # Plot 5: Histogram of overload magnitudes
    report_println("Creating histogram: Overload magnitudes...")

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

    overload_hist_file = joinpath(output_dir, "line_overload_magnitude_histogram.png")
    savefig(p5, overload_hist_file)
    report_println("  Saved: $overload_hist_file")

    # Plot 6: Bar chart of top 15 most overloaded lines
    report_println("Creating bar chart: Top 15 most overloaded lines...")

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

    top_lines_file = joinpath(output_dir, "line_overload_top_lines.png")
    savefig(p6, top_lines_file)
    report_println("  Saved: $top_lines_file")

    # Plot 7: Histogram of overloads per sample
    report_println("Creating histogram: Overloads per sample...")

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

    sample_dist_file = joinpath(output_dir, "line_overload_per_sample_histogram.png")
    savefig(p7, sample_dist_file)
    report_println("  Saved: $sample_dist_file")

    # CORRELATION WITH RELIABILITY METRICS

    # Plot 8: Scatter - overloads vs unserved energy (per sample)
    report_println("Creating scatter plot: Overloads vs. unserved energy...")

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

    correlation_file = joinpath(output_dir, "line_overload_vs_eue.png")
    savefig(p8, correlation_file)
    report_println("  Saved: $correlation_file")

    # Plot 9: Scatter - max overload magnitude vs unserved energy
    report_println("Creating scatter plot: Max overload magnitude vs. unserved energy...")

    # Compute per-sample max overload magnitude
    sample_max_overload = zeros(Float64, NUM_SAMPLES)
    for i in 1:n_overloads
        sample_id = line_overload.sample_id[i]
        sample_max_overload[sample_id] =
            max(sample_max_overload[sample_id], line_overload.overload_mw[i])
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

    max_correlation_file = joinpath(output_dir, "line_overload_max_vs_eue.png")
    savefig(p9, max_correlation_file)
    report_println("  Saved: $max_correlation_file")

    # Plot 10: Line overload probability ranking
    report_println("Creating bar chart: Line overload probability ranking...")

    # Calculate probability for top 15 lines
    top_15_lines = get_most_overloaded_lines(line_overload, 15)
    line_names_prob = [x[1] for x in top_15_lines]
    line_probs =
        [100 * line_overload_probability(line_overload, name) for name in line_names_prob]

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

    prob_file = joinpath(output_dir, "line_overload_probability.png")
    savefig(p10, prob_file)
    report_println("  Saved: $prob_file")

    # TEMPORAL ANALYSIS

    # Plot 11: Time series - overload events per timestep
    report_println("Creating time series: Overload events per timestep...")

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

    temporal_count_file = joinpath(output_dir, "line_overload_temporal_count.png")
    savefig(p11, temporal_count_file)
    report_println("  Saved: $temporal_count_file")

    # Plot 12: Time series - average overload magnitude per timestep
    report_println("Creating time series: Average overload magnitude per timestep...")

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
            avg_magnitude_per_timestep[t] =
                magnitude_per_timestep[t] / count_per_timestep[t]
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

    temporal_mag_file = joinpath(output_dir, "line_overload_temporal_magnitude.png")
    savefig(p12, temporal_mag_file)
    report_println("  Saved: $temporal_mag_file")

    # ADDITIONAL INSIGHTS

    # Plot 13: Flow utilization distribution
    report_println("Creating histogram: Flow utilization distribution...")

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
    vline!(p13, [1.0], linewidth=2, linestyle=:dash, color=:red, label="Rating Limit")

    utilization_file = joinpath(output_dir, "line_overload_utilization.png")
    savefig(p13, utilization_file)
    report_println("  Saved: $utilization_file")

    # CORRELATION ANALYSIS

    report_println()
    report_println("Correlation Analysis:")

    # Correlation between overload count and EUE
    nonzero_mask = (sample_overload_count .> 0) .| (sample_eue .> 0)
    if sum(nonzero_mask) > 1
        count_eue_corr = cor(sample_overload_count[nonzero_mask], sample_eue[nonzero_mask])
        report_println(
            "  Correlation (overload count vs EUE): $(round(count_eue_corr, digits=3))",
        )
    end

    # Correlation between max overload magnitude and EUE
    if sum(sample_max_overload .> 0) > 1
        mag_nonzero_mask = (sample_max_overload .> 0) .| (sample_eue .> 0)
        mag_eue_corr =
            cor(sample_max_overload[mag_nonzero_mask], sample_eue[mag_nonzero_mask])
        report_println(
            "  Correlation (max overload vs EUE): $(round(mag_eue_corr, digits=3))",
        )
    end

    # Samples with high overloads but low EUE
    high_overload_threshold =
        quantile(sample_overload_count[sample_overload_count .> 0], 0.75)
    if sum(sample_eue .> 0) > 0
        low_eue_threshold = quantile(sample_eue[sample_eue .> 0], 0.25)
        high_ov_low_eue = sum(
            (sample_overload_count .>= high_overload_threshold) .&
            (sample_eue .<= low_eue_threshold),
        )
        report_println("  Samples with high overloads but low EUE: $high_ov_low_eue")
        report_println("    (May indicate overloads don't always cause shortfall)")
    end

    report_println()

else
    report_println("No line overloads detected - no plots to generate!")
end

#######################
# Summary Statistics
#######################

report_println("="^80)
report_println("SUMMARY STATISTICS")
report_println("="^80)
report_println()
report_println("Power Flow:")
report_println("  Convergence rate: $(round(100 * convergence_rate, digits=2))%")
report_println("  Total solves: $(NUM_SAMPLES * length(line_overload.timestamps))")
report_println()

if n_overloads > 0
    samples_affected = length(unique(line_overload.sample_id))
    lines_affected = length(unique(line_overload.line_idx))
    timesteps_affected = length(unique(line_overload.timestep))

    report_println("Overload Statistics:")
    report_println("  Total overload events: $n_overloads")
    report_println(
        "  Samples affected: $samples_affected / $NUM_SAMPLES ($(round(100 * samples_affected / NUM_SAMPLES, digits=1))%)",
    )
    report_println(
        "  Lines affected: $lines_affected / $(length(line_overload.branch_names))",
    )
    report_println(
        "  Timesteps affected: $timesteps_affected / $(length(line_overload.timestamps))",
    )
    report_println(
        "  Overall overload probability: $(round(100 * overload_probability(line_overload), digits=2))%",
    )
    report_println()

    report_println("Top 5 Critical Lines:")
    top_5 = get_most_overloaded_lines(line_overload, 5)
    for (i, (name, count, max_ov)) in enumerate(top_5)
        prob = line_overload_probability(line_overload, name)
        report_println("  $i. $name")
        report_println(
            "     Events: $count, Max: $(round(max_ov, digits=2)) MW, Prob: $(round(100 * prob, digits=2))%",
        )
    end
end

report_println()
report_println("="^80)
report_println("ANALYSIS COMPLETE")
report_println("="^80)
report_println("Plots saved to: $output_dir")
report_println()

# Close report file
close(report_io)
