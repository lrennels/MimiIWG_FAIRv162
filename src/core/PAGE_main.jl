"""
Returns the IWG version of the PAGE 2009 model for the specified scenario.
"""
function get_page_model(scenario_choice::Union{scenario_choice, Nothing}=nothing, gas::Symbol=nothing)

    # Get original version of PAGE
    m = MimiPAGE2009.get_model()

    # Nowe we need to reset the time dimension from the default PAGE2009 years 
    # to the IWG PAGE years, or  
    #
    # FROM: [2009, 2010, 2020, 2030, 2040, 2050, 2075, 2100, 2150, 2200]
    # TO: [2010, 2020, 2030, 2040, 2050, 2060, 2080, 2100, 2200, 2300]
    #
    # however this reset is illeagl in current resetting time dimension protocol
    # because it moves the start year forward.  The following is a backdoor way 
    # to make this change but is unsafe in the way it handles parameter time labels
    # so it SHOULD NOT be replicated or altered. In the future we should return 
    # and change page_years to start in 2009 with a missing value and then 
    # continue to 2300. [Lisa Rennels May 4 2021]
    
    dim = Mimi.Dimension(page_years)
    Mimi._propagate_time_dim!(m.md, dim)
    Mimi._propagate_first_last!(m.md; first = page_years[1], last = page_years[end])

    # Add dimensions required for FAIR exogenous temperature component
    set_dimension!(m, :fair_samples, _n_fair_samples)
    set_dimension!(m, :pulse_years, length(_all_pulse_years))
    set_dimension!(m, :scenarios, length(scenarios))

    # Replace modified components
    replace!(m, :GDP => IWG_PAGE_GDP)
    replace!(m, :ClimateTemperature => IWG_PAGE_ClimateTemperature)

    # Load all of the IWG parameters from excel that aren't scenario specific
    set_param!(m, :ClimateTemperature, :sens_climatesensitivity, _page_iwg_params["sens_climatesensitivity"])

    # Update y_year_0 and y_year parameters used by components
    update_param!(m, :y_year_0, 2000)
    update_param!(m, :y_year, page_years)
    
    # Update all parameter values (and their timesteps) from the iwg parameters
    for (k, v) in _page_iwg_params
        if Symbol(k) in keys(Mimi.model_params(m))
            if size(v) == (10, 8) || size(v) == (10,)
                update_param!(m, Symbol(k), v)
            else
                update_param!(m, Symbol(k), v)
            end
        else
            set_param!(m, Symbol(k), v)
        end
    end

    # Add the scenario choice component and load all the scenario parameter values
    add_comp!(m, IWG_PAGE_ScenarioChoice, :IWGScenarioChoice; before = :co2emissions)
    set_page_all_scenario_params!(m)

    # Set the scenario number if a scenario_choice was provided
    if scenario_choice !== nothing 
        scenario_num = Int(scenario_choice)
        set_param!(m, :IWGScenarioChoice, :scenario_num, scenario_num)
    end

    ##
    ## Handle Exogenous Temperature
    ##

    # Remove the climate modules; temperature is now exogenous
    for c in [  :co2cycle, :co2forcing, :ch4forcing, :ch4cycle, :n2oforcing, :n2ocycle, 
                :LGcycle, :LGforcing, :SulphateForcing, :TotalForcing, :ClimateTemperature
            ]
        delete!(m, c)
    end

    # Add FAIR exogenous temperature component
    add_comp!(m, FAIR_T_exog, before=:SeaLevelRise);

    # Reconnect temperature where needed
    connect_param!(m, :SeaLevelRise => :rt_g_globaltemperature, :FAIR_T_exog => :T)
    connect_param!(m, :Discontinuity => :rt_g_globaltemperature, :FAIR_T_exog => :T)

    # TODO differentiate between global and regional realized temperature via 
    # pattern scaling -- see FAIR_T_exog component
    connect_param!(m, :MarketDamages => :rtl_realizedtemperature, :FAIR_T_exog => :T_regions)
    connect_param!(m, :NonMarketDamages => :rtl_realizedtemperature, :FAIR_T_exog => :T_regions)

    # Set temperature trajectories
    n_page_years = length(page_years)
    n_scenarios = length(scenarios)
    n_pulse_years = length(_all_pulse_years)

    T_key = Arrow.Table(joinpath(@__DIR__, "..", "fairv162_paths", "output", "temperature_T_KEY.arrow")) |> DataFrame;
    T_base = Array{Float64}(undef, n_page_years, _n_fair_samples, n_scenarios);
    T_pulse = Array{Float64}(undef, n_page_years, _n_fair_samples, n_pulse_years, n_scenarios);

    for scenario in scenarios

        # load the temperature path
        T = Arrow.Table(joinpath(@__DIR__, "..", "fairv162_paths", "output", "T_$(gas)_$(emf_scenarios[Int(scenario)]).arrow")) |> DataFrame
        T = hcat(T_key, T) |> @filter(_.time in page_years) |> DataFrame

        # Set BASE temperature trajectories
        T_base_scenario = unstack(select(T, :time, :trialnum, :T_base), :trialnum, :T_base) |> DataFrame
        T_base[:,:,Int(scenario)] = max.(T_base_scenario[:,2:end] |> Matrix, 0.) # remove negative temperature anomalies

        # Set PULSE temperature trajectories
        T_pulse_scenario = Array{Float64}(undef, n_page_years, _n_fair_samples, n_pulse_years)
        for (i, pulse_year) in enumerate(_all_pulse_years)
            col = Symbol("T_pulse_$(pulse_year)")
            T_pulse_scenario_year = unstack(select(T, :time, :trialnum, col), :trialnum, col) |> DataFrame
            T_pulse_scenario[:,:,i] = T_pulse_scenario_year[:,2:end] |> Matrix
        end
        T_pulse[:,:,:,Int(scenario)] = max.(T_pulse_scenario, 0.) # remove negative temperature anomalies
    end

    # Set the FAIR exogenous trajectories in the component
    update_param!(m, :FAIR_T_exog, :T_base, T_base)
    update_param!(m, :FAIR_T_exog, :T_pulse, T_pulse)
    
    # Update gas in temperature component
    update_param!(m, :FAIR_T_exog, :gas, gas)
    
    # Update scenario number if a scenario_choice was provided
    if scenario_choice !== nothing
        scenario_num = Int(scenario_choice)
        update_param!(m, :FAIR_T_exog, :FAIR_T_exog_scenario_num, scenario_num)
    end

    return m
