"""
    Returns the IWG version of the DICE 2010 model for the specified scenario.
"""
function get_dice_model(scenario_choice::Union{scenario_choice, Nothing}=nothing, gas::Union{Nothing, Symbol}=nothing)

    # Get the original default version of DICE2010
    m = MimiDICE2010.construct_dice()

    # Shorten the time index
    set_dimension!(m, :time, dice_years)
    
    # Add dimensions required for FAIR exogenous temperature component
    set_dimension!(m, :fair_samples, _n_fair_samples)
    set_dimension!(m, :pulse_years, length(_all_pulse_years))
    set_dimension!(m, :scenarios, length(scenarios))

    # Replace the IWG modified components
    replace!(m, :neteconomy => IWG_DICE_neteconomy)
        
    # Delete the emissions component; emissions are now exogenous
    delete!(m, :emissions)

    # Update all IWG parameter values that are not scenario-specific
    iwg_params = load_dice_iwg_params()
    update_params!(m, iwg_params)

    # Add the scenario choice component and load all the scenario parameter values
    add_comp!(m, IWG_DICE_ScenarioChoice, :IWGScenarioChoice; before = :grosseconomy)
    set_dice_all_scenario_params!(m)
     
    # Set the scenario number if a scenario_choice was provided
    if scenario_choice !== nothing 
        scenario_num = Int(scenario_choice)
        set_param!(m, :IWGScenarioChoice, :scenario_num, scenario_num)
    end

    ##
    ## Handle Exogenous Temperature
    ##
    
    # Remove the climate modules; temperature is now exogenous
    delete!(m, :co2cycle)
    delete!(m, :radiativeforcing)
    delete!(m, :climatedynamics)
    
    # Add FAIR exogenous temperature component
    add_comp!(m, FAIR_T_exog, before=:sealevelrise)

    # Reconnect temperature where needed
    connect_param!(m, :sealevelrise => :TATM, :FAIR_T_exog => :T)
    connect_param!(m, :damages => :TATM, :FAIR_T_exog => :T)
    missing_years = 2305:10:dice_years[end]  # add bottom rows that don't matter for SCC because it ends at 2300; performance note: allocation

    # Set temperature trajectories
    n_dice_years = length(dice_years)
    n_scenarios = length(scenarios)
    n_pulse_years = length(_all_pulse_years)

    T_key = Arrow.Table(joinpath(datadep"mimiiwg_fairv162_temp_trajectories", "temperature_T_KEY.arrow")) |> DataFrame
    T_base = Array{Float64}(undef, n_dice_years, _n_fair_samples, n_scenarios)
    T_pulse = Array{Float64}(undef, n_dice_years, _n_fair_samples, n_pulse_years, n_scenarios)
    
    for scenario in scenarios

        # load the temperature path
        T = Arrow.Table(joinpath(datadep"mimiiwg_fairv162_temp_trajectories", "T_$(gas)_$(emf_scenarios[Int(scenario)]).arrow")) |> DataFrame
        T = hcat(T_key, T) |> @filter(_.time in dice_years) |> DataFrame

        # Set BASE temperature trajectories
        T_base_scenario = unstack(select(T, :time, :trialnum, :T_base), :trialnum, :T_base) |> DataFrame
        for year in missing_years # append extra rows to 2500, these will not be used in the SC-GHG calculation
            append!(T_base_scenario, DataFrame(T_base_scenario[end,:]))
        end
        T_base[:,:,Int(scenario)] = max.(T_base_scenario[:,2:end] |> Matrix, 0.) # remove negative temperature anomalies

        # Set PULSE temperature trajectories
        T_pulse_scenario = Array{Float64}(undef, n_dice_years, _n_fair_samples, n_pulse_years)
        for (i, pulse_year) in enumerate(_all_pulse_years)
            col = Symbol("T_pulse_$(pulse_year)")
            T_pulse_scenario_year = unstack(select(T, :time, :trialnum, col), :trialnum, col) |> DataFrame
            for year in missing_years # append extra rows to 2500, these will not be used in the SC-GHG calculation
                append!(T_pulse_scenario_year, DataFrame(T_pulse_scenario_year[end,:]))
            end
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
set_dice_all_scenario_params!(m::Model; comp_name::Symbol = :IWGScenarioChoice, connect::Boolean = true)
    m: a Mimi model with and IWGScenarioChoice component
    comp_name: the name of the IWGScenarioChoice component in the model, defaults to :IWGScenarioChoice
    connect: whether or not to connect the outgoing variables to the other components who depend on them as parameter values
