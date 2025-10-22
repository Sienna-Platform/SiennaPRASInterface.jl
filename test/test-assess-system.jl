function test_shortfalls(shortfalls)
    @test shortfalls isa SiennaPRASInterface.PRASCore.Results.ShortfallResult

    lole = SiennaPRASInterface.LOLE(shortfalls)
    eue = SiennaPRASInterface.EUE(shortfalls)
    @test lole isa SiennaPRASInterface.PRASCore.ReliabilityMetric
    @test eue isa SiennaPRASInterface.PRASCore.ReliabilityMetric
    @test SiennaPRASInterface.val(lole) >= 0 && SiennaPRASInterface.val(lole) <= 10
    @test SiennaPRASInterface.stderror(lole) >= 0 &&
          SiennaPRASInterface.stderror(lole) <= 10
    @test SiennaPRASInterface.val(eue) >= 0 && SiennaPRASInterface.val(eue) <= 10
    @test SiennaPRASInterface.stderror(eue) >= 0 && SiennaPRASInterface.stderror(eue) <= 10
end

@testset "test assess(::PSY.System, ::Area, ...) Hourly PRAS System" begin
    rts_da_sys = get_rts_gmlc_outage("DA")

    sequential_monte_carlo = SiennaPRASInterface.SequentialMonteCarlo(samples=2, seed=1)
    @testset "sys-area call" begin
        shortfalls, = SiennaPRASInterface.assess(
            rts_da_sys,
            PSY.Area,
            sequential_monte_carlo,
            SiennaPRASInterface.Shortfall(),
        )
        test_shortfalls(shortfalls)
    end
    @testset "sys call" begin
        shortfalls, = SiennaPRASInterface.assess(
            rts_da_sys,
            sequential_monte_carlo,
            SiennaPRASInterface.Shortfall(),
        )
        test_shortfalls(shortfalls)
    end

    @testset "sys RATemplate call" begin
        template = SiennaPRASInterface.RATemplate(
            PSY.Area,
            deepcopy(SiennaPRASInterface.DEFAULT_DEVICE_MODELS),
        )
        SiennaPRASInterface.set_device_model!(
            template,
            DeviceRAModel(
                PSY.RenewableDispatch,
                GeneratorPRAS,
                lump_renewable_generation=true,
            ),
        )
        SiennaPRASInterface.set_device_model!(
            template,
            DeviceRAModel(
                PSY.RenewableDispatch,
                GeneratorPRAS,
                lump_renewable_generation=true,
                add_default_transition_probabilities=true,
            ),
        )

        shortfalls, = SiennaPRASInterface.assess(
            rts_da_sys,
            template,
            sequential_monte_carlo,
            SiennaPRASInterface.Shortfall(),
        )
        test_shortfalls(shortfalls)
    end
end

@testset "test assess(::PSY.System, ::Area, ...) Sub-Hourly System" begin
    rts_rt_sys = get_rts_gmlc_outage("RT")

    sequential_monte_carlo = SiennaPRASInterface.SequentialMonteCarlo(samples=2, seed=1)
    shortfalls, = SiennaPRASInterface.assess(
        rts_rt_sys,
        PSY.Area,
        sequential_monte_carlo,
        SiennaPRASInterface.Shortfall(),
    )

    test_shortfalls(shortfalls)
end