end

"""
set_page_all_scenario_params!(m::Model; comp_name::Symbol = :IWGScenarioChoice, connect::Boolean = true)
    m: a Mimi model with and IWGScenarioChoice component
    comp_name: the name of the IWGScenarioChoice component in the model, defaults to :IWGScenarioChoice
    connect: whether or not to connect the outgoing variables to the other components who depend on them as parameter values
"""
function set_page_all_scenario_params!(m::Model; comp_name::Symbol = :IWGScenarioChoice, connect::Bool = true)

    # reshape each array of values into one array for each param, then set that value in the model
    for (k, v) in _page_scenario_params_dict
        _size = size(v[1])
        param = zeros(_size..., 5)
        for i in 1:5
            param[[1:l for l in _size]..., i] = v[i]
        end
        set_param!(m, comp_name, Symbol("$(k)_all"), param)
    end

    if connect 
        connect_param!(m, :GDP => :gdp_0, comp_name => :gdp_0)
        connect_all!(m, [:GDP, :EquityWeighting], comp_name => :grw_gdpgrowthrate)
        connect_all!(m, [:Discontinuity, :MarketDamages, :NonMarketDamages, :SLRDamages], comp_name => :GDP_per_cap_focus_0_FocusRegionEU)
        connect_all!(m, [:GDP, :Population], comp_name => :pop0_initpopulation)
        connect_all!(m, [:EquityWeighting, :Population], comp_name => :popgrw_populationgrowth)
        connect_all!(m, [:co2emissions => :e0_baselineCO2emissions, :AbatementCostsCO2 => :e0_baselineemissions, :AbatementCostParametersCO2 => :e0_baselineemissions], comp_name => :e0_baselineCO2emissions)
        connect_param!(m, :co2cycle => :e0_globalCO2emissions, comp_name => :e0_globalCO2emissions)
        connect_all!(m, [:co2emissions => :er_CO2emissionsgrowth, :AbatementCostsCO2 => :er_emissionsgrowth], comp_name => :er_CO2emissionsgrowth)
        connect_param!(m, :co2forcing => :f0_CO2baseforcing, comp_name => :f0_CO2baseforcing)
        connect_param!(m, :TotalForcing => :exf_excessforcing, comp_name => :exf_excessforcing)
    end
end