"""
function set_dice_all_scenario_params!(m::Model; comp_name::Symbol = :IWGScenarioChoice, connect::Bool = true)
    params_dict = Dict{Symbol, Array}([k=>[] for k in dice_scenario_specific_params])

    # add an array of each scenario's value to the dictionary
    for scenario in scenarios
        params = load_dice_scenario_params(scenario)
        for p in dice_scenario_specific_params
            push!(params_dict[p], params[p])
        end
    end

    # reshape each array of values into one array for each param, then set that value in the model
    for (k, v) in params_dict
        _size = size(v[1])
        param = zeros(_size..., 5)
        for i in 1:5
            param[[1:l for l in _size]..., i] = v[i]
        end
        set_param!(m, comp_name, Symbol("$(k)_all"), param)
    end

    if connect 
        connect_all!(m, [:grosseconomy, :neteconomy], comp_name=>:l)
        connect_param!(m, :grosseconomy=>:al, comp_name=>:al)
        connect_param!(m, :grosseconomy=>:k0, comp_name=>:k0)
    end

end

"""
    Returns a dictionary of the scenario-specific parameter values for the specified scenario.
"""
function load_dice_scenario_params(scenario_choice, scenario_file=nothing)

    # Input parameters from EPA's Matlab code
    A0    = 0.0303220  # First period total factor productivity, from DICE2010
    gamma = 0.3        # Labor factor productivity, from DICE2010
    delta = 0.1        # Capital depreciation rate [yr^-1], from DICE2010
    s     = 0.23       # Approximate optimal savings in DICE2010 
    
    params = Dict{Any, Any}()
    nyears = length(dice_years)

    # Get the scenario number
    idx = Int(scenario_choice)

    # All scenario data
    scenario_file = scenario_file === nothing ? iwg_dice_input_file : scenario_file
    f = openxlsx(scenario_file)

    Y       = f["GDP!B2:F32"][:, idx] * dice_inflate    # GDP
    N       = f["Population!B2:F32"][:, idx]            # Population
    E       = f["IndustrialCO2!B2:F32"][:, idx]         # Industrial CO2
    El      = f["LandCO2!B2:F32"][:, idx]               # Land CO2 
    Fex1    = f["EMFnonCO2forcings!B2:F32"][:, idx]     # EMF non-CO2 forcings
    Fex2    = f["OthernonCO2forcings!B2:B32"]           # Other non-CO2 forcings
    Fex     = Fex1 + Fex2                               # All non-CO2 forcings

    # Use 2010 EMF value for dice period 2005-2015 etc. (need additional zeros to run past the 31st timestep)
    Y = [Y[2:end]; zeros(nyears - length(Y[2:end]))]
    N = [N[2:end]; zeros(nyears - length(N[2:end]))]
    E = [E[2:end]; zeros(nyears - length(E[2:end]))]
    El = [El[2:end]; zeros(nyears - length(El[2:end]))]
    Fex = [Fex[2:end]; zeros(nyears - length(Fex[2:end]))]

    # Set these scenario values in the parameter dictionary:
    params[:l] = N          # population
    params[:E] = El + E     # total CO2 emissions
    params[:forcoth] = Fex  # other forcings

    # Solve for implied path of exogenous technical change using the given GDP (Y data) 
    al = zeros(nyears)   
    K = zeros(nyears)
    al[1] = A0
    K[1] = (Y[1] / al[1] / (N[1] ^ (1 - gamma))) ^ (1 / gamma)
    for t in 2:nyears
        K[t] = K[t-1] * (1 - delta) ^ 10 + s * Y[t-1] * 10
        al[t] = Y[t] / (N[t] + eps()) ^ (1 - gamma) / (K[t] + eps()) ^ gamma
    end

    # Update these parameters for grosseconomy component
    params[:al] = al    # total factor productivity
    params[:k0] = K[1]  # initial capital stock

    return params
end

"""
    Returns a dicitonary of IWG parameters that are the same for all IWG scenarios. (Does not include scenario-specific parameters.)
