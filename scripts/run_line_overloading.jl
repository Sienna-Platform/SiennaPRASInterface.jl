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

# Include helper modules
include("rts_gmlc.jl")
include("plots.jl")

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
# Save Results
#######################

report_println("="^80)
report_println("SAVING RESULTS")
report_println("="^80)
report_println()

save_simulation_results(output_dir; shortfall=shortfall, line_overload=line_overload)

#######################
# Generate Plots
#######################

report_println("="^80)
report_println("GENERATING VISUALIZATIONS")
report_println("="^80)
report_println()

system_label = "RTS-GMLC, $NUM_SAMPLES samples"

# Use plotting module to generate all plots
plot_line_overloads(
    line_overload,
    shortfall,
    output_dir,
    system_label,
    NUM_SAMPLES;
    report_println=report_println
)

report_println()
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
