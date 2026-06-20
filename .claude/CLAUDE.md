# SiennaPRASInterface.jl — Claude Guide

Platform-wide Sienna conventions (performance, type stability, formatter, environments, code style) live in `.claude/Sienna.md` — read it too. This file is repo-specific and does not restate them.

## Purpose & place in the stack

SiennaPRASInterface (SPI) is the **interface layer between Sienna/PowerSystems.jl and PRAS — the Probabilistic Resource Adequacy Suite**. It:

1. Converts a PowerSystems.jl `System` into a PRAS `SystemModel` (`generate_pras_system`).
2. Runs resource-adequacy assessments via Monte Carlo / sequential simulation (`assess`), producing shortfall metrics such as `LOLE` (loss of load expectation), `EUE` (expected unserved energy), and `Shortfall`.
3. Converts assessment results back into the PowerSystems data model (e.g. writing worst-sample availability time series onto components, `generate_outage_profile!`).

This is **not** a JuMP optimization package. PRAS uses Monte Carlo / sequential simulation, not mathematical programming — there is no optimization-model construction layer here.

## Dependency on PRAS

SPI is a **thin interface ON TOP of PRAS**, NREL's Probabilistic Resource Adequacy Suite. PRAS is maintained **outside the Sienna-Platform org**, in NREL's repository at **https://github.com/NREL/PRAS**, and is the **source of truth for all adequacy math** (the `SystemModel` representation, the sequential Monte Carlo engine, and the reliability metrics). SPI does not reimplement any of it.

In `Project.toml` the PRAS components are pulled in as two modular packages of that suite:

- **`PRASCore`** (uuid `c5c32b99-e7c3-4530-a685-6f76e19f7fe2`), compat `0.7, 0.8` — provides `SystemModel`, `SequentialMonteCarlo`, `assess`, and all result/metric types (`Shortfall`, `LOLE`, `EUE`, `Surplus`, `Flow`, `Utilization`, the `*Samples` and `*Availability` variants, `val`, `stderror`).
- **`PRASFiles`** (uuid `a2806276-6d43-4ef5-91c0-491704cd7cf1`), compat `0.7, 0.8` — `.pras` file I/O (export of generated systems).

SPI **re-exports** these PRAS symbols from its own module (see the `import PRASCore: ...` block in `src/SiennaPRASInterface.jl`), so users get them via `using SiennaPRASInterface`. Implication: **changes to PRAS's `SystemModel` layout or assessment API ripple directly into this package.** When adequacy results look wrong, suspect PRAS semantics first; SPI only marshals data in and out. PRAS is unregistered in the General registry context historically — treat the compat bounds above as the contract.

## Architecture & `src/` layout

Module file `src/SiennaPRASInterface.jl` holds all exports, the PRAS imports/re-exports, the `include` order, and the three `assess(sys, ...)` PSY-system methods. Respect the include order when adding definitions.

