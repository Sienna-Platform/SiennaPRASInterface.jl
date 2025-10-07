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
