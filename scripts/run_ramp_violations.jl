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

# Include helper modules
include("rts_gmlc.jl")
include("plots.jl")

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

gen_counts = Dict{String, Int}()
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
# Save Results
#######################

report_println("="^80)
report_println("SAVING RESULTS")
report_println("="^80)
report_println()

save_simulation_results(output_dir; shortfall=shortfall, ramp_violations=ramp_violations)

#######################
# Generate Plots
#######################

report_println("="^80)
report_println("GENERATING PLOTS")
report_println("="^80)
report_println()

system_label = "RTS-GMLC $system_variant, $disaggregation_method, $NUM_SAMPLES samples"

# Use plotting module to generate all plots
plot_ramp_violations(
    ramp_violations,
    shortfall,
    output_dir,
    system_label,
    NUM_SAMPLES;
    gen_counts=gen_counts,
    report_println=report_println,
)

report_println()

report_println("="^80)
report_println("SIMULATION COMPLETE")
report_println("="^80)
report_println("Results and plots saved to: $output_dir")
report_println()

# Close report file
close(report_io)
