"""
    get_model(model::model_choice, scenario_choice::Union{scenario_choice, Nothing} = nothing; gas::Symbol = :HFC23)

Return a Mimi model of the IWG version of the specified `model_choice` and with socioeconomic scenario `scenario_choice`.

`model_choice` must be one of the following enums: DICE, FUND, or PAGE.
`scenario_choice` can be one of the following enums: USG1, USG2, USG3, USG4, or USG5.
If `scenario_choice` is not specified in `get_model`, then the `:scenario_num` parameter in the `:IWGScenarioChoice` 
component must be set to an Integer in 1:5 before the model can be run.
`gas` must be one of :CO2, :CH4, :N2O or one of the :HFCs

Examples

≡≡≡≡≡≡≡≡≡≡

julia> m = MimiIWG_FAIRv162.get_model(DICE, USG1; gas = :CO2)

julia> run(m)

julia> m2 = MimiIWG_FAIRv162.get_model(FUND; gas = :CO2)

julia> using Mimi

julia> set_param!(m2, :IWGScenarioChoice, :scenario_num, 4)

julia> run(m2)
"""
function get_model(model::model_choice, scenario_choice::Union{scenario_choice, Nothing} = nothing; gas::Symbol = :HFC23)

    # dispatch on provided model choice
    if model == DICE 
        return get_dice_model(scenario_choice, gas)
    elseif model == FUND 
        return get_fund_model(scenario_choice, gas)
    elseif model == PAGE 
        return get_page_model(scenario_choice, gas)
    else
        error()
    end
end

"""
    compute_scc(model::model_choice, scenario_choice::scenario_choice; 
        gas::Union{Symbol, Nothing} = nothing,
        year::Union{Int, Nothing}=nothing, 
        discount::Union{Float64, Nothing}=nothing,
        domestic::Bool = false)

Return the deterministic Social Cost of the specified `gas` from one run of the IWG version of 
the Mimi model `model_choice` with socioeconomic scenario `scenario_choice` for the 
specified year `year` and constant dicounting with the specified rate `discount`. If `domestic`
equals `true`, then only domestic damages are used to calculate the SCC. Units of 
the returned SCC value are [2007\$ / metric ton of `gas`]. 

`model_choice` must be one of the following enums: DICE, FUND, or PAGE.
`scenario_choice` must be one of the following enums: USG1, USG2, USG3, USG4, or USG5.
`gas` can be one of :CO2, :CH4, or :N2O, or one of the HFCs, and will default to 
:CO2 if nothing is specified.
"""
function compute_scc(model::model_choice, scenario_choice::scenario_choice = nothing; 
    gas::Union{Symbol, Nothing} = nothing,
    year::Union{Int, Nothing} = nothing, 
    discount::Union{Float64, Nothing} = nothing,
    domestic::Bool = false)

    # Check the gas
    if gas === nothing
        @warn("No `gas` provided to `compute_scc`; will return the SC-CO2.")
        gas = :CO2
    elseif ! (gas in [:CO2, :CH4, :N2O, HFC_list...])
        error("Unknown gas :$gas. Available gases are :CO2, :CH4, and :N2O.")
    end

    # Check the emissions year
    if year === nothing 
        @warn("No `year` provided to `compute_scc`; will return SCC from an emissions pulse in $_default_year.")
        year = _default_year
    end

    # Check the discount rate
    if discount === nothing 
        @warn("No `discount` provided to `compute_scc`; will return SCC for a discount rate of $(_default_discount * 100)%.")
        discount = _default_discount
    end 

    # dispatch on provided model choice
    if model == DICE 
        return compute_dice_scc(scenario_choice, gas, year, discount, domestic = domestic)
    elseif model == FUND 
        return compute_fund_scc(scenario_choice, gas, year, discount, domestic = domestic)
    elseif model == PAGE 
        return compute_page_scc(scenario_choice, gas, year, discount, domestic = domestic)
    else
        error()
    end

end