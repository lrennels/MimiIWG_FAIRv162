using Mimi

@defcomp FAIR_T_exog begin

    T_base = Parameter(index=[time, fair_samples, scenarios])
    T_pulse = Parameter(index=[time, fair_samples, pulse_years, scenarios])

    pulse = Parameter{Bool}(default=false)
    sample_id = Parameter{Int64}(default = 1)
    pulse_year_idx = Parameter{Int64}(default=1)
    gas = Parameter{Symbol}()

    # The number for which scenario to use 
    FAIR_T_exog_scenario_num = Parameter{Integer}()
    
    T = Variable(index=[time])
    T_regions = Variable(index=[time, 8])

    function init(p,v,d)
        if p.pulse # use the pulsed temperature trajectory
            v.T[:] = p.T_pulse[:, p.sample_id, p.pulse_year_idx, p.FAIR_T_exog_scenario_num] # performance note: allocation
        else # use the baseline temperature trajectory
            v.T[:] = p.T_base[:, p.sample_id, p.FAIR_T_exog_scenario_num]
        end

        # TODO downscale to regional temperatures per PAGE implementation
        v.T_regions[:,:] = repeat(v.T[:], 1, 8)

    end
    function run_timestep(p,v,d,t)
    end
end
