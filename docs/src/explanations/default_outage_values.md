# Default values used for outage statistics

When a system does not contain any `GeometricDistributionForcedOutage` supplemental attributes
attached to any components, then the outage rates default to a set of defaults defined
in the [Default Outage Rates CSV](https://github.com/Sienna-Platform/SiennaPRASInterface.jl/blob/main/src/util/descriptors/outage-rates-ERCOT-modified.csv) based off of rates in ERCOT.

For any remaining components not captured by the CSV defaults, such as lines,
renewables, and storage, the outage rates are 0 and will never fail.
