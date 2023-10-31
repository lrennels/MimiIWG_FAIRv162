using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
Pkg.instantiate() 

using MimiFAIRv1_6_2, Mimi, CSVFiles, Query, DataFrames, Interpolations, MimiGIVE, Arrow

include("helper.jl")

datadir = joinpath(@__DIR__, "..", "data")
outdir = joinpath(@__DIR__, "..", "output")
mkpath(outdir)

ntrials = 2237 # maximum number, will run each once
pulse_years = collect(2015:5:2105)

gases = [:HFC23, :HFC32, :HFC43_10, :HFC125, :HFC134a, :HFC143a, :HFC227ea, :HFC245fa, :HFC152a, :HFC236fa, :HFC365mfc, :CO2]

# get temperature trajectories for all models for all FAIR samples
for emf_scenario in [:IMAGE, :MERGE, :MESSAGE, :MiniCAM, :Scen5]
    for gas in gases

        println("Calculating temperature trajectories for $emf_scenario $gas ...")
        if gas == :CO2
            pulse_size = 1. # 1 GtC
        else
            pulse_size = 1e3 # 1 Mt HFCs
        end
        
        # get the model 
        m = get_emf_fair(emf_scenario, datadir)

        # create an array of marginal models with the base model and one model 
        # with a pulse in each year
        models = [m]
        for year in pulse_years
            if gas == :CO2
                mm = Mimi.create_marginal_model(m, MimiGIVE.scc_gas_pulse_size_conversions[gas] .* pulse_size)
                time = Mimi.dim_keys(mm.modified, :time)
                pulse_year_index = findfirst(i -> i == year, time)

                # for now this will return :E_co2 because it is treated as a 
                # shared parameter in MimiFAIRv1_6_2, and thus also in this model, but this
                # line keeps us robust if it becomes an unshared parameter.
                model_param_name = Mimi.get_model_param_name(mm.modified, :co2_cycle, :E_co2)

                # obtain the base emissions values from the model - the following line 
                # allows us to do so without running the model. If we had run the model
                # we can use deepcopy(m[:co2_cycle, :E_co2])
                new_emissions = deepcopy(Mimi.model_param(mm.modified, model_param_name).values.data)

                # update emissions parameter with a pulse
                new_emissions[pulse_year_index] +=  pulse_size # add pulse in GtC

                update_param!(mm.modified, :E_co2, new_emissions)
                push!(models, mm.modified)
            else
                mm = MimiGIVE.get_marginal_model(m; year = year, gas = gas, pulse_size = pulse_size);
                push!(models, mm.modified)
            end
        end

        # Set up output directories
        scenario_outdir = joinpath(outdir, "$(gas)_$(emf_scenario)")
        mkpath(scenario_outdir)

        # Get an instance of the mcs
        mcs = MimiFAIRv1_6_2.get_mcs();
        Mimi.delete_save!(mcs, (:co2_cycle, :co2))

        # run monte carlo trials
        Mimi.run(mcs, models, ntrials; results_output_dir = scenario_outdir, results_in_memory=false);

        # post-process to save some space
        base_temperature = load(joinpath(scenario_outdir, "model_1", "temperature_T.csv")) |> DataFrame
        df = DataFrame(:T_base => base_temperature.T)
        for (i, pulse_year) in enumerate(pulse_years)
            pulse_temperature = load(joinpath(scenario_outdir, "model_$(i+1)", "temperature_T.csv")) |> DataFrame
            insertcols!(df, Symbol("T_pulse_$(pulse_year)") => pulse_temperature.T)
        end

        Arrow.write(joinpath(outdir, "T_$(gas)_$(emf_scenario).arrow"), df) 

        # save the key just once
        if emf_scenario == :IMAGE && gas == :HFC23
            df = select(base_temperature, [:time, :trialnum]) 
            Arrow.write(joinpath(outdir, "temperature_T_KEY.arrow"), df) 
        end

        rm(scenario_outdir, recursive=true)
    end
end
