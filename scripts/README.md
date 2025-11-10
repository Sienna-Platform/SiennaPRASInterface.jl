# RTS-GMLC Test Results Summary

## Test Configuration

- **Samples**: 1000 Monte Carlo samples per test
- **Random Seed**: 1234
- **System Variants**:
  - `unmodified`: Standard RTS-GMLC with 10% load increase
  - `modified`: Modified RTS-GMLC system
- **Disaggregation Methods**:
  - `proportional`: Distributes dispatch proportionally by capacity
  - `merit_order`: Dispatches cheapest generators first
  - `ramp_aware`: Dispatches most flexible generators first

## Ramp Violations Analysis

| System | Disaggregation | Total Violations | EUE (MWh) | Key Finding |
|--------|---------------|------------------|-----------|-------------|
| **Unmodified** | proportional | **0** | 29.76 | No violations detected |
| Unmodified | merit_order | 590,638 | 25.61 | Moderate violations |
| Unmodified | ramp_aware | 359,829 | 38.40 | Lower violations than merit |
| **Modified** | proportional | **29,805,913** | 133.16 | Highest violations |
| Modified | merit_order | 9,161,855 | 114.54 | 69% fewer than proportional |
| Modified | ramp_aware | 5,791,815 | 139.23 | **Lowest violations** (81% reduction) |

## Test Execution Statistics

- **Total Tests**: 12 (6 ramp violations + 6 line overloading)
- **Execution Time**: ~30-165 seconds per test
- **Power Flow Convergence**: 100% for all line overloading tests
- **Plots Generated**: ~8-13 plots per test
- **Results Directory**: `results/[analysis_type]/[system]_[disaggregation]/`