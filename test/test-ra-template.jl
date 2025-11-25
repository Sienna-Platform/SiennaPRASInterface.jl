keys_to_names(
    x::Dict{PSY.Device, B},
) where {B <: SiennaPRASInterface.AbstractRAFormulation} = PSY.get_name.(collect(keys(x)))

@testset "RATemplate formulation construction" begin
    rts_da_sys =
        PSCB.build_system(PSCB.SPISystems, "RTS_GMLC_Hourly with Static Outage Data")
    load_names = PSY.get_name.(PSY.get_components(PSY.StaticLoad, rts_da_sys))
    generator_names =
        PSY.get_name.(
            PSY.get_components(
                PSY.get_available,
                Union{PSY.HydroDispatch, PSY.RenewableGen, PSY.ThermalGen},
                rts_da_sys,
            )
        )
    storage_names = PSY.get_name.(PSY.get_components(PSY.Storage, rts_da_sys))
    generatorstorage_names =
        PSY.get_name.(
            PSY.get_components(
                PSY.get_available,
                Union{PSY.HydroUnit, PSY.HybridSystem},
                rts_da_sys,
            )
        )

    problem_template = SiennaPRASInterface.RATemplate(
        PSY.Area,
        [
            SiennaPRASInterface.DeviceRAModel(
                PSY.StaticLoad,
                SiennaPRASInterface.StaticLoadPRAS(max_active_power="max_active_POWER"),
            ),
            SiennaPRASInterface.DeviceRAModel(
                PSY.ThermalGen,
                SiennaPRASInterface.GeneratorPRAS(max_active_power="max_active_POWER"),
            ),
            SiennaPRASInterface.DeviceRAModel(
                PSY.HydroDispatch,
                SiennaPRASInterface.GeneratorPRAS(max_active_power="max_active_POWER"),
            ),
            SiennaPRASInterface.DeviceRAModel(
                PSY.RenewableGen,
                SiennaPRASInterface.GeneratorPRAS(max_active_power="max_active_POWER"),
            ),
            SiennaPRASInterface.DeviceRAModel(
                PSY.EnergyReservoirStorage,
                SiennaPRASInterface.EnergyReservoirSoC(),
            ),
            SiennaPRASInterface.DeviceRAModel(
                PSY.HydroTurbine,
                SiennaPRASInterface.HydroEnergyReservoirPRAS(),
            ),
            SiennaPRASInterface.DeviceRAModel(
                PSY.HydroPumpTurbine,
                SiennaPRASInterface.HydroEnergyReservoirPRAS(),
            ),
        ],
    )
    # Test generator formulation building
    generator_to_pras = SiennaPRASInterface.build_component_to_formulation(
        GeneratorPRAS,
        rts_da_sys,
        problem_template.device_models,
    )
    @test generator_to_pras isa Dict{PSY.Device, GeneratorPRAS}
    @test test_names_equal(keys_to_names(generator_to_pras), generator_names)

    # Test storage formulation building
    storage_to_pras = SiennaPRASInterface.build_component_to_formulation(
        StoragePRAS,
        rts_da_sys,
        problem_template.device_models,
    )
    @test storage_to_pras isa Dict{PSY.Device, StoragePRAS}
    @test test_names_equal(keys_to_names(storage_to_pras), storage_names)

    # Test generatorstorage formulation building
    generatorstorage_to_pras = SiennaPRASInterface.build_component_to_formulation(
        GeneratorStoragePRAS,
        rts_da_sys,
        problem_template.device_models,
    )
    @test generatorstorage_to_pras isa Dict{PSY.Device, GeneratorStoragePRAS}
    @test test_names_equal(keys_to_names(generatorstorage_to_pras), generatorstorage_names)

    # Test load formulation building
    load_to_pras = SiennaPRASInterface.build_component_to_formulation(
        SiennaPRASInterface.StaticLoadPRAS,
        rts_da_sys,
        problem_template.device_models,
    )
    @test load_to_pras isa Dict{PSY.Device, SiennaPRASInterface.StaticLoadPRAS}
    @test test_names_equal(keys_to_names(load_to_pras), load_names)
end

@testset "RATemplate construction and manipulation" begin
    @testset "Creation and modification (with time-series-names)" begin
        device_models = [
            SiennaPRASInterface.DeviceRAModel(
                PSY.StaticLoad,
                SiennaPRASInterface.StaticLoadPRAS(max_active_power="max_active_POWER"),
            ),
            SiennaPRASInterface.DeviceRAModel(
                PSY.ThermalGen,
                SiennaPRASInterface.GeneratorPRAS,
            ),
            SiennaPRASInterface.DeviceRAModel(
                PSY.RenewableGen,
                SiennaPRASInterface.GeneratorPRAS,
                time_series_names=Dict(:max_active_power => "max_active_POWER"),
            ),
        ]
        @test device_models isa Vector{
            SiennaPRASInterface.DeviceRAModel{
                <:PSY.Device,
                <:SiennaPRASInterface.AbstractRAFormulation,
            },
        }
        template = SiennaPRASInterface.RATemplate(PSY.Area, device_models)
        @test template isa SiennaPRASInterface.RATemplate
        @test template.aggregation == PSY.Area
        @test template.device_models == device_models
        @test template.device_models isa Vector{SiennaPRASInterface.DeviceRAModel}

        # Test that we can add a device model
        @test_nowarn SiennaPRASInterface.set_device_model!(
            template,
            SiennaPRASInterface.DeviceRAModel(
                PSY.EnergyReservoirStorage,
                SiennaPRASInterface.EnergyReservoirSoC(),
            ),
        )
        @test length(template.device_models) == 4
    end
end
