
module MimiIWG_FAIRv162

using Dates
using DelimitedFiles
using Distributions
using Interpolations
using Mimi
using MimiDICE2010
using MimiFUND          # pinned to version 3.8 in package registration Compat.toml
using MimiPAGE2009      
using StatsBase
using XLSX: readxlsx, openxlsx, readdata
using CSVFiles
using DataFrames
using Query
using Statistics
using Arrow

export DICE, FUND, PAGE, # export the enumerated model_choice options
        USG1, USG2, USG3, USG4, USG5 # export the enumerated scenario_choice options 

# General constants and functions
include("core/constants.jl")
include("core/utils.jl")

# IWG modified components
include("components/IWG_DICE_ScenarioChoice.jl")
include("components/IWG_DICE_neteconomy.jl")
include("components/IWG_FUND_impactsealevelrise.jl")
include("components/IWG_FUND_ScenarioChoice.jl")
include("components/IWG_PAGE_ClimateTemperature.jl")
include("components/IWG_PAGE_ScenarioChoice.jl")
include("components/IWG_PAGE_GDP.jl")
include("components/IWG_RoeBakerClimateSensitivity.jl")

# FAIR Tempearture component
include("components/FAIR_T_exog.jl")

# Main models and functions
include("core/DICE_main.jl")
include("core/FUND_main.jl")
include("core/PAGE_main.jl")
include("core/main.jl")

# Monte carlo support
include("montecarlo/DICE_mcs.jl")
include("montecarlo/FUND_mcs.jl")
include("montecarlo/PAGE_mcs.jl")
include("montecarlo/run_scc_mcs.jl")


end