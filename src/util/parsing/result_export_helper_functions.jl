const OUTAGE_RESULT_SPEC = PRASCore.Results.ResultSpec[
    ShortfallSamples(),
    GeneratorAvailability(),
    StorageAvailability(),
    GeneratorStorageAvailability(),
    SurplusSamples()
]

"""
Get DeviceRAModel for PRAS AbstractAvailabilityResult
"""
function get_device_ramodel(
    ::Type{T},
) where {T <: PRASCore.Results.GeneratorAvailabilityResult}
    return (model=GeneratorPRAS, key=:generators)
end

"""
Get DeviceRAModel for PRAS AbstractAvailabilityResult
"""
function get_device_ramodel(
    ::Type{T},
) where {T <: PRASCore.Results.StorageAvailabilityResult}
    return (model=StoragePRAS, key=:storages)
end

"""
Get DeviceRAModel for PRAS AbstractAvailabilityResult
"""
function get_device_ramodel(
    ::Type{T},
) where {T <: PRASCore.Results.GeneratorStorageAvailabilityResult}
    return (model=GeneratorStoragePRAS, key=:generatorstorages)
end

"""
    SPIOutageResult(; shortfall_samples, gen_availability, stor_availability, gen_stor_availability)

# Arguments
$(TYPEDFIELDS)

SPIOutageResult is used to parse Tuple{Vararg{PRAS.PRASCore.Results.Result}} and add structure to it.
"""
struct SPIOutageResult
    "Shortfall Sample Result"
    shortfall_samples::PRASCore.Results.ShortfallSamplesResult
    "Generator Availability Result"
    gen_availability::PRASCore.Results.GeneratorAvailabilityResult
    "Storage Availability Result"
    stor_availability::PRASCore.Results.StorageAvailabilityResult
    "GeneratorStorage Availability Result"
    gen_stor_availability::PRASCore.Results.GeneratorStorageAvailabilityResult
    "Surplus Sample Result"
    surplus_samples::PRASCore.Results.SurplusSamplesResult
end

function SPIOutageResult(results::T) where {T <: Tuple{Vararg{PRASCore.Results.Result}}}
    SPIOutageResult(results...)
end
