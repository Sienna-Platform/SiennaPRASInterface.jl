# TODO: OUTAGE_INFO FILE: this should probably be an artifact 
"""
    DEFAULT outage data which is used when outage_flag is set to FALSE

Based on ERCOT historical data
"""
const OUTAGE_INFO_FILE =
    joinpath(@__DIR__, "descriptors", "outage-rates-ERCOT-modified.csv")

"""
    Filtered Transformer Types

These transformers are not modeled as lines in PRAS.
"""
const TransformerTypes =
    [PSY.TapTransformer, PSY.Transformer2W, PSY.PhaseShiftingTransformer]

"""
Default GeometricDistributionForcedOutage SupplementalAttributes

This will be added to the component for which no outage data is provided.
"""
λ_default, μ_default = rate_to_probability(0.05, 24) # %% FOR and 24hr MTTR
const DEFAULT_OUTAGE_DATA_SUPP_ATTR = PSY.GeometricDistributionForcedOutage(
    mean_time_to_recovery=24,
    outage_transition_probability=λ_default,
)
