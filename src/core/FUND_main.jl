"""
    Returns the IWG version of the FUND3.8 model without any scenario parameters set yet. 
    Need to call apply_scenario!(m, scenario_choice) before this model can be run.
"""
function get_fund_model(scenario_choice::Union{scenario_choice, Nothing} = nothing, gas::Union{Nothing, Symbol}=nothing)

    # Get the default FUND model
    m = getfund()

    # Set time dimension to shorten it
    set_dimension!(m, :time, fund_years)

    # Add dimensions required for FAIR exogenous temperature component
    set_dimension!(m, :fair_samples, _n_fair_samples)
    set_dimension!(m, :pulse_years, length(_all_pulse_years))
    set_dimension!(m, :scenarios, length(scenarios))

    # Replace the Impact Sea Level Rise component
    replace!(m, :impactsealevelrise => IWG_FUND_impactsealevelrise)

    # Remove the climate modules; temperature is now exogenous
    # note for now we leave in the climateco2cycle because the accumulated 
    # emissions are used by some damages components -- emissions are consistent 
    # with what we used for temperature
    for c in [:climaten2ocycle, :climatech4cycle, :climatesf6cycle, :climateso2cycle, :climateforcing, :climatedynamics]
        delete!(m, c)
    end

    # Add the scenario choice component and load all the scenario parameter values
    add_comp!(m, IWG_FUND_ScenarioChoice, :IWGScenarioChoice; before = :population)
    set_fund_all_scenario_params!(m)

    # Set the scenario number if a scenario_choice was provided
    if scenario_choice !== nothing 
        scenario_num = Int(scenario_choice)
        set_param!(m, :IWGScenarioChoice, :scenario_num, scenario_num)
    end

    ##
    ## Handle Exogenous Temperature
    ##

    # Add FAIR exogenous temperature component
    add_comp!(m, FAIR_T_exog, before=:biodiversity);

    # Reconnect temperature where needed
    connect_param!(m, :climateregional => :inputtemp, :FAIR_T_exog => :T)
    connect_param!(m, :biodiversity => :temp, :FAIR_T_exog => :T)
    connect_param!(m, :ocean =>  :temp, :FAIR_T_exog => :T)
    connect_param!(m, :climateco2cycle => :temp, :FAIR_T_exog => :T)
 
    # Set temperature trajectories
    n_fund_years = length(fund_years)
    n_scenarios = length(scenarios)
    n_pulse_years = length(_all_pulse_years)

    T_key = Arrow.Table(joinpath(datadep"mimiiwg_fairv162_temp_trajectories", "temperature_T_KEY.arrow")) |> DataFrame
    T_base = Array{Float64}(undef, n_fund_years, _n_fair_samples, n_scenarios)
    T_pulse = Array{Float64}(undef, n_fund_years, _n_fair_samples, n_pulse_years, n_scenarios)
    
    for scenario in scenarios

        # load the temperature path
        T = Arrow.Table(joinpath(datadep"mimiiwg_fairv162_temp_trajectories", "T_$(gas)_$(emf_scenarios[Int(scenario)]).arrow")) |> DataFrame
        T = hcat(T_key, T) |> @filter(_.time in fund_years) |> DataFrame

        # Set BASE temperature trajectories
        T_base_scenario = unstack(select(T, :time, :trialnum, :T_base), :trialnum, :T_base) |> DataFrame
        T_base[:,:,Int(scenario)] = max.(T_base_scenario[:,2:end] |> Matrix, 0.) # remove negative temperature anomalies

        # Set PULSE temperature trajectories
        T_pulse_scenario = Array{Float64}(undef, n_fund_years, _n_fair_samples, n_pulse_years)
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
set_fund_all_scenario_params!(m::Model; comp_name::Symbol = :IWGScenarioChoice, connect::Boolean = true)
    m: a Mimi model with and IWGScenarioChoice component
    comp_name: the name of the IWGScenarioChoice component in the model, defaults to :IWGScenarioChoice
    connect: whether or not to connect the outgoing variables to the other components who depend on them as parameter values
