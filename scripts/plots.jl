"""
PRAS Simulation Results Plotting Module

This module provides functions for:
1. Serializing and deserializing PRAS simulation results (JLD2 format)
2. Plotting individual simulation results (ramp violations, line overloads, correlations)
3. Creating overlay comparison plots across multiple simulation runs
"""

using JLD2
using Plots
using Statistics
using SiennaPRASInterface
import PRASCore

"""
    save_simulation_results(output_dir::String, shortfall, custom_result)

Save PRAS simulation results to JLD2 file.

For LineOverloadResult, strips the _pf_data field (contains C finalizers, not serializable).

Arguments:

  - output_dir: Directory where results.jld2 will be saved
  - keyword arguments
"""
function save_simulation_results(output_dir::String; keyword_results...)
    results_file = joinpath(output_dir, "results.jld2")

    results = Dict(keyword_results)
    if haskey(results, "line_overload")
        results["line_overload"] = strip_powerflow_data(results["line_overload"])
    end

    jldsave(results_file; results...)
    println("Saved results to: $results_file")
    return results_file
end

"""
    load_simulation_results(results_file::String)

Load PRAS simulation results from JLD2 file.

Returns:

  - Dict of name to results
"""
function load_simulation_results(results_file::String)
    return load(results_file)
end

"""
    strip_powerflow_data(result::SiennaPRASInterface.LineOverloadResult)

Remove non-serializable PowerFlowData from LineOverloadResult.

The _pf_data field contains C-backed objects with finalizers that cannot be serialized.
This field is only needed to keep objects alive during simulation; it's safe to remove
after simulation completes.
"""
function strip_powerflow_data(result)
    # Get the type parameters
    N = length(result.timestamps)
    L = result.timestamps[2] - result.timestamps[1]
    T = typeof(result.timestamps).parameters[3]
    S = length(unique(result.sample_id))

    # Reconstruct without _pf_data
    return SiennaPRASInterface.LineOverloadResult{N, L, T, S}(
        result.timestamps,
        result.branch_names,
        result.line_idx,
        result.timestep,
        result.sample_id,
        result.overload_mw,
        result.flow_mw,
        result.rating_mw,
        result.convergence_rate,
        [],  # Empty PowerFlowData vector
    )
end

#######################
# Ramp Violation Plots
#######################