"""
function load_dice_iwg_params()

    params = Dict{Any, Any}()
    nyears = length(dice_years)

    # Replace some parameter values to match EPA's matlab code
    params[:S]          = repeat([0.23], nyears)    # previously called 'savebase'. :S in neteconomy
    params[:MIU]        = zeros(nyears)             # previously called 'miubase'-- :MIU in neteconomy;  make this all zeros so abatement in neteconomy is calculated as zero; EPA doesn't include abatement costs
    params[:a1]         = 0.00008162
    params[:a2]         = 0.00204626
    params[:b1]         = 0.00518162                # previously called 'slrcoeff'-- :b1 in SLR
    params[:b2]         = 0.00305776                # previously called 'slrcoeffsq'-- :b2 in SLR
    params[:t2xco2]     = 3.0

    return params
end

function get_dice_marginal_model(scen::scenario_choice; gas::Symbol, year::Int64)
    pulse_year_idx = findfirst(i -> i == year, _all_pulse_years)
    base = get_dice_model(scen, gas)
    mm = create_marginal_model(base)
    update_param!(mm.modified, :FAIR_T_exog, :pulse, true)
    update_param!(mm.modified, :FAIR_T_exog, :pulse_year_idx, pulse_year_idx)
    return mm
end

"""
    Returns marginal damages each year from an additional ton of the specified `gas` in the specified year. 
 """
function get_dice_marginaldamages(scenario_choice::scenario_choice, gas::Symbol, year::Int, discount::Float64) 

    # Check the emissions year
    _is_mid_year = false
    if year < dice_years[1] || year > dice_years[end]
        error("$year is not a valid year; can only calculate marginal damages within the model's time index $dice_years.")
    elseif ! (year in dice_years)
        _is_mid_year = true         # boolean flag for if the desired year is in between values of the model's time index
        mid_year = year     # save the desired year to interpolate later
        year = dice_years[Int(floor((year - dice_years[1]) / dice_ts) + 1)]    # first calculate for the DICE year below the specified year
    end

    mm = get_dice_marginal_model(scenario_choice, gas=gas, year=year)
    run(mm)
    diff = -1. * mm[:neteconomy, :C] * _dice_normalization_factor(gas)

    if _is_mid_year     # need to calculate md for next year in time index as well, then interpolate for desired year
        lower_diff = diff
        next_year = dice_years[findfirst(isequal(year), dice_years) + 1]
        upper_diff = get_dice_marginaldamages(scenario_choice, gas, next_year, 0.)
        diff = [_interpolate([lower_diff[i], upper_diff[i]], [year, next_year], [mid_year])[1] for i in 1:length(lower_diff)]
    end 

    if discount != 0 
        nyears = length(dice_years)
        DF = zeros(nyears)
        first = findfirst(isequal(year), dice_years)
        DF[first:end] = [1/(1+discount)^t for t in 0:(nyears-first)]
        return diff .* DF
    else
        return diff
    end

end

"""
    Returns the Social Cost of the specified `gas` for a given `year` and `discount` rate 
    from one deterministic run of the IWG-DICE model for the specified scenario.
"""
function compute_dice_scc(scenario_choice::scenario_choice, gas::Symbol, year::Int, discount::Float64; domestic::Bool = false, horizon::Int = _default_horizon)

    # Check if the emissions year is valid, and whether or not we need to interpolate
    _is_mid_year = false
    if year < dice_years[1] || year > dice_years[end]
        error("$year is not a valid year; can only calculate SCC within the model's time index $years.")
    elseif ! (year in dice_years)
        _is_mid_year = true         # boolean flag for if the desired SCC years is in between values of the model's time index
        mid_year = year     # save the desired SCC year to interpolate later
        year = dice_years[Int(floor((year - dice_years[1]) / dice_ts) + 1)]    # first calculate for the DICE year below the specified year
    end

    md = get_dice_marginaldamages(scenario_choice, gas, year, 0.)   # Get undiscounted marginal damages
    annual_years = dice_years[1]:horizon
    annual_md = _interpolate(md, dice_years, annual_years)   # Interpolate to annual timesteps

    DF = zeros(length(annual_years)) 
    first = findfirst(isequal(year), annual_years)
    DF[first:end] = [1/(1+discount)^t for t in 0:(length(annual_years)-first)]

    scc = sum(annual_md .* DF)

    if _is_mid_year     # need to calculate SCC for next year in time index as well, then interpolate for desired year
        lower_scc = scc
        next_year = dice_years[findfirst(isequal(year), dice_years) + 1]
        upper_scc = compute_dice_scc(scenario_choice, gas, next_year, discount, domestic = false, horizon = horizon)
        scc = _interpolate([lower_scc, upper_scc], [year, next_year], [mid_year])[1]
    end 

    if domestic
        @warn("DICE is a global model. Domestic SCC will be calculated as 10% of the global SCC value.")
        return 0.1 * scc
    else
        return scc 
    end
end