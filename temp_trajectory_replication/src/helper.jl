using DataFrames, CSVFiles, Query, Interpolations, Mimi

function get_emf_fair(emf_scenario::Symbol, datadir::String)

    # get MimiFAIRv1_6_2 model
    m = MimiFAIRv1_6_2.get_model(start_year=1750, end_year=2300, ar6_scenario = "ssp245")

    # get an second model to pull the data
    m2 = deepcopy(m)
    run(m2)

    # methane (Mt CH4)
    emf_ch4 = load(joinpath(datadir, "dice_inputs_ch4.csv"), skiplines_begin=1) |> DataFrame |> i -> select(i, [:Year, emf_scenario]) |> DataFrame
    fair_ch4 = getdataframe(m2, :ch4_cycle, :fossil_emiss_CH₄)
    idxs = indexin(emf_ch4.Year, fair_ch4.time)
    fair_ch4[idxs, :fossil_emiss_CH₄] .= emf_ch4[!, emf_scenario]
    update_param!(m, :fossil_emiss_CH₄, fair_ch4.fossil_emiss_CH₄)

    # nitrous oxide (Mt N2O))
    emf_n2o = load(joinpath(datadir, "dice_inputs_n2o.csv"), skiplines_begin=1) |> DataFrame |> i -> select(i, [:Year, emf_scenario]) |> DataFrame
    fair_n2o = getdataframe(m2, :n2o_cycle, :fossil_emiss_N₂O)
    idxs = indexin(emf_n2o.Year, fair_n2o.time)
    fair_n2o[idxs, :fossil_emiss_N₂O] .= emf_n2o[!, emf_scenario]
    update_param!(m, :fossil_emiss_N₂O, fair_n2o.fossil_emiss_N₂O)

    # CO2 landuse emissions
    emf_land_co2 = load(joinpath(datadir, "dice_inputs_land_co2.csv"), skiplines_begin=1) |> DataFrame |> i -> select(i, [:Year, emf_scenario]) |> DataFrame
    emf_land_co2[!, emf_scenario] = emf_land_co2[!, emf_scenario] ./ 10. # convert decadal to annual
    interp_linear = LinearInterpolation(emf_land_co2.Year, emf_land_co2[!, emf_scenario])
    emf_land_co2_interp = interp_linear[collect(2005:2300)]
    fair_land_co2 = getdataframe(m2, :landuse_forcing, :landuse_emiss)
    idxs = indexin(2005:2300, fair_land_co2.time)
    fair_land_co2[idxs, :landuse_emiss] .= emf_land_co2_interp
    update_param!(m, :landuse_emiss, fair_land_co2.landuse_emiss)

    # CO2 industrial emissions
    emf_industrial_co2 = load(joinpath(datadir, "dice_inputs_industrial_co2.csv"), skiplines_begin=1) |> DataFrame |> i -> select(i, [:Year, emf_scenario]) |> DataFrame
    emf_industrial_co2[!, emf_scenario] = emf_industrial_co2[!, emf_scenario] ./ 10. # convert decadal to annual
    interp_linear = LinearInterpolation(emf_industrial_co2.Year, emf_industrial_co2[!, emf_scenario])
    emf_industrial_co2_interp = interp_linear[collect(2005:2300)]
    fair_E_co2 = getdataframe(m2, :co2_cycle, :E_co2)
    idxs = indexin(2005:2300, fair_E_co2.time)
    fair_E_co2[idxs, :E_co2] .= emf_industrial_co2_interp .+ emf_land_co2_interp
    update_param!(m, :E_co2, fair_E_co2.E_co2)

    return m
end