"""
    plot_ramp_violations(
        ramp_violations,
        shortfall,
        output_dir::String,
        system_label::String,
        NUM_SAMPLES::Int;
        gen_counts=nothing
    )

Generate all ramp violation plots and save to output_dir.

Arguments:

  - ramp_violations: RampViolationsResult from assessment
  - shortfall: ShortfallSamplesResult from assessment
  - output_dir: Directory to save plots
  - system_label: Label for plot titles (e.g., "RTS-GMLC modified, proportional")
  - NUM_SAMPLES: Number of Monte Carlo samples
  - gen_counts: Optional Dict of generator violation counts (computed if not provided)
"""
function plot_ramp_violations(
    ramp_violations,
    shortfall,
    output_dir::String,
    system_label::String,
    NUM_SAMPLES::Int;
    gen_counts=nothing,
    report_println=println,
)
    # Set plot defaults
    default(;
        size=(800, 600),
        dpi=300,
        legendfontsize=10,
        guidefontsize=12,
        tickfontsize=10,
    )

    # Extract violation data
    violations = ramp_violations.ramp_violation.value
    n_violations = length(violations)

    if n_violations == 0
        report_println("No violations to plot!")
        return
    end

    report_println("Generating ramp violation plots...")

    # Extract data from sparse accumulator
    sample_ids = ramp_violations.ramp_violation.sampleid
    timesteps = ramp_violations.ramp_violation.time
    violations_values = ramp_violations.ramp_violation.value

    # Determine dimensions
    num_timesteps = maximum(timesteps)
    num_samples = NUM_SAMPLES

    # Build violation matrices
    violation_count_matrix = zeros(Int, num_samples, num_timesteps)
    violation_magnitude_matrix = zeros(Float64, num_samples, num_timesteps)
    for i in eachindex(sample_ids)
        s = sample_ids[i]
        t = timesteps[i]
        violation_count_matrix[s, t] += 1
        violation_magnitude_matrix[s, t] += abs(violations_values[i])
    end

    # Build outage mask matrix
    outage_mask = zeros(Bool, num_samples, num_timesteps)
    gen_unavail = ramp_violations.generator_unavailability
    for i in 1:length(gen_unavail.sampleid)
        s = gen_unavail.sampleid[i]
        t = gen_unavail.time[i]
        outage_mask[s, t] = true
    end

    # Compute per-sample metrics
    sample_ramp_count = zeros(Int, NUM_SAMPLES)
    sample_ramp_magnitude = zeros(Float64, NUM_SAMPLES)
    for i in 1:n_violations
        sample_id = ramp_violations.ramp_violation.sampleid[i]
        sample_ramp_count[sample_id] += 1
        sample_ramp_magnitude[sample_id] += abs(violations[i])
    end

    sample_eue = shortfall[]

    # Compute generator counts if not provided
    if isnothing(gen_counts)
        gen_counts = compute_gen_violation_counts(ramp_violations)
    end

    # Plot 1: Histogram of violation magnitudes
    plot_ramp_histogram(violations, output_dir, system_label, report_println)

    # Plot 2: Heatmaps
    plot_ramp_heatmaps(
        violation_count_matrix,
        violation_magnitude_matrix,
        outage_mask,
        output_dir,
        system_label,
        num_timesteps,
        num_samples,
        report_println,
    )

    # Plot 3: Top generators
    if !isnothing(gen_counts) && length(gen_counts) > 0
        plot_top_generators(gen_counts, output_dir, system_label, report_println)
    end

    # Plot 4: Correlations with shortfall
    plot_ramp_correlations(
        sample_ramp_count,
        sample_ramp_magnitude,
        sample_eue,
        output_dir,
        system_label,
        report_println,
    )

    # Plot 5: Per-sample distribution
    plot_ramp_per_sample(
        sample_ramp_count,
        output_dir,
        system_label,
        NUM_SAMPLES,
        report_println,
    )
end

"""
    compute_gen_violation_counts(ramp_violations)

Count violations per generator from RampViolationsResult.
"""
function compute_gen_violation_counts(ramp_violations)
    gen_counts = Dict{String, Int}()
    generators = ramp_violations.generators

    for i in 1:length(ramp_violations.ramp_violation.value)
        gen_idx = ramp_violations.ramp_violation.idx[i]
        gen_name = generators[gen_idx]
        gen_counts[gen_name] = get(gen_counts, gen_name, 0) + 1
    end

    return gen_counts
end

"""
    plot_ramp_histogram(violations, output_dir, system_label, report_println)

Plot histogram of ramp violation magnitudes.
"""
function plot_ramp_histogram(violations, output_dir, system_label, report_println)
    report_println("  Creating histogram of ramp violation magnitudes...")

    abs_violations = abs.(violations)

    p1 = histogram(
        abs_violations,
        bins=50,
        xlabel="Violation Magnitude (MW/min)",
        ylabel="Frequency",
        title="Distribution of Ramp Violations\n($system_label)",
        legend=false,
        color=:steelblue,
        alpha=0.7,
    )

    histogram_file = joinpath(output_dir, "ramp_violations_histogram.png")
    savefig(p1, histogram_file)
    report_println("    Saved: $histogram_file")
end

