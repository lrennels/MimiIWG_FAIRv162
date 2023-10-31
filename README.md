# MimiIWG_FAIRv162

This is a work-in-progress version of MimiIWG modified to be coupled to FAIR v1.6.2. It is used in part for Tan, Rennels, and Parthum (2023), "The Social Costs of Hydrofluorocarbons and the Benefits from Their Expedited Phasedown" which contains further descriptions of modeling choices.

The boilerplate code and input files are available in the following two repositories:

- [MimiFAIRv1_6_2](https://github.com/FrankErrickson/MimiFAIRv1_6_2.jl)
- [MimiIWG](https://github.com/rffscghg/MimiIWG.jl)

## Temperature Trajectories

In order to run `MimiIWG` with `FAIR v1.6.2` we first preprocess the exogenous temperature trajectories to be loaded for each run. These files are saved in `src/fairv162_paths/output` with one file per gas-socioeconomic combination. For each of 2237 FAIR parameter sets we have a baseline run and a pulse run for each of the pulse years. The underlying emissions for each run are using the FAIR v1.6.2 background emissions settings and then forcing CO2, N2O, and CH4 with emf sceanrios from 2005 to 2300.

These trajectories serve as inputs to the `FAIR_T_exog` component Parameters:

```
T_base = Parameter(index=[time, fair_samples, scenarios])
T_pulse = Parameter(index=[time, fair_samples, pulse_years, scenarios])
```

### Replication Code

The subfolder `src/fairv162_paths` contains all scripts and data used to compute the FAIR v1.6.2 temperature trajectories resulting from using FAIR v1.6.2 background emissions settings, forcing CO2, N2O, and CH4 with emf scenarios from 2005 to 2300, and adding a pulse of 1 GtC for CO2 and 1 Mt for any given HFC. Running `src/core/fairv162/src/main.jl` will produce the input files necessary for computing the SC-HFCs with this model. This only needs to be done _once_ locally and these can then be reused, the output `.arrow` files will be output to the `src/fairv162_paths/output` folder.  **NOTE** this should not be necessary for the average user, we use the `DataDeps` package to load our pre-calculated outputs into this folder but retain replication code for completeness.

## Other Modification Notes

- The `get_model` function now requires `gas` as an argument, as needed by the model to load the correct "pulse" temperature trajectories.
- Roe and Baker climate sensitivity distribution is no longer used here, replaced with climate dynamics and uncertainty in FAIR v1.6.2 and AR6 constrained parameter set
