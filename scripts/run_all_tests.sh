#!/bin/bash

#############################################################################
# RTS-GMLC Comprehensive Test Suite
#
# This script runs all combinations of:
# - System variants: unmodified (with 10% load increase), modified
# - Disaggregation methods: proportional, merit_order, ramp_aware
# - Analysis types: ramp violations, line overloading
#
# Results are organized in the results/ directory by analysis type,
# system variant, and disaggregation method.
#
# Usage:
#   ./scripts/run_all_tests.sh
#
# Options:
#   Set NUM_THREADS to control parallelism (default: auto):
#   NUM_THREADS=8 ./scripts/run_all_tests.sh
#############################################################################

set -e  # Exit on error

# Configuration
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPTS_DIR")"
RESULTS_DIR="$REPO_DIR/results"

# Use environment variable or default to auto
NUM_THREADS="${NUM_THREADS:-auto}"

# Test configurations
SYSTEMS=("unmodified" "modified")
DISAGGREGATION_METHODS=("proportional" "merit_order" "ramp_aware")

echo "=============================================================================="
echo "RTS-GMLC Comprehensive Test Suite"
echo "=============================================================================="
echo "Repository directory: $REPO_DIR"
echo "Scripts directory: $SCRIPTS_DIR"
echo "Results directory: $RESULTS_DIR"
echo "Julia threads: $NUM_THREADS"
echo ""
echo "System variants: ${SYSTEMS[*]}"
echo "Disaggregation methods: ${DISAGGREGATION_METHODS[*]}"
echo ""
echo "Total tests: $((2 * ${#SYSTEMS[@]} * ${#DISAGGREGATION_METHODS[@]}))"
echo "  - Ramp violations: $((${#SYSTEMS[@]} * ${#DISAGGREGATION_METHODS[@]}))"
echo "  - Line overloading: $((${#SYSTEMS[@]} * ${#DISAGGREGATION_METHODS[@]}))"
echo "=============================================================================="
echo ""

# Create results directory
mkdir -p "$RESULTS_DIR"

# Track timing
START_TIME=$(date +%s)
TEST_COUNT=0
TOTAL_TESTS=$((2 * ${#SYSTEMS[@]} * ${#DISAGGREGATION_METHODS[@]}))

#############################################################################
# Function to run a single test
#############################################################################
run_test() {
    local script=$1
    local system=$2
    local disagg=$3
    local output_dir=$4
    local test_name=$5

    TEST_COUNT=$((TEST_COUNT + 1))

    echo ""
    echo "=========================================================================="
    echo "Test $TEST_COUNT/$TOTAL_TESTS: $test_name"
    echo "=========================================================================="
    echo "Script: $script"
    echo "System: $system"
    echo "Disaggregation: $disagg"
    echo "Output: $output_dir"
    echo "Started: $(date)"
    echo ""

    local test_start=$(date +%s)

    # Run the test
    julia --project="$SCRIPTS_DIR" --threads="$NUM_THREADS" \
        "$SCRIPTS_DIR/$script" "$system" "$disagg" "$output_dir"

    local test_end=$(date +%s)
    local test_duration=$((test_end - test_start))

    echo ""
    echo "Completed in: ${test_duration}s"
    echo "=========================================================================="
}

#############################################################################
# Run Ramp Violation Tests
#############################################################################
echo ""
echo "##########################################################################"
echo "# RAMP VIOLATION TESTS"
echo "##########################################################################"
echo ""

for system in "${SYSTEMS[@]}"; do
    for disagg in "${DISAGGREGATION_METHODS[@]}"; do
        output_dir="$RESULTS_DIR/ramp_violations/${system}_${disagg}"
        test_name="Ramp Violations - $system - $disagg"

        run_test "run_ramp_violations.jl" "$system" "$disagg" "$output_dir" "$test_name"
    done
done

#############################################################################
# Run Line Overloading Tests
#############################################################################
echo ""
echo "##########################################################################"
echo "# LINE OVERLOADING TESTS"
echo "##########################################################################"
echo ""

for system in "${SYSTEMS[@]}"; do
    for disagg in "${DISAGGREGATION_METHODS[@]}"; do
        output_dir="$RESULTS_DIR/line_overloading/${system}_${disagg}"
        test_name="Line Overloading - $system - $disagg"

        run_test "run_line_overloading.jl" "$system" "$disagg" "$output_dir" "$test_name"
    done
done

#############################################################################
# Summary
#############################################################################
END_TIME=$(date +%s)
TOTAL_DURATION=$((END_TIME - START_TIME))
HOURS=$((TOTAL_DURATION / 3600))
MINUTES=$(((TOTAL_DURATION % 3600) / 60))
SECONDS=$((TOTAL_DURATION % 60))

echo ""
echo "=============================================================================="
echo "TEST SUITE COMPLETE"
echo "=============================================================================="
echo "Completed: $(date)"
echo "Total tests: $TOTAL_TESTS"
echo "Total duration: ${HOURS}h ${MINUTES}m ${SECONDS}s"
echo ""
echo "Results directory structure:"
echo "$RESULTS_DIR/"
echo "├── ramp_violations/"
for system in "${SYSTEMS[@]}"; do
    for disagg in "${DISAGGREGATION_METHODS[@]}"; do
        echo "│   ├── ${system}_${disagg}/"
        echo "│   │   ├── report.txt"
        echo "│   │   └── *.png"
    done
done
echo "└── line_overloading/"
for system in "${SYSTEMS[@]}"; do
    for disagg in "${DISAGGREGATION_METHODS[@]}"; do
        echo "    ├── ${system}_${disagg}/"
        echo "    │   ├── report.txt"
        echo "    │   └── *.png"
    done
done
echo ""
echo "=============================================================================="
