# SiennaPRASInterface.jl

```@meta
CurrentModule = SiennaPRASInterface
```

## About

`SiennaPRASInterface.jl` is a [`Julia`](http://www.julialang.org) package that provides an interface to [`PRAS.jl`](https://nrel.github.io/PRAS) from [Sienna](https://www.nrel.gov/analysis/sienna.html)'s [`PowerSystem.jl`](https://github.com/Sienna-Platform/PowerSystems.jl)'s `System` data model.

The Probabilistic Resource Adequacy Suite (PRAS) analyzes the resource adequacy of a bulk power system using Monte Carlo methods.

## Getting Started

To use `SiennaPRASInterface.jl`, you first need a `System` from `PowerSystems.jl`

### 1. Install

```
] add SiennaPRASInterface
```

### 2. Add Data

Add outage information to generators using the supplemental attribute [`GeometricDistributionForcedOutage`](https://sienna-platform.github.io/PowerSystems.jl/stable/api/public/#PowerSystems.GeometricDistributionForcedOutage).

```julia
using PowerSystems
transition_data = GeometricDistributionForcedOutage(;
    mean_time_to_recovery=10,  # Units of hours
    outage_transition_probability=0.005,  # Probability for outage per hour
)
component = get_component(Generator, sys, "test_generator")
add_supplemental_attribute!(sys, component, transition_data)
```

### 3. Calculate Shortfalls and Expected Unserved Energy on System

```julia
using SiennaPRASInterface
sequential_monte_carlo = SequentialMonteCarlo(samples=10_000, seed=1)
shortfalls, = assess(sys, PowerSystems.Area, sequential_monte_carlo, Shortfall())
eue = EUE(shortfalls)
```

## Documentation

  - [PRAS Documentation](https://nrel.github.io/PRAS/)

```@contents
Pages = ["api/public.md", "tutorials"]
Depth = 2
```

* * *

SiennaPRASInterface has been developed as part of the Transmission Planning Tools Maintenance project at the U.S. Department of Energy's National Renewable Energy
Laboratory ([NREL](https://www.nrel.gov/)) funded by DOE Grid Deployment Office (GDO).