- **`src/PowerSystems2PRAS.jl`** (~41 KB, the bulk of the package) — the PSY `System` → PRAS `SystemModel` conversion. Defines `generate_pras_system` (core method `(sys, template, export_location)`; convenience methods taking an `aggregation::Type{<:AggregationTopology}` or a JSON-path `String`), `add_default_data!`, the region/load/generator/storage/line matrix assembly, and the `DEFAULT_DEVICE_MODELS` / `_LUMPED_RENEWABLE_DEVICE_MODELS` / `DEFAULT_TEMPLATE` constants.
- **`src/PRAS2PowerSystems.jl`** — results → PSY. `generate_outage_profile!` (assess, then write the worst-shortfall-sample availability onto `GeometricDistributionForcedOutage` supplemental attributes), `add_asset_status!`.
- **`src/formulation_definitions.jl`** — the formulation/template type system: `AbstractRAFormulation` and concretes (`GeneratorPRAS`, `StoragePRAS`/`EnergyReservoirSoC`, `GeneratorStoragePRAS`/`HybridSystemPRAS`/`HydroEnergyReservoirPRAS`, `LinePRAS`, `InterfacePRAS`/`AreaInterchangeLimit`, `LoadPRAS`/`StaticLoadPRAS`), the `DeviceRAModel{D,B}` (Sienna device type → formulation, analogous to PowerSimulations' `DeviceModel`), `RATemplate{T<:AggregationTopology}`, and `set_device_model!`.
- **`src/util/`** — `definitions.jl` (`OUTAGE_INFO_FILE`, `TransformerTypes`, `DEFAULT_OUTAGE_DATA_SUPP_ATTR`); `descriptors/` (ERCOT default outage-rate CSV, CC restrictions JSON); `parsing/` (metadata `S2P_metadata`, lines/interfaces, outage-data helpers, `.pras` export, result-export helpers incl. `SPIOutageResult`); `draws/` (RNG-based outage draws); `sienna/helper_functions.jl`; `runchecks.jl`.

## Main public API / entry points (verified exports)

- `generate_pras_system(sys, aggregation | template | sys_json_path; ...)` → `PRASCore.SystemModel`.
- `assess(sys, method, resultspecs...)`, `assess(sys, template, method, resultspecs...)`, `assess(sys, aggregation, method, resultspecs...)` — these PSY-system methods are added by SPI; they call `generate_pras_system` then delegate to `PRASCore.assess`.
- Template construction: `RATemplate`, `DeviceRAModel`, `set_device_model!`, and the formulation types listed above.
- Result specs / metrics (re-exported from PRASCore): `Shortfall`, `ShortfallSamples`, `Surplus`, `Flow`, `Utilization`, `StorageEnergy`, `GeneratorStorageEnergy`, the `*Availability` family, `LOLE`, `EUE`; accessors `val`, `stderror`.
- Back-conversion: `generate_outage_profile!`, `make_generator_outage_draws!`.
- `SPIOutageResult` (internal, not exported) structures the assessment result tuple for `add_asset_status!`.

## Conventions & gotchas

- **Component → PRAS mapping is table-driven** via `DeviceRAModel` entries in a `RATemplate`. PRAS is **area-based**: the template's `aggregation` (`PSY.Area` by default, or `PSY.LoadZone`) defines PRAS regions. `device_models` are processed in **reverse order — later models take precedence** (last-applied wins; a `@warn` fires on overlap). Default mappings: thermal/renewable/hydro-dispatch → `GeneratorPRAS`; `EnergyReservoirStorage` → `EnergyReservoirSoC`; `HybridSystem` → `HybridSystemPRAS`; hydro turbines → `HydroEnergyReservoirPRAS`; lines/HVDC → `LinePRAS`; load → `StaticLoadPRAS`.
- **Renewable lumping:** `lump_region_renewable_gens=true` (or `GeneratorPRAS(lump_renewable_generation=true)`) aggregates renewables into the region because they often lack FOR data. `filter_component_to_formulation` decides lumped vs. non-lumped based on presence/zeroing of `GeometricDistributionForcedOutage`.
- **Outage-rate handling:** outage data lives on PSY `GeometricDistributionForcedOutage` supplemental attributes (`outage_transition_probability` λ, `mean_time_to_recovery` μ). When a component has none and `add_default_transition_probabilities` is set, defaults come from the ERCOT CSV (`OUTAGE_INFO_FILE`) via `add_default_data!`, or the global `DEFAULT_OUTAGE_DATA_SUPP_ATTR` (5% FOR, 24 h MTTR). Rates are converted with `rate_to_probability`.
- **Time series:** formulations reference time series **by name** (defaults `"max_active_power"`, `"inflow"`, `"storage_capacity"`, `"outage_probability"`, `"recovery_probability"`). The PRAS horizon/resolution is derived from PSY's static time-series summary (`S2P_metadata`). The system is coerced to `NATURAL_UNITS` during conversion.
- **RNG / reproducibility:** outage draws use **Random123** — a module-level `rng = Random123.Philox4x((0,0), 10)` in `src/util/draws/sienna_draws.jl`. This is shared mutable state; runs are reproducible only for the seeded sequence. Be wary of cross-test contamination from this global counter-based RNG.
- **Upstream coupling:** SPI sits on **PowerSystems** (`~5`) and **InfrastructureSystems** (`~3`); it leans heavily on PSY component types, supplemental attributes, and time-series APIs. Upstream renames (component types, getters, supplemental-attribute API) break the conversion paths in `PowerSystems2PRAS.jl`.

## Running tests, docs, formatter (verified commands)

Formatter (run before reporting any task done; self-activates its own env):

```sh
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'
```

Tests — `test/runtests.jl` runs an Aqua testset, then **auto-includes every `test/test-*.jl` file** inside a titled `@testset` (do not add tests to `runtests.jl`; create a new `test-<title>.jl` file). Test deps (incl. `PowerSystemCaseBuilder`, `Aqua`) live in `test/Project.toml`:

```sh
julia --project=test -e 'using Pkg; Pkg.instantiate()'   # first time
julia --project=test test/runtests.jl                    # full suite
```

There is no single-file CLI selector built into the runner; to run one file in isolation, `include` it from a `--project=test` REPL after `using SiennaPRASInterface, Test`.

Docs (`docs/make.jl` is currently `warnonly=true`):

```sh
julia --project=docs -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()'   # first time
julia --project=docs docs/make.jl
```
