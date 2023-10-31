# MimiIWG_FAIRv162

This is a work-in-progress of the [MimiIWG model](https://github.com/rffscghg/MimiIWG.jl) modified to be coupled to the [FAIR v1.6.2 climate model](https://github.com/FrankErrickson/MimiFAIRv1_6_2.jl) for use in sensitivity analysis of Tan, Rennels, and Parthum (2023) "The Social Costs of Hydrofluorocarbons and the Benefits from Their Expedited Phasedown".

The boilerplate code and input files are available in the following two repositories, and more information on methods and assumptions should be found in the afforementioned publication.

- [MimiFAIRv1_6_2](https://github.com/FrankErrickson/MimiFAIRv1_6_2.jl)
- [MimiIWG](https://github.com/rffscghg/MimiIWG.jl)

## Temperature Trajectories

In order to run `MimiIWG` with `FAIR v1.6.2` we must exogenously load temperature trajectories in the `FAIR_T_exog` component, setting two Parameters:

```
T_base = Parameter(index=[time, fair_samples, scenarios])
T_pulse = Parameter(index=[time, fair_samples, pulse_years, scenarios])
```

We host these data inputs on `Zenodo.com` and download them automatically (~12 GB) to your machine upon running this package, as indicated by the following `__init__()` function specification from `MimiIWG_FAIRv162.jl`.

```
function __init__()
    register(DataDep(
        "mimiiwg_fairv162_paths",
        "MimiIWG FAIRv162 Temperature Paths",
        "https://zenodo.org/record/TODO",
        "TODO",
        post_fetch_method=unpack
    ))
end
```

Please see the `Zenodo.com` dataset [here]() for further data specifications and information.  We also include full replication code for generating these inputs in the Zenodo dataset, as well as here in this repository in `src/mimiiwg_fair162/paths`. To run this code locally, run `mimiiwg_fairv162_paths/main.jl` and the outputs which duplicate those from `Zenodo.com` will be produced in the `mimiiwg_fairv162_paths/output` folder.

## Other Notes

- The `get_model` function now requires `gas` as an argument, as needed by the model to load the correct "pulse" temperature trajectories.
- It is important to check the Methods section of Tan, Rennels, and Parthum 2023 for details on modeling constraints around the estimation methodology assumptions, and note that the work thus far was done with a focus on HFCs though could be further improved to explore other gases.