"""
    plot_ramp_heatmaps(
        violation_count_matrix,
        violation_magnitude_matrix,
        outage_mask,
        output_dir,
        system_label,
        num_timesteps,
        num_samples,
        report_println
    )

Create heatmaps of violation counts and magnitudes.
"""
function plot_ramp_heatmaps(
    violation_count_matrix,
    violation_magnitude_matrix,
    outage_mask,
    output_dir,
    system_label,
    num_timesteps,
    num_samples,
    report_println,
)
    report_println("  Creating heatmaps...")

    # Heatmap 2a: Violation counts
    heatmap_data = log10.(violation_count_matrix .+ 1)
    p2a = heatmap(
        1:num_timesteps,
        1:num_samples,
        heatmap_data,
        xlabel="Time Step",
        ylabel="Sample ID",
        title="Ramp Violations Count Heatmap\n($system_label)",
        colorbar_title="log10(Count+1)",
        color=:viridis,
        aspect_ratio=:auto,
        size=(1000, 600),
        left_margin=10Plots.mm,
        right_margin=10Plots.mm,
        top_margin=10Plots.mm,
        bottom_margin=10Plots.mm,
    )

    count_heatmap_file = joinpath(output_dir, "ramp_violations_count_heatmap.png")
    savefig(p2a, count_heatmap_file)
    report_println("    Saved: $count_heatmap_file")

    # Heatmap 2b: Violation magnitudes
    magnitude_heatmap_data = log10.(violation_magnitude_matrix .+ 0.01)
    p2b = heatmap(
        1:num_timesteps,
        1:num_samples,
        magnitude_heatmap_data,
        xlabel="Time Step",
        ylabel="Sample ID",
        title="Ramp Violations Magnitude Heatmap\n($system_label)",
        colorbar_title="log10(MW/min)",
        color=:plasma,
        aspect_ratio=:auto,
        size=(1000, 600),
        left_margin=10Plots.mm,
        right_margin=10Plots.mm,
        top_margin=10Plots.mm,
        bottom_margin=10Plots.mm,
    )

    magnitude_heatmap_file = joinpath(output_dir, "ramp_violations_magnitude_heatmap.png")
    savefig(p2b, magnitude_heatmap_file)
    report_println("    Saved: $magnitude_heatmap_file")

    # Heatmap 2c: With outages
    magnitude_with_outages = copy(violation_magnitude_matrix)
    magnitude_with_outages[.!outage_mask] .= NaN

    if any(.!isnan.(magnitude_with_outages))
        p2c = heatmap(
            1:num_timesteps,
            1:num_samples,
            log10.(magnitude_with_outages .+ 0.01),
            xlabel="Time Step",
            ylabel="Sample ID",
            title="Ramp Violations When Outages Occur\n($system_label)",
            colorbar_title="log10(MW/min)",
            color=:plasma,
            aspect_ratio=:auto,
            size=(1000, 600),
            left_margin=10Plots.mm,
            right_margin=10Plots.mm,
            top_margin=10Plots.mm,
            bottom_margin=10Plots.mm,
        )

        savefig(p2c, joinpath(output_dir, "ramp_violations_magnitude_with_outages.png"))
        report_println("    Saved: ramp_violations_magnitude_with_outages.png")
    end

    # Heatmap 2d: Without outages
    magnitude_no_outages = copy(violation_magnitude_matrix)
    magnitude_no_outages[outage_mask] .= NaN

    if any(.!isnan.(magnitude_no_outages))
        p2d = heatmap(
            1:num_timesteps,
            1:num_samples,
            log10.(magnitude_no_outages .+ 0.01),
            xlabel="Time Step",
            ylabel="Sample ID",
            title="Ramp Violations When NO Outages Occur\n($system_label)",
            colorbar_title="log10(MW/min)",
            color=:plasma,
            aspect_ratio=:auto,
            size=(1000, 600),
            left_margin=10Plots.mm,
            right_margin=10Plots.mm,
            top_margin=10Plots.mm,
            bottom_margin=10Plots.mm,
        )

        savefig(p2d, joinpath(output_dir, "ramp_violations_magnitude_no_outages.png"))
        report_println("    Saved: ramp_violations_magnitude_no_outages.png")
    end
end

"""
    plot_top_generators(gen_counts, output_dir, system_label, report_println)

Plot top 10 generators by violation count.
"""
function plot_top_generators(gen_counts, output_dir, system_label, report_println)
    report_println("  Creating bar plot of top generators...")

    sorted_gens = sort(collect(gen_counts), by=x -> x[2], rev=true)
    top_10 = sorted_gens[1:min(10, length(sorted_gens))]

    gen_labels = [x[1] for x in top_10]
    gen_violation_counts = [x[2] for x in top_10]

    p3 = bar(
        gen_labels,
        gen_violation_counts,
        xlabel="Generator",
        ylabel="Violation Count",
        title="Top 10 Generators by Ramp Violations\n($system_label)",
        legend=false,
        color=:indianred,
        alpha=0.7,
        xrotation=45,
    )

    generators_file = joinpath(output_dir, "ramp_violations_generators.png")
    savefig(p3, generators_file)
    report_println("    Saved: $generators_file")