"""
function set_fund_all_scenario_params!(m::Model; comp_name::Symbol = :IWGScenarioChoice, connect::Bool = true)

    # reshape each array of values into one array for each param, then set that value in the model
    for (k, v) in _fund_scenario_params_dict

        _size = size(v[1])
        param = zeros(_size..., 5)
        for i in 1:5
            param[[1:l for l in _size]..., i] = v[i]
        end

        idxs = indexin(fund_years, dim_keys(m, :time))
        if _size[1] == 1051
            if ndims(param) == 3
                param = param[idxs,:,:]
            elseif ndims(param) == 2
                param = param[idxs,:]
            end
        end

        set_param!(m, comp_name, Symbol("$(k)_all"), param)
    end

    if connect 

        # Socioeconomics
        connect_all!(m, [:population, :socioeconomic, :emissions], comp_name => :pgrowth)
        connect_all!(m, [:socioeconomic, :emissions], comp_name => :ypcgrowth)
        connect_param!(m, :emissions => :aeei, comp_name => :aeei)
        connect_param!(m, :emissions => :acei, comp_name => :acei)

    end
end

"""
    Returns marginal damages each year from an additional emissions pulse of the specified `gas` in the specified `year`. 
    User must specify an IWG scenario `scenario_choice`.
    If no `gas` is sepcified, will run for an emissions pulse of CO2.
    If no `year` is specified, will run for an emissions pulse in $_default_year.
    If no `discount` is specified, will return undiscounted marginal damages.
    The `income_normalized` parameter indicates whether the damages from the marginal run should be scaled by the ratio of incomes between the base and marginal runs. 
"""
function get_fund_marginaldamages(scenario_choice::scenario_choice, gas::Symbol, year::Int, discount::Float64; regional::Bool = false, income_normalized::Bool=true)

    # Check the emissions year
    if ! (year in fund_years)
        error("$year not a valid year; must be in model's time index $fund_years.")
    end

    pulse_year_idx = findfirst(i -> i == year, _all_pulse_years)
    base = get_fund_model(scenario_choice, gas)
    marginal = Model(base)

    # TODO update emissions as well to handle components that take cumulative co2 as 
    # a direct input (eg. agriculture)
    update_param!(marginal, :FAIR_T_exog, :pulse, true)
    update_param!(marginal, :FAIR_T_exog, :pulse_year_idx, pulse_year_idx)

    run(base)
    run(marginal)

    damages1 = base[:impactaggregation, :loss]
    if income_normalized
        damages2 = marginal[:impactaggregation, :loss] ./ marginal[:socioeconomic, :income] .* base[:socioeconomic, :income]
    else
        damages2 = marginal[:impactaggregation, :loss]
    end

    pulse_size = gas == :CO2 ?  1e-9 * 12/44 : 1e-6  # 1e-9 * 12/44 to convert from per GtC to per tCO2; 1e6 for Mt to t

    if regional
        diff = (damages2 .- damages1) * pulse_size * fund_inflator
    else
        diff = sum((damages2 .- damages1), dims = 2) * pulse_size * fund_inflator   
    end

    nyears = length(fund_years)
    if discount != 0 
        DF = zeros(nyears)
        first = MimiFUND.getindexfromyear(year)
        DF[first:end] = [1/(1+discount)^t for t in 0:(nyears-first)]
        return diff[1:nyears, :] .* DF
    else
        return diff[1:nyears, :]
    end

end

"""
    Returns the Social Cost of `gas` for a given `year` and `discount` rate from one deterministic run of the IWG-FUND model.
    User must specify an IWG scenario `scenario_choice`.
    If no `gas` is specified, will retrun the SC-CO2.
    If no `year` is specified, will return SC for $_default_year.
    If no `discount` is specified, will return SC for a discount rate of $(_default_discount * 100)%.
"""
function compute_fund_scc(scenario_choice::scenario_choice, gas::Symbol, year::Int, discount::Float64; domestic::Bool = false, income_normalized::Bool = true)

    # Check the emissions year
    if !(year in fund_years)
        error("$year is not a valid year; can only calculate SCC within the model's time index $fund_years.")
    end

    if domestic
        md = get_fund_marginaldamages(scenario_choice, gas, year, discount, income_normalized = income_normalized, regional = true)[:, 1]
    else
        md = get_fund_marginaldamages(scenario_choice, gas, year, discount, income_normalized = income_normalized, regional = false)
    end
    scc = sum(md[MimiFUND.getindexfromyear(year):end])    # Sum from the perturbation year to the end (avoid the NaN in the first timestep)
    return scc 
end