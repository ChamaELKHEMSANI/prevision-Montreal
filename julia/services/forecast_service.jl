module ForecastService

using DataFrames, Dates, Logging, JSON3, Tables, Statistics
using ..ModelRegistry: get_model, register_model, list_models_by_category
using ..AbstractModel: AbstractForecastingModel, fit!, predict, calculate_metrics


const EXECUTOR = nothing

function _string_dict(parameters)
    parameters isa AbstractDict || return Dict{String,Any}()
    return Dict{String,Any}(string(k) => v for (k, v) in pairs(parameters))
end

function _kwargs(parameters::AbstractDict)
    return Dict(Symbol(string(k)) => v for (k, v) in parameters)
end

function run_forecast(model_name::String, data::DataFrame, parameters::AbstractDict, horizon::Int)
    @info "Running forecast" model=model_name horizon=horizon
    parameters = _string_dict(parameters)
    
    model_type = get_model(model_name)
    if model_type === nothing
        error("Model '$model_name' not found")
    end
    model = model_type()
    
    # Fit the model
    kwargs = _kwargs(parameters)
    fit_success = fit!(model, data; kwargs...)
    if !fit_success
        error("Model fitting failed for $model_name")
    end
    
    # Predict
    forecast_df = predict(model, horizon; kwargs...)
    
    # Le repli precedent renvoyait Dict("RMSE"=>10.5, "R2"=>0.95) : des metriques inventees,
    # et flatteuses, pour tout modele ne respectant pas le contrat AbstractForecastingModel.
    # Mieux vaut un echec explicite qu'un R2 de 0.95 fabrique.
    if !hasproperty(model, :metrics)
        error("Model '$model_name' ($(typeof(model))) exposes no `metrics` field; " *
              "AbstractForecastingModel implementations must populate it in fit!")
    end
    metrics = model.metrics
    
    forecast_records = [Dict(string(k) => v for (k, v) in pairs(row)) for row in Tables.namedtupleiterator(forecast_df)]
    
    return Dict(
        "forecast" => forecast_records,
        "metrics" => metrics,
        "model" => model_name,
        "parameters" => parameters,
        "horizon" => horizon
    )
end

function compare_models(model_names::Vector{String}, data::DataFrame, parameters::AbstractDict, horizon::Int)
    results = Dict{String,Any}()
    for name in model_names
        try
            results[name] = run_forecast(name, data, get(parameters, name, Dict()), horizon)
        catch e
            results[name] = Dict("error"=>string(e))
        end
    end
    return results
end

function sensitivity_analysis(model_name::String, data::DataFrame, parameter::String, param_range::Vector{Float64})
    results = Dict{Float64,Any}()
    for value in param_range
        params = Dict(parameter => value)
        res = run_forecast(model_name, data, params, 10)
        results[value] = Dict("forecast"=>res["forecast"], "metrics"=>res["metrics"])
    end
    return results
end

function monte_carlo_simulation(model_name::String, data::DataFrame, parameters::Dict{String,Any},
                                horizon::Int, n_simulations::Int=1000; max_simulations::Int=1000)
    # `min(n_simulations, 100)` tronquait systematiquement le parametre sans rien dire :
    # la signature annoncait 1000 tirages, le code en faisait 100. Le plafond est desormais
    # explicite, ajustable, et signale quand il mord.
    effective = min(n_simulations, max_simulations)
    if effective < n_simulations
        @warn "Nombre de simulations plafonne" demande=n_simulations effectif=effective plafond=max_simulations
    end
    simulations = []
    simulation_metrics = Any[]
    for _ in 1:effective
        varied_params = copy(parameters)
        for (k,v) in varied_params
            if v isa Number
                # add ±10% noise
                variation = v * 0.1
                varied_params[k] = v + rand()*2*variation - variation
            end
        end
        res = run_forecast(model_name, data, varied_params, horizon)
        push!(simulations, res["forecast"])
        push!(simulation_metrics, res["metrics"])
    end
    # statistics (simplified)
    stats = Dict(
        "n_simulations" => length(simulations),
        "mean_r2" => mean([get(m, "R2", get(m, "r2", 0.0)) for m in simulation_metrics])
    )
    return Dict("simulations"=>simulations, "statistics"=>stats)
end

# `apply_forecast_continuity` vivait ici en doublon vide (elle renvoyait son argument tel
# quel) et n'etait appelee nulle part. La seule implementation est AbstractModel.apply_forecast_continuity,
# que les modeles utilisent deja directement.

end