end

"""
    plot_ramp_correlations(
        sample_ramp_count,
        sample_ramp_magnitude,
        sample_eue,
        output_dir,
        system_label,
        report_println
    )

Plot correlations between ramp violations and unserved energy.
"""
function plot_ramp_correlations(
    sample_ramp_count,
    sample_ramp_magnitude,
    sample_eue,
    output_dir,
    system_label,
    report_println,
)
    report_println("  Creating correlation plots...")

    # Plot 4a: Violation count vs EUE
    p4 = scatter(
        sample_ramp_count,
        sample_eue,
        xlabel="Ramp Violations per Sample (count)",
        ylabel="Unserved Energy per Sample (MWh)",
        title="Lost Load vs Ramp Violations\n($system_label)",
        legend=false,
        color=:purple,
        alpha=0.5,
        markersize=4,
    )

    correlation_file = joinpath(output_dir, "lostload_vs_ramp_violations.png")
    savefig(p4, correlation_file)
    report_println("    Saved: $correlation_file")

    # Plot 4b: Violation magnitude vs EUE
    p4b = scatter(
        sample_ramp_magnitude,
        sample_eue,
        xlabel="Total Ramp Violation Magnitude per Sample (MW/min)",
        ylabel="Unserved Energy per Sample (MWh)",
        title="Lost Load vs Ramp Violation Magnitude\n($system_label)",
        legend=false,
        color=:orange,
        alpha=0.5,
        markersize=4,
    )

    magnitude_correlation_file = joinpath(output_dir, "lostload_vs_ramp_magnitude.png")
    savefig(p4b, magnitude_correlation_file)
    report_println("    Saved: $magnitude_correlation_file")
end

"""
    plot_ramp_per_sample(
        sample_ramp_count,
        output_dir,
        system_label,
        NUM_SAMPLES,
        report_println
    )

Plot distribution of violations per sample.
"""
function plot_ramp_per_sample(
    sample_ramp_count,
    output_dir,
    system_label,
    NUM_SAMPLES,
    report_println,
)
    report_println("  Creating histogram of violations per sample...")

    samples_with_viols = sample_ramp_count[sample_ramp_count .> 0]

    p5 = histogram(
        sample_ramp_count,
        bins=50,
        xlabel="Number of Ramp Violations per Sample",
        ylabel="Number of Samples",
        title="Distribution of Ramp Violations per Sample\n($system_label)",
        legend=false,
        color=:teal,
        alpha=0.7,
    )

    median_violations = median(sample_ramp_count)
    vline!(
        p5,
        [median_violations],
        linewidth=2,
        linestyle=:dash,
        color=:red,
        label="Median = $(round(median_violations, digits=1))",
    )

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

    sample_dist_file = joinpath(output_dir, "ramp_violations_per_sample.png")
    savefig(p5, sample_dist_file)
    report_println("    Saved: $sample_dist_file")
end

#######################
# Line Overload Plots
#######################

