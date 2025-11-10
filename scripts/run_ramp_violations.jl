#!/usr/bin/env julia

"""
RTS-GMLC Ramp Violations Analysis Script

This script runs a comprehensive resource adequacy assessment on the RTS-GMLC system
using Monte Carlo simulation with multi-threading. It tracks:
- Shortfall events and probabilities
- Expected Unserved Energy (EUE)
- Ramp constraint violations with configurable disaggregation methods

Results are visualized using Plots.jl and saved to the specified output directory.

Usage:
    julia --project=scripts --threads=auto scripts/run_ramp_violations.jl <system> <disaggregation> <output_dir>

Arguments:
    system          - System variant: "unmodified" or "modified" (default: "modified")
    disaggregation  - Disaggregation method: "proportional", "merit_order", or "ramp_aware" (default: "ramp_aware")
    output_dir      - Output directory for plots and reports (default: "results/ramp_violations")

Examples:
    julia --project=scripts --threads=auto scripts/run_ramp_violations.jl unmodified proportional results/ramp_unmodified_proportional
    julia --project=scripts --threads=auto scripts/run_ramp_violations.jl modified merit_order results/ramp_modified_merit
    julia --project=scripts --threads=auto scripts/run_ramp_violations.jl modified ramp_aware results/ramp_modified_ramp_aware
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
# Parse CLI Arguments
#######################

function parse_arguments()
    # Default values
    system_variant = "modified"
    disaggregation_method = "ramp_aware"
    output_dir = "results/ramp_violations"

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

#######################
# Simulation Parameters
#######################

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
report_println("RTS-GMLC Ramp Violations Analysis")
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
report_println("  System type: $(use_modified ? "modified" : "unmodified") RTS-GMLC")
report_println()

#######################
# Set Up Simulation
#######################

report_println("Setting up Monte Carlo simulation...")

# Create Monte Carlo method with threading
method = SequentialMonteCarlo(; samples=NUM_SAMPLES, seed=RANDOM_SEED)

# Get disaggregation function
disagg_func = get_disaggregation_function(disaggregation_method, sys)

# Create result specifications
ramp_spec = RampViolations(sys; disaggregation_func=disagg_func)

report_println("Simulation configured:")
report_println("  Method: Sequential Monte Carlo")
report_println("  Aggregation: By Area")
report_println("  Disaggregation: $disaggregation_method")
report_println()

#######################
# Run Assessment
#######################

report_println("Running resource adequacy assessment...")
report_println()

start_time = time()
shortfall, ramp_violations = assess(sys, PSY.Area, method, ShortfallSamples(), ramp_spec)
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

report_println("Loss of Load Expectation (LOLE): $(round(lole, digits=4)) events/period")
report_println("Expected Unserved Energy (EUE): $(round(eue_val, digits=2)) MWh")
report_println()

# Ramp violation metrics
violations = ramp_violations.ramp_violation.value
n_violations = length(violations)
report_println("Ramp Violations:")
report_println("  Total violations: $n_violations")

if n_violations > 0
    max_violation = maximum(abs.(violations))
    mean_violation = mean(abs.(violations))
    median_violation = median(abs.(violations))

    report_println("  Maximum violation: $(round(max_violation, digits=4)) MW/min")
    report_println("  Mean violation: $(round(mean_violation, digits=4)) MW/min")
    report_println("  Median violation: $(round(median_violation, digits=4)) MW/min")

    # Count violations per sample
    sample_ids = ramp_violations.ramp_violation.sampleid
    samples_with_violations = length(unique(sample_ids))
    report_println("  Samples with violations: $samples_with_violations / $NUM_SAMPLES")

    # Top 5 generators with most violations
    gen_indices = ramp_violations.ramp_violation.idx
    gen_names = ramp_violations.generators
    gen_counts = Dict{String, Int}()
    for idx in gen_indices
        gen_name = gen_names[idx]
        gen_counts[gen_name] = get(gen_counts, gen_name, 0) + 1
    end

    report_println()
    report_println("  Top 5 generators with violations:")
    sorted_gens = sort(collect(gen_counts), by=x -> x[2], rev=true)
    for (i, (gen, count)) in enumerate(sorted_gens[1:min(5, length(sorted_gens))])
        report_println("    $i. $gen: $count violations")
    end
else
    report_println("  No ramp violations detected!")
end
report_println()

#######################
# Generate Plots
#######################

report_println("="^80)
report_println("GENERATING PLOTS")
report_println("="^80)
report_println()

# Set plot defaults for publication quality
default(; size=(800, 600), dpi=300, legendfontsize=10, guidefontsize=12, tickfontsize=10)

if n_violations > 0
    # Plot 1: Histogram of violation magnitudes
    report_println("Creating histogram of ramp violation magnitudes...")
    abs_violations = abs.(violations)

    p1 = histogram(
        abs_violations,
        bins=50,
        xlabel="Violation Magnitude (MW/min)",
        ylabel="Frequency",
        title="Distribution of Ramp Violations\n(RTS-GMLC $system_variant, $disaggregation_method, $NUM_SAMPLES samples)",
        legend=false,
        color=:steelblue,
        alpha=0.7,
    )

    histogram_file = joinpath(output_dir, "ramp_violations_histogram.png")
    savefig(p1, histogram_file)
    report_println("  Saved: $histogram_file")

    # Plot 2a: Heatmap of violation counts (samples × timesteps)
    report_println("Creating heatmap of violation counts...")

    # Extract data from sparse accumulator
    sample_ids = ramp_violations.ramp_violation.sampleid
    timesteps = ramp_violations.ramp_violation.time
    violations_values = ramp_violations.ramp_violation.value

    # Determine dimensions
    num_timesteps = maximum(timesteps)
    num_samples = NUM_SAMPLES

    # Build violation count matrix (samples × timesteps)
    violation_count_matrix = zeros(Int, num_samples, num_timesteps)
    for i in 1:length(sample_ids)
        s = sample_ids[i]
        t = timesteps[i]
        violation_count_matrix[s, t] += 1
    end

    # Create heatmap with log scale
    heatmap_data = log10.(violation_count_matrix .+ 1)
    p2a = heatmap(
        1:num_timesteps,
        1:num_samples,
        heatmap_data,
        xlabel="Time Step",
        ylabel="Sample ID",
        title="Ramp Violations Count Heatmap\n(RTS-GMLC $system_variant, $disaggregation_method, $NUM_SAMPLES samples)",
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
    report_println("  Saved: $count_heatmap_file")

    # Plot 2b: Heatmap of total violation magnitude
    report_println("Creating heatmap of violation magnitudes...")

    violation_magnitude_matrix = zeros(Float64, num_samples, num_timesteps)
    for i in 1:length(sample_ids)
        s = sample_ids[i]
        t = timesteps[i]
        violation_magnitude_matrix[s, t] += abs(violations_values[i])
    end

    magnitude_heatmap_data = log10.(violation_magnitude_matrix .+ 0.01)
    p2b = heatmap(
        1:num_timesteps,
        1:num_samples,
        magnitude_heatmap_data,
        xlabel="Time Step",
        ylabel="Sample ID",
        title="Ramp Violations Magnitude Heatmap\n(RTS-GMLC $system_variant, $disaggregation_method, $NUM_SAMPLES samples)",
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
    report_println("  Saved: $magnitude_heatmap_file")

    # Plot 3: Top 10 generators by violation count
    report_println("Creating bar plot of top generators...")
    sorted_gens = sort(collect(gen_counts), by=x -> x[2], rev=true)
    top_10 = sorted_gens[1:min(10, length(sorted_gens))]

    gen_labels = [x[1] for x in top_10]
    gen_violation_counts = [x[2] for x in top_10]

    p3 = bar(
        gen_labels,
        gen_violation_counts,
        xlabel="Generator",
        ylabel="Violation Count",
        title="Top 10 Generators by Ramp Violations\n(RTS-GMLC $system_variant, $disaggregation_method, $NUM_SAMPLES samples)",
        legend=false,
        color=:indianred,
        alpha=0.7,
        xrotation=45,
    )

    generators_file = joinpath(output_dir, "ramp_violations_generators.png")
    savefig(p3, generators_file)
    report_println("  Saved: $generators_file")
else
    report_println("No violations to plot!")
end

# Plot 4: Per-sample Lost Load vs Ramp Violations
report_println("Creating per-sample correlation plot...")

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
    title="Lost Load vs Ramp Violations\n(RTS-GMLC $system_variant, $disaggregation_method, $NUM_SAMPLES samples)",
    legend=false,
    color=:purple,
    alpha=0.5,
    markersize=4,
)

correlation_file = joinpath(output_dir, "lostload_vs_ramp_violations.png")
savefig(p4, correlation_file)
report_println("  Saved: $correlation_file")

# Plot 4b: Per-sample Lost Load vs Total Ramp Violation Magnitude
report_println("Creating magnitude correlation plot...")

sample_ramp_magnitude = zeros(Float64, NUM_SAMPLES)
if n_violations > 0
    for i in 1:n_violations
        sample_id = ramp_violations.ramp_violation.sampleid[i]
        sample_ramp_magnitude[sample_id] += abs(violations[i])
    end
end

p4b = scatter(
    sample_ramp_magnitude,
    sample_eue,
    xlabel="Total Ramp Violation Magnitude per Sample (MW/min)",
    ylabel="Unserved Energy per Sample (MWh)",
    title="Lost Load vs Ramp Violation Magnitude\n(RTS-GMLC $system_variant, $disaggregation_method, $NUM_SAMPLES samples)",
    legend=false,
    color=:orange,
    alpha=0.5,
    markersize=4,
)

magnitude_correlation_file = joinpath(output_dir, "lostload_vs_ramp_magnitude.png")
savefig(p4b, magnitude_correlation_file)
report_println("  Saved: $magnitude_correlation_file")

# Compute and print correlation statistics
if n_violations > 0
    report_println()
    report_println("Correlation Analysis:")

    # Correlation between violation count and EUE
    nonzero_mask = (sample_ramp_count .> 0) .| (sample_eue .> 0)
    if sum(nonzero_mask) > 1
        count_eue_corr = cor(sample_ramp_count[nonzero_mask], sample_eue[nonzero_mask])
        report_println(
            "  Correlation (violation count vs EUE): $(round(count_eue_corr, digits=3))",
        )
    end

    # Correlation between violation magnitude and EUE
    if sum(sample_ramp_magnitude .> 0) > 1
        mag_nonzero_mask = (sample_ramp_magnitude .> 0) .| (sample_eue .> 0)
        mag_eue_corr =
            cor(sample_ramp_magnitude[mag_nonzero_mask], sample_eue[mag_nonzero_mask])
        report_println(
            "  Correlation (violation magnitude vs EUE): $(round(mag_eue_corr, digits=3))",
        )
    end

    # Samples with low violations but high EUE
    low_violation_threshold = quantile(sample_ramp_magnitude, 0.25)
    high_eue_threshold = quantile(sample_eue[sample_eue .> 0], 0.75)
    low_viol_high_eue = sum(
        (sample_ramp_magnitude .<= low_violation_threshold) .&
        (sample_eue .>= high_eue_threshold),
    )
    report_println("  Samples with low violations but high EUE: $low_viol_high_eue")
    report_println("    (This may indicate outages reducing violations)")

    # Identify samples with notably fewer violations
    total_violations_per_sample = sum(violation_count_matrix, dims=2)[:, 1]
    median_violations =
        median(total_violations_per_sample[total_violations_per_sample .> 0])
    low_violation_samples = findall(total_violations_per_sample .< median_violations)

    report_println(
        "  Median violations per sample (excluding zeros): $(round(median_violations, digits=1))",
    )
    report_println(
        "  Samples below median (potential 'dark streaks'): $(length(low_violation_samples)) of $NUM_SAMPLES",
    )

    # Check if low-violation samples have different EUE patterns
    if length(low_violation_samples) > 0
        avg_eue_low_viol = mean(sample_eue[low_violation_samples])
        avg_eue_all = mean(sample_eue)
        report_println(
            "  Average EUE for low-violation samples: $(round(avg_eue_low_viol, digits=2)) MWh",
        )
        report_println("  Average EUE for all samples: $(round(avg_eue_all, digits=2)) MWh")
        if avg_eue_low_viol > avg_eue_all * 1.2
            report_println(
                "  → Low-violation samples have 20%+ higher EUE (outages likely reducing violations)",
            )
        elseif avg_eue_low_viol < avg_eue_all * 0.8
            report_println(
                "  → Low-violation samples have 20%+ lower EUE (favorable load patterns likely)",
            )
        else
            report_println("  → Similar EUE between low and normal violation samples")
        end
    end
    report_println()

    # Timestep-level outage analysis
    report_println("="^60)
    report_println("TIMESTEP-LEVEL OUTAGE ANALYSIS")
    report_println("="^60)

    # Count outages per timestep across all samples
    outages_per_timestep = zeros(Int, num_timesteps, NUM_SAMPLES)
    if hasfield(typeof(ramp_violations), :generator_unavailability)
        gen_unavail = ramp_violations.generator_unavailability
        for i in 1:length(gen_unavail.sampleid)
            s = gen_unavail.sampleid[i]
            t = gen_unavail.time[i]
            outages_per_timestep[t, s] += 1
        end
    end

    timestep_outage_counts = vec(outages_per_timestep)
    timestep_violation_counts = vec(violation_count_matrix')

    # Separate into categories
    no_outage_mask = timestep_outage_counts .== 0
    has_outage_mask = timestep_outage_counts .> 0
    heavy_outage_mask = timestep_outage_counts .>= 3

    if sum(has_outage_mask) > 0
        avg_viol_no_outage = mean(timestep_violation_counts[no_outage_mask])
        avg_viol_with_outage = mean(timestep_violation_counts[has_outage_mask])

        report_println("Timestep-level statistics:")
        report_println(
            "  Average violations when NO outages: $(round(avg_viol_no_outage, digits=2))",
        )
        report_println(
            "  Average violations when outages occur: $(round(avg_viol_with_outage, digits=2))",
        )
        report_println(
            "  Difference: $(round(avg_viol_no_outage - avg_viol_with_outage, digits=2)) violations",
        )

        pct_change = 100 * (avg_viol_with_outage - avg_viol_no_outage) / avg_viol_no_outage
        report_println("  Percent change: $(round(pct_change, digits=1))%")

        if pct_change < -5
            report_println("  → Outages REDUCE violations by >5% (confirms hypothesis!)")
        elseif pct_change > 5
            report_println("  → Outages INCREASE violations by >5%")
        else
            report_println("  → Outages have minimal effect on violations")
        end

        if sum(heavy_outage_mask) > 10
            avg_viol_heavy = mean(timestep_violation_counts[heavy_outage_mask])
            report_println(
                "  Average violations when 3+ outages: $(round(avg_viol_heavy, digits=2))",
            )
        end

        # Correlation between outage count and violation count
        if sum(has_outage_mask) > 10
            outage_viol_corr = cor(timestep_outage_counts, timestep_violation_counts)
            report_println(
                "  Correlation (outages vs violations at timestep level): $(round(outage_viol_corr, digits=3))",
            )
        end

        # Check violation magnitude
        timestep_violation_magnitude = vec(violation_magnitude_matrix')
        avg_mag_no_outage = mean(timestep_violation_magnitude[no_outage_mask])
        avg_mag_with_outage = mean(timestep_violation_magnitude[has_outage_mask])

        report_println("\nViolation magnitude analysis:")
        report_println(
            "  Average magnitude when NO outages: $(round(avg_mag_no_outage, digits=2)) MW/min",
        )
        report_println(
            "  Average magnitude when outages occur: $(round(avg_mag_with_outage, digits=2)) MW/min",
        )
        mag_pct_change = 100 * (avg_mag_with_outage - avg_mag_no_outage) / avg_mag_no_outage
        report_println("  Percent change: $(round(mag_pct_change, digits=1))%")

        # Check if outages correlate with unserved energy
        report_println("\nChecking if outages → unserved energy:")

        shortfall_data = shortfall.shortfall
        system_shortfall = dropdims(sum(shortfall_data, dims=1), dims=1)
        timestep_shortfall = vec(system_shortfall')

        avg_shortfall_no_outage = mean(timestep_shortfall[no_outage_mask])
        avg_shortfall_with_outage = mean(timestep_shortfall[has_outage_mask])

        report_println(
            "  Average shortfall when NO outages: $(round(avg_shortfall_no_outage, digits=2)) MW",
        )
        report_println(
            "  Average shortfall when outages occur: $(round(avg_shortfall_with_outage, digits=2)) MW",
        )

        if avg_shortfall_with_outage > avg_shortfall_no_outage * 1.5
            report_println("  → Outages cause 50%+ more unserved energy")
            report_println(
                "  → Hypothesis: Reduced dispatch → less ramping needed → fewer violations",
            )
        else
            report_println("  → Unserved energy doesn't explain the violation reduction")
        end

        # Correlation between outages and shortfall
        if sum(timestep_shortfall .> 0) > 10
            outage_shortfall_corr = cor(timestep_outage_counts, timestep_shortfall)
            report_println(
                "  Correlation (outages vs shortfall): $(round(outage_shortfall_corr, digits=3))",
            )
        end

        report_println("\nHypothesis check:")
        report_println("  If outages preferentially remove inflexible generators,")
        report_println("  then remaining generators are more flexible on average,")
        report_println("  leading to fewer violations even with similar dispatch levels.")
        report_println()
        report_println("  Key insight: PRAS regional dispatch accounts for outages")
        report_println("  by reducing available capacity. The disaggregation then")
        report_println("  distributes dispatch among remaining (potentially more flexible)")
        report_println("  generators, and the offline generator can't violate constraints.")
    end
    report_println()
end

# Plot 5: Distribution of violations per sample
report_println("Creating histogram of violations per sample...")

samples_with_viols = sample_ramp_count[sample_ramp_count .> 0]

p5 = histogram(
    sample_ramp_count,
    bins=50,
    xlabel="Number of Ramp Violations per Sample",
    ylabel="Number of Samples",
    title="Distribution of Ramp Violations per Sample\n(RTS-GMLC $system_variant, $disaggregation_method, $NUM_SAMPLES samples)",
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
report_println("  Saved: $sample_dist_file")

report_println()
report_println("="^80)
report_println("SIMULATION COMPLETE")
report_println("="^80)
report_println("Results and plots saved to: $output_dir")
report_println()

# Close report file
close(report_io)
