_dice_simdef = @defsim begin
    FAIR_T_exog.sample_id = Mimi.EmpiricalDistribution(collect(1:_n_fair_samples))
end 

"""
    Returns a Monte Carlo Simulation object.
"""
function get_dice_mcs()
    return deepcopy(_dice_simdef) 
end

function dice_scenario_func(mcs::SimulationInstance, tup::Tuple)
    (scenario_choice, rate) = tup
    global scenario_num = Int(scenario_choice)
    global rate_num = findfirst(isequal(rate), Mimi.payload(mcs)[1])

    base, marginal = mcs.models

    update_param!(base, :scenario_num, scenario_num)
    update_param!(marginal, :scenario_num, scenario_num)

    update_param!(base, :FAIR_T_exog, :FAIR_T_exog_scenario_num, scenario_num)
    update_param!(marginal, :FAIR_T_exog, :FAIR_T_exog_scenario_num, scenario_num)

    Mimi.build!(base)
    Mimi.build!(marginal)
end

function dice_post_trial_func(mcs::SimulationInstance, trial::Int, ntimesteps::Int, tup::Tuple)
    (name, rate) = tup
    (base, marginal) = mcs.models

    rates, discount_factors, model_years, horizon, gas, perturbation_years, SCC_values, SCC_values_domestic, md_values = Mimi.payload(mcs)

    last_idx = horizon - 2005 + 1
    annual_years = dice_years[1]:horizon

    base_consump = base[:neteconomy, :C] 

    DF = discount_factors[rate]             # access the pre-computed discount factor for this rate

    for (idx, pyear) in enumerate(perturbation_years)

        pulse_year_idx = findfirst(i -> i == pyear, _all_pulse_years) # performance memory allocation

        # Call the marginal model with perturbations in each year
        # Update the model instance so the model does not rebuild
        update_param!(marginal.mi, :FAIR_T_exog, :pulse, true)
        update_param!(marginal.mi, :FAIR_T_exog, :pulse_year_idx, pulse_year_idx)
        run(marginal.mi)

        marg_consump = marginal.mi[:neteconomy, :C]
        md = (base_consump .- marg_consump)  * _dice_normalization_factor(gas)     # get marginal damages
        annual_md = _interpolate(md, dice_years, annual_years)  # get annual marginal damages

        first_idx = pyear - 2005 + 1

        scc = sum(annual_md[first_idx:last_idx] ./ DF[1:horizon - pyear + 1])

        SCC_values[trial, idx, scenario_num, rate_num] = scc 
        if md_values !== nothing
            md_values[idx, scenario_num, :, trial] = md
        end
    end
end