"""
    plot_line_overloads(
        line_overload,
        shortfall,
        output_dir::String,
        system_label::String,
        NUM_SAMPLES::Int;
        report_println=println
    )

Generate all line overload plots and save to output_dir.

Arguments:

  - line_overload: LineOverloadResult from assessment
  - shortfall: ShortfallSamplesResult from assessment
  - output_dir: Directory to save plots
  - system_label: Label for plot titles (e.g., "RTS-GMLC, 1000 samples")
  - NUM_SAMPLES: Number of Monte Carlo samples
  - report_println: Function to use for logging (default: println)
"""
function plot_line_overloads(
    line_overload,
    shortfall,
    output_dir::String,
    system_label::String,
    NUM_SAMPLES::Int;
    report_println=println,
)
    # Set plot defaults
    default(;
        size=(800, 600),
        dpi=300,
        legendfontsize=10,
        guidefontsize=12,
        tickfontsize=10,
    )

    n_overloads = length(line_overload.overload_mw)

    if n_overloads == 0
        report_println("No line overloads detected - no plots to generate!")
        return
    end

    report_println("Generating line overload plots...")

    # Extract dimensions
    num_timesteps = length(line_overload.timestamps)
    num_lines = length(line_overload.branch_names)

    # Build matrices
    overload_count_matrix = zeros(Int, NUM_SAMPLES, num_timesteps)
    overload_magnitude_matrix = zeros(Float64, NUM_SAMPLES, num_timesteps)
    line_timestep_matrix = zeros(Int, num_lines, num_timesteps)
    line_sample_matrix = zeros(Int, num_lines, NUM_SAMPLES)
    sample_overload_count = zeros(Int, NUM_SAMPLES)
    sample_max_overload = zeros(Float64, NUM_SAMPLES)

    for i in 1:n_overloads
        s = line_overload.sample_id[i]
        t = line_overload.timestep[i]
        line_idx = line_overload.line_idx[i]
        overload = line_overload.overload_mw[i]

        overload_count_matrix[s, t] += 1
        overload_magnitude_matrix[s, t] += overload
        line_timestep_matrix[line_idx, t] += 1
        line_sample_matrix[line_idx, s] += 1
        sample_overload_count[s] += 1
        sample_max_overload[s] = max(sample_max_overload[s], overload)
    end

    sample_eue = shortfall[]

    # Plot heatmaps
    plot_overload_heatmaps(
        overload_count_matrix,
        overload_magnitude_matrix,
        line_timestep_matrix,
        line_sample_matrix,
        line_overload,
        output_dir,
        system_label,
        num_timesteps,
        NUM_SAMPLES,
        report_println,
    )

    # Plot distributions
    plot_overload_distributions(
        line_overload,
        sample_overload_count,
        output_dir,
        system_label,
        NUM_SAMPLES,
        report_println,
    )

    # Plot correlations
    plot_overload_correlations(
        sample_overload_count,
        sample_max_overload,
        sample_eue,
        output_dir,
        system_label,
        report_println,
    )

    # Plot temporal patterns
    plot_overload_temporal(
        line_overload,
        num_timesteps,
        output_dir,
        system_label,
        NUM_SAMPLES,
        report_println,
    )
end

"""
    plot_overload_heatmaps(...)

Create heatmap visualizations for line overloads.
"""
function plot_overload_heatmaps(
    overload_count_matrix,
    overload_magnitude_matrix,
    line_timestep_matrix,
    line_sample_matrix,
    line_overload,
    output_dir,
    system_label,
    num_timesteps,
    NUM_SAMPLES,
    report_println,
)
    report_println("  Creating heatmaps...")

    # Heatmap 1: Overload count (samples × timesteps)
    heatmap_data_count = log10.(overload_count_matrix .+ 1)
    p1 = heatmap(
        1:num_timesteps,
        1:NUM_SAMPLES,
        heatmap_data_count,
        xlabel="Time Step",
        ylabel="Sample ID",
        title="Line Overload Count Heatmap\n($system_label)",
        colorbar_title="log10(Count+1)",
        color=:viridis,
        aspect_ratio=:auto,
        size=(1000, 600),
        left_margin=10Plots.mm,
        right_margin=10Plots.mm,
        top_margin=10Plots.mm,
        bottom_margin=10Plots.mm,
    )

    savefig(p1, joinpath(output_dir, "line_overload_count_heatmap.png"))
    report_println("    Saved: line_overload_count_heatmap.png")

    # Heatmap 2: Overload magnitude (samples × timesteps)
    heatmap_data_mag = log10.(overload_magnitude_matrix .+ 0.01)
    p2 = heatmap(
        1:num_timesteps,
        1:NUM_SAMPLES,
        heatmap_data_mag,
        xlabel="Time Step",
        ylabel="Sample ID",
        title="Line Overload Magnitude Heatmap\n($system_label)",
        colorbar_title="log10(MW+0.01)",
        color=:plasma,
        aspect_ratio=:auto,
        size=(1000, 600),
        left_margin=10Plots.mm,
        right_margin=10Plots.mm,
        top_margin=10Plots.mm,
        bottom_margin=10Plots.mm,
    )

    savefig(p2, joinpath(output_dir, "line_overload_magnitude_heatmap.png"))
    report_println("    Saved: line_overload_magnitude_heatmap.png")

    # Heatmap 3: Per-line overload count (top 30 lines × timesteps)
    line_total_counts = sum(line_timestep_matrix, dims=2)[:, 1]
    sorted_indices = sortperm(line_total_counts, rev=true)

    top_n_lines = min(30, length(line_overload.branch_names))
    top_line_indices = sorted_indices[1:top_n_lines]

    line_timestep_subset = line_timestep_matrix[top_line_indices, :]
    heatmap_data_line = log10.(line_timestep_subset .+ 1)

    p3 = heatmap(
        1:num_timesteps,
        1:top_n_lines,
        heatmap_data_line,
        xlabel="Time Step",
        ylabel="Line Index (sorted by count)",
        title="Per-Line Overload Count (Top $top_n_lines Lines)\n($system_label)",
        colorbar_title="log10(Count+1)",
        color=:thermal,
        aspect_ratio=:auto,
        size=(1000, 600),
        left_margin=10Plots.mm,
        right_margin=10Plots.mm,
        top_margin=10Plots.mm,
        bottom_margin=10Plots.mm,
    )

    savefig(p3, joinpath(output_dir, "line_overload_by_line_heatmap.png"))
    report_println("    Saved: line_overload_by_line_heatmap.png")

    # Heatmap 4: Per-line per-sample overload count
    line_sample_subset = line_sample_matrix[top_line_indices, :]
    heatmap_data_line_sample = log10.(line_sample_subset .+ 1)

    p4 = heatmap(
        1:NUM_SAMPLES,
        1:top_n_lines,
        heatmap_data_line_sample,
        xlabel="Sample ID",
        ylabel="Line Index (sorted by count)",
        title="Per-Line Per-Sample Overload Count (Top $top_n_lines Lines)\n($system_label)",
        colorbar_title="log10(Count+1)",
        color=:inferno,
        aspect_ratio=:auto,
        size=(1000, 600),
        left_margin=10Plots.mm,
        right_margin=10Plots.mm,
        top_margin=10Plots.mm,
        bottom_margin=10Plots.mm,
    )

    savefig(p4, joinpath(output_dir, "line_overload_by_line_sample_heatmap.png"))
    report_println("    Saved: line_overload_by_line_sample_heatmap.png")