"""
    Returns a dicitonary of all of the necessary parameters that are the same for all IWG scenarios. (Does not include scenario-specific parameters.)
"""
function load_page_iwg_params()

    # Build a dictionary of values to return
    p = Dict{Any, Any}()

    # Specify the scenario parameter file path
    fn = joinpath(iwg_page_input_file)
    xf = readxlsx(fn)

    #------------------------
    # 1. BASE DATA sheet
    #------------------------

    # Socioeconomics
    p["lat_latitude"] = convert(Array{Float64}, xf["Base data"]["M24:M31"])[:, 1]
    # the rest of the Socioeconomics parameters are scenario-specific

    # Initial emissions (all but CO2)
    p["e0_baselineCH4emissions"] = convert(Array{Float64}, xf["Base data"]["G24:G31"])[:, 1]    # initial CH4 emissions
    p["AbatementCostsCH4_e0_baselineemissions"] = p["e0_baselineCH4emissions"]                      # same initial values, but different parameter name in the AbatementCosts component
    p["AbatementCostParametersCH4_e0_baselineemissions"] = p["e0_baselineCH4emissions"]             # same initial values, but different parameter name in the AbatementCostParameters component
    p["e_0globalCH4emissions"] = sum(p["e0_baselineCH4emissions"])                                  # sum to get global
    p["e0_baselineN2Oemissions"] = convert(Array{Float64}, xf["Base data"]["H24:H31"])[:, 1]    # initial N2O emissions
    p["AbatementCostsN2O_e0_baselineemissions"] = p["e0_baselineN2Oemissions"]                      # same initial values, but different parameter name in the AbatementCosts component
    p["AbatementCostParametersN2O_e0_baselineemissions"] = p["e0_baselineN2Oemissions"]             # same initial values, but different parameter name in the AbatementCostParameters component
    p["e_0globalN2Oemissions"] = sum(p["e0_baselineN2Oemissions"])                                  # sum to get global
    p["e0_baselineLGemissions"] = convert(Array{Float64}, xf["Base data"]["I24:I31"])[:, 1]     # initial Linear Gas emissions
    p["AbatementCostsLin_e0_baselineemissions"] = p["e0_baselineLGemissions"]                       # same initial values, but different parameter name in the AbatementCosts component
    p["AbatementCostParametersLin_e0_baselineemissions"] = p["e0_baselineLGemissions"]              # same initial values, but different parameter name in the AbatementCostParameters component
    p["e_0globalLGemissions"] = sum(p["e0_baselineLGemissions"])                                    # sum to get global
    p["se0_sulphateemissionsbase"] = convert(Array{Float64}, xf["Base data"]["J24:J31"])[:, 1]  # initial Sulphate emissions
    p["nf_naturalsfx"] = convert(Array{Float64}, xf["Base data"]["K24:K31"])[:, 1]              # natural Sulphate emissions

    p["rtl_0_realizedtemperature"] = convert(Array{Float64}, xf["Base data"]["L24:L31"])[:, 1]  # RTL0

    # Forcing slopes and bases (excludes CO2 base forcing)
    p["fslope_CO2forcingslope"] = xf["Base data"]["B14:B14"][1]     # CO2 forcing slope
    p["fslope_CH4forcingslope"] = xf["Base data"]["C14:C14"][1]     # CH4 forcing slope
    p["fslope_N2Oforcingslope"] = xf["Base data"]["D14:D14"][1]     # CO2 forcing slope
    p["fslope_LGforcingslope"] = xf["Base data"]["E14:E14"][1]      # LG forcing slope
    p["f0_CH4baseforcing"] = xf["Base data"]["C21:C21"][1]          # CH4 base forcing
    p["f0_N2Obaseforcing"] = xf["Base data"]["D21:D21"][1]          # CO2 base forcing
    p["f0_LGforcingbase"] = xf["Base data"]["E21:E21"][1]           # LG base forcing

    # stimulation, air fractions, and halflifes
    p["stim_CH4emissionfeedback"] = xf["Base data"]["C15:C15"][1] 
    p["air_CH4fractioninatm"] = xf["Base data"]["C17:C17"][1] 
    p["res_CH4atmlifetime"] = xf["Base data"]["C18:C18"][1] 
    p["stim_N2Oemissionfeedback"] = xf["Base data"]["D15:D15"][1] 
    p["air_N2Ofractioninatm"] = xf["Base data"]["D17:D17"][1] 
    p["res_N2Oatmlifetime"] = xf["Base data"]["D18:D18"][1] 
    p["stim_LGemissionfeedback"] = xf["Base data"]["E15:E15"][1] 
    p["air_LGfractioninatm"] = xf["Base data"]["E17:E17"][1] 
    p["res_LGatmlifetime"] = xf["Base data"]["E18:E18"][1] 

    # concentrations
    p["stay_fractionCO2emissionsinatm"] = xf["Base data"]["B16:B16"][1] / 100 # percent of CO2 emissions that stay in the air
    p["c0_CO2concbaseyr"] = xf["Base data"]["B19:B19"][1]               # CO2 base year concentration
    p["c0_baseCO2conc"] = p["c0_CO2concbaseyr"]
    p["ce_0_basecumCO2emissions"] = xf["Base data"]["B20:B20"][1]       # CO2 cumulative emissions
    p["c0_CH4concbaseyr"] = xf["Base data"]["C19:C19"][1]                 # CH4 base year concentration
    p["c0_baseCH4conc"] = p["c0_CH4concbaseyr"]
    p["c0_N2Oconcbaseyr"] = xf["Base data"]["D19:D19"][1]                 # N2O base year concentration
    p["c0_baseN2Oconc"] = p["c0_N2Oconcbaseyr"]
    p["c0_LGconcbaseyr"] = xf["Base data"]["E19:E19"][1]                # LG base year concentration

    # BAU emissions
    p["AbatementCostParametersCO2_bau_businessasusualemissions"] = convert(Array{Float64}, xf["Base data"]["C68:L75"]')
    p["AbatementCostParametersCH4_bau_businessasusualemissions"] = convert(Array{Float64}, xf["Base data"]["C77:L84"]')
    p["AbatementCostParametersN2O_bau_businessasusualemissions"] = convert(Array{Float64}, xf["Base data"]["C86:L93"]')
    p["AbatementCostParametersLin_bau_businessasusualemissions"] = convert(Array{Float64}, xf["Base data"]["C95:L102"]')

    #elasticity of utility
    p["emuc_utilityconvexity"] = xf["Base data"]["B10:B10"][1]

    #pure rate of time preference
    p["ptp_timepreference"] = xf["Base data"]["B8:B8"][1]

    #------------------------
    # 2. LIBRARY DATA sheet
    #------------------------

    p["sens_climatesensitivity"] = xf["Library data"]["C18:C18"][1]  # Climate sensitivity
    
    # p["cutbacks_at_neg_cost_grw"] = xf["Library data"]["C123:C123"][1]    # cutbacks at negative cost growth rate (??)
    # p["max_cutbacks_grw"] = xf["Library data"]["C125:C125"][1]        # Maximum cutbacks growth rate
    # p["most_neg_grw"] = xf["Library data"]["C127:C127"][1]           # Most negative cost growth rate
    
    # p["automult_autonomoustechchange"] = xf["Library data"]["C134:C134"][1]        # Autonomous technical change
    # p["auto"] = xf["Library data"]["C134:C134"][1]        # Autonomous technical change

    p["d_sulphateforcingbase"] = xf["Library data"]["C11:C11"][1]
    p["ind_slopeSEforcing_indirect"] = xf["Library data"]["C12:C12"][1]

    p["q0propmult_cutbacksatnegativecostinfinalyear"] = xf["Library data"]["C122:C122"][1]
    p["qmax_minus_q0propmult_maxcutbacksatpositivecostinfinalyear"] = xf["Library data"]["C124:C124"][1]
    p["c0mult_mostnegativecostinfinalyear"] = xf["Library data"]["C126:C126"][1]

    p["civvalue_civilizationvalue"] = xf["Library data"]["C44:C44"][1]

    #------------------------
    # 3. POLICY A sheet
    #------------------------

    # Emissions growth (all but CO2)
    p["er_CH4emissionsgrowth"] = convert(Array{Float64}, xf["Policy A"]["B14:K21"]')    # CH4 emissions growth
    p["er_N2Oemissionsgrowth"] = convert(Array{Float64}, xf["Policy A"]["B23:K30"]')    # N2O emissions growth
    p["er_LGemissionsgrowth"] = convert(Array{Float64}, xf["Policy A"]["B32:K39"]')    # Lin emissions growth
    p["AbatementCostsCH4_er_emissionsgrowth"] = convert(Array{Float64}, xf["Policy A"]["B14:K21"]')    # CH4 emissions growth
    p["AbatementCostsN2O_er_emissionsgrowth"] = convert(Array{Float64}, xf["Policy A"]["B23:K30"]')    # N2O emissions growth
    p["AbatementCostsLin_er_emissionsgrowth"] = convert(Array{Float64}, xf["Policy A"]["B32:K39"]')    # Lin emissions growth
    
    p["pse_sulphatevsbase"] = convert(Array{Float64}, xf["Policy A"]["B41:K48"]')

    return p
end

# Only load these parameters once, and `get_model` uses this dictionary
_page_iwg_params = load_page_iwg_params()

function getpageindexfromyear(year)
    i = findfirst(isequal(year), page_years)
    if i == 0
        error("Invalid PAGE year: $year.")
    end 
    return i 
end

function getpageindexlengthfromyear(year)
    if year == 2010
        return 10
    end 
    
    i = findfirst(page_years, year)
    if i == 0
        error("Invalid PAGE year: $year.")
    end 

    return page_years[i] - page_years[i-1]
end

function getperiodlength(year)
    if year==2010
        return 10
    end

    i = getpageindexfromyear(year)

    return (page_years[i+1] - page_years[i-1]) / 2
end

function get_marginal_page_models(; scenario_choice::Union{scenario_choice, Nothing}=nothing, gas::Symbol=:CO2, year=nothing, discount=nothing)

    base = get_page_model(scenario_choice, gas)
    if discount != nothing
        update_param!(base, :ptp_timepreference, discount * 100)
    end
    marginal = Model(base)

    pulse_year_idx = findfirst(i -> i == year, _all_pulse_years)
    update_param!(marginal, :FAIR_T_exog, :pulse, true)
    update_param!(marginal, :FAIR_T_exog, :pulse_year_idx, pulse_year_idx)

    # TODO update emissions as well to handle components that take emissions as 
    # a direct input (eg. adaptation costs)
    return base, marginal
end

"""
    Returns the Social Cost of the specified `gas` for a given `year` and `discount` rate from one deterministic run of the IWG-PAGE model.
    User must specify an IWG scenario `scenario_choice`.
    If no `year` is specified, will return SCC for $_default_year.
    If no `discount` is specified, will return SCC for a discount rate of $(_default_discount * 100)%.
"""
function compute_page_scc(scenario_choice::scenario_choice, gas::Symbol, year::Int, discount::Float64; domestic=false)

    # Check the emissions year
    _need_to_interpolate = false
    if year < page_years[1] || year > page_years[end]
        error("$year is not a valid year; can only calculate SCC within the model's time index $page_years.")
    elseif ! (year in page_years)
        _need_to_interpolate = true         # boolean flag for if the desired SCC years is in the middle of the model's time index
        mid_year = year     # save the desired SCC year to interpolate later
        year = filter(x-> x < year, page_years)[end]    # use the last year less than the desired year as the lower scc value
    end

    base, marginal = get_marginal_page_models(scenario_choice=scenario_choice, gas=gas, year=year, discount=discount)
    run(base)
    run(marginal)

    DF = [(1 / (1 + discount)) ^ (Y - 2000) for Y in page_years]
    idx = getpageindexfromyear(year)

    if domestic
        td_base = sum(base[:EquityWeighting, :addt_equityweightedimpact_discountedaggregated][:, 2])  # US is the second region; then sum across time
        td_marginal = sum(marginal[:EquityWeighting, :addt_equityweightedimpact_discountedaggregated][:, 2])
    else 
        td_base = base[:EquityWeighting, :td_totaldiscountedimpacts]
        td_marginal = marginal[:EquityWeighting, :td_totaldiscountedimpacts] 
    end
        
    EMUC = base[:EquityWeighting, :emuc_utilityconvexity]
    UDFT_base = DF[idx] * (base[:EquityWeighting, :cons_percap_consumption][idx, 1] / base[:EquityWeighting, :cons_percap_consumption_0][1]) .^ (-EMUC)
    UDFT_marginal = DF[idx] * (marginal[:EquityWeighting, :cons_percap_consumption][idx, 1] / base[:EquityWeighting, :cons_percap_consumption_0][idx]) ^ (-EMUC)

    # TODO work on pulse size here
    pulse_size = gas == :CO2 ? 1e3 : 1
    scc = ((td_marginal / UDFT_marginal) - (td_base / UDFT_base)) / pulse_size * page_inflator

    if _need_to_interpolate     # need to calculate SCC for next year in time index as well, then interpolate for desired year
        lower_scc = scc
        next_year = page_years[findfirst(page_years, year) + 1] 
        upper_scc = compute_page_scc(scenario_choice, next_year, discount, domestic=domestic)
        scc = _interpolate([lower_scc, upper_scc], [year, next_year], [mid_year])[1]
    end 

    return scc
end
