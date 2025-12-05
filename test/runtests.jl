using SiennaPRASInterface
using Test

import Aqua
import PowerSystems
import PowerSystemCaseBuilder
import CSV
import DataFrames
import Dates
import Test
import TimeSeries
using Dates: DateTime

const PSY = PowerSystems
const PSCB = PowerSystemCaseBuilder

include("comparison_utils.jl")

# Need to define this before PSCB changes are merged
function PSY.get_storage_capacity(res::PSY.HydroReservoir)
    return PSY.get_storage_level_limits(res).max
end

@testset "Aqua.jl" begin
    Aqua.test_unbound_args(SiennaPRASInterface)
    Aqua.test_undefined_exports(SiennaPRASInterface)
    Aqua.test_ambiguities(SiennaPRASInterface)
    Aqua.test_stale_deps(SiennaPRASInterface)
    Aqua.test_deps_compat(SiennaPRASInterface)
end

#=
Don't add your tests to runtests.jl. Instead, create files named

    test-title-for-my-test.jl

The file will be automatically included inside a `@testset` with title "Title For My Test".
=#
@testset "All tests" begin
    for (root, dirs, files) in walkdir(@__DIR__)
        for file in files
            if isnothing(match(r"^test.*\.jl$", file))
                continue
            end
            title = titlecase(replace(splitext(file[6:end])[1], "-" => " "))
            @testset "$title" begin
                include(file)
            end
        end
    end
end