end

"""
    plot_overload_distributions(...)

Plot distribution histograms and top line bar charts.
"""
function plot_overload_distributions(
    line_overload,
    sample_overload_count,
    output_dir,
    system_label,
    NUM_SAMPLES,
    report_println,
)
    report_println("  Creating distribution plots...")

    # Histogram of overload magnitudes
    p5 = histogram(
        line_overload.overload_mw,
        bins=50,
        xlabel="Overload Magnitude (MW over rating)",
        ylabel="Frequency",
        title="Distribution of Line Overload Magnitudes\n($system_label)",
        legend=false,
        color=:steelblue,
        alpha=0.7,
    )

    savefig(p5, joinpath(output_dir, "line_overload_magnitude_histogram.png"))
    report_println("    Saved: line_overload_magnitude_histogram.png")

    # Bar chart of top 15 most overloaded lines
    top_15_lines = SiennaPRASInterface.get_most_overloaded_lines(line_overload, 15)
    line_labels = [x[1] for x in top_15_lines]
    line_counts = [x[2] for x in top_15_lines]

    p6 = bar(
        line_labels,
        line_counts,
        xlabel="Transmission Line",
        ylabel="Overload Event Count",
        title="Top 15 Lines by Overload Frequency\n($system_label)",
        legend=false,
        color=:indianred,
        alpha=0.7,
        xrotation=45,
        size=(1000, 600),
        bottom_margin=15Plots.mm,
    )

    savefig(p6, joinpath(output_dir, "line_overload_top_lines.png"))
    report_println("    Saved: line_overload_top_lines.png")

    # Histogram of overloads per sample
    p7 = histogram(
        sample_overload_count,
        bins=50,
        xlabel="Number of Line Overloads per Sample",
        ylabel="Number of Samples",
        title="Distribution of Line Overloads per Sample\n($system_label)",
        legend=false,
        color=:teal,
        alpha=0.7,
    )

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

    savefig(p7, joinpath(output_dir, "line_overload_per_sample_histogram.png"))
    report_println("    Saved: line_overload_per_sample_histogram.png")

    # Line overload probability ranking
    top_15_lines = SiennaPRASInterface.get_most_overloaded_lines(line_overload, 15)
    line_names_prob = [x[1] for x in top_15_lines]
    line_probs = [
        100 * SiennaPRASInterface.line_overload_probability(line_overload, name) for
        name in line_names_prob
    ]

    p10 = bar(
        line_names_prob,
        line_probs,
        xlabel="Transmission Line",
        ylabel="Overload Probability (%)",
        title="Line Overload Probability (Top 15 Lines)\n($system_label)",
        legend=false,
        color=:coral,
        alpha=0.7,
        xrotation=45,
        size=(1000, 600),
        bottom_margin=15Plots.mm,
    )

    savefig(p10, joinpath(output_dir, "line_overload_probability.png"))
    report_println("    Saved: line_overload_probability.png")
end

"""
    plot_overload_correlations(...)

Plot correlations between overloads and unserved energy.
"""
function plot_overload_correlations(
    sample_overload_count,
    sample_max_overload,
    sample_eue,
    output_dir,
    system_label,
    report_println,
)
    report_println("  Creating correlation plots...")

    # Scatter: overload count vs EUE
    p8 = scatter(
        sample_overload_count,
        sample_eue,
        xlabel="Line Overloads per Sample (count)",
        ylabel="Unserved Energy per Sample (MWh)",
        title="Unserved Energy vs Line Overloads\n($system_label)",
        legend=false,
        color=:purple,
        alpha=0.5,
        markersize=4,
    )

    savefig(p8, joinpath(output_dir, "line_overload_vs_eue.png"))
    report_println("    Saved: line_overload_vs_eue.png")

    # Scatter: max overload magnitude vs EUE
    p9 = scatter(
        sample_max_overload,
        sample_eue,
        xlabel="Max Line Overload per Sample (MW)",
        ylabel="Unserved Energy per Sample (MWh)",
        title="Unserved Energy vs Max Line Overload\n($system_label)",
        legend=false,
        color=:orange,
        alpha=0.5,
        markersize=4,
    )

    savefig(p9, joinpath(output_dir, "line_overload_max_vs_eue.png"))
    report_println("    Saved: line_overload_max_vs_eue.png")
end

"""
    plot_overload_temporal(...)

Plot temporal patterns of line overloads.
"""
function plot_overload_temporal(
    line_overload,
    num_timesteps,
    output_dir,
    system_label,
    NUM_SAMPLES,
    report_println,
)
    report_println("  Creating temporal plots...")

    n_overloads = length(line_overload.overload_mw)

    # Time series: overload events per timestep
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
        title="Line Overload Events Over Time\n($system_label)",
        legend=false,
        color=:darkblue,
        linewidth=2,
        size=(1000, 500),
    )

    savefig(p11, joinpath(output_dir, "line_overload_temporal_count.png"))
    report_println("    Saved: line_overload_temporal_count.png")

    # Time series: average overload magnitude per timestep
    magnitude_per_timestep = zeros(Float64, num_timesteps)
    count_per_timestep = zeros(Int, num_timesteps)
    for i in 1:n_overloads
        t = line_overload.timestep[i]
        magnitude_per_timestep[t] += line_overload.overload_mw[i]
        count_per_timestep[t] += 1
    end

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
        title="Average Line Overload Magnitude Over Time\n($system_label)",
        legend=false,
        color=:darkred,
        linewidth=2,
        size=(1000, 500),
    )

    savefig(p12, joinpath(output_dir, "line_overload_temporal_magnitude.png"))
    report_println("    Saved: line_overload_temporal_magnitude.png")

    # Flow utilization distribution
    utilization_ratios = line_overload.flow_mw ./ line_overload.rating_mw

    p13 = histogram(
        utilization_ratios,
        bins=50,
        xlabel="Flow / Rating Ratio",
        ylabel="Frequency",
        title="Transmission Line Utilization During Overloads\n($system_label)",
        legend=false,
        color=:forestgreen,
        alpha=0.7,
    )

    vline!(p13, [1.0], linewidth=2, linestyle=:dash, color=:red, label="Rating Limit")

    savefig(p13, joinpath(output_dir, "line_overload_utilization.png"))
    report_println("    Saved: line_overload_utilization.png")
end
