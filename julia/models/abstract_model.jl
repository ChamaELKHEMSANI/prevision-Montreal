module AbstractModel

using DataFrames, Statistics, LinearAlgebra

abstract type AbstractForecastingModel end


function fit!(model::AbstractForecastingModel, data::DataFrame; kwargs...)::Bool
    error("fit! not implemented for $(typeof(model))")
end

function predict(model::AbstractForecastingModel, horizon::Int; kwargs...)::DataFrame
    error("predict not implemented for $(typeof(model))")
end


function validate(model::AbstractForecastingModel, validation_data::DataFrame)::Dict{String,Float64}
    error("validate not implemented for $(typeof(model))")
end

function calculate_metrics(actual::AbstractVector, predicted::AbstractVector)::Dict{String,Float64}
    n = min(length(actual), length(predicted))
    if n == 0
        return Dict("MAE"=>0.0, "MSE"=>0.0, "RMSE"=>0.0, "MAPE"=>0.0, "R2"=>0.0,
                    "mae"=>0.0, "mse"=>0.0, "rmse"=>0.0, "mape"=>0.0, "r2"=>0.0)
    end
    actual = Float64.(actual[1:n])
    predicted = Float64.(predicted[1:n])
    errors = actual - predicted
    mae = mean(abs.(errors))
    mse = mean(errors.^2)
    rmse = sqrt(mse)
    mape = mean(abs.(errors ./ (actual .+ 1e-10))) * 100
    denominator = sum((actual .- mean(actual)).^2)
    r2 = denominator == 0 ? 0.0 : 1 - sum(errors.^2) / denominator
    return Dict("MAE"=>mae, "MSE"=>mse, "RMSE"=>rmse, "MAPE"=>mape, "R2"=>r2,
                "mae"=>mae, "mse"=>mse, "rmse"=>rmse, "mape"=>mape, "r2"=>r2)
end

function get_model_info(model::AbstractForecastingModel)::Dict{String,Any}
    return Dict("name"=>model.name, "description"=>model.description, "parameters"=>model.parameters,
                "is_fitted"=>model.is_fitted, "metrics"=>model.metrics)
end


function apply_forecast_continuity(forecast_df::DataFrame, training_df::DataFrame)::DataFrame
    if !("predicted_passengers" in names(forecast_df)) || !("actual_passengers" in names(training_df))
        return forecast_df
    end
    preds = forecast_df.predicted_passengers
    actuals = skipmissing(training_df.actual_passengers) |> collect
    if isempty(preds) || isempty(actuals)
        return forecast_df
    end
    first_pred = preds[1]
    last_actual = actuals[end]
    if first_pred <= 0 || last_actual <= 0
        return forecast_df
    end
    factor = last_actual / first_pred
    if factor <= 0
        return forecast_df
    end
    df = copy(forecast_df)
    df[!, :predicted_passengers_raw] = df.predicted_passengers
    df[!, :predicted_passengers_adjusted] = df.predicted_passengers .* factor
    
    for col in ["predicted_passengers_lower", "predicted_passengers_upper"]
        if col in names(df)
            df[!, Symbol(col * "_adjusted")] = df[!, Symbol(col)] .* factor
        end
    end
    n = nrow(df)
    df[!, :continuity_adjustment_factor] = fill(factor, n)
    df[!, :continuity_reference_passengers] = fill(last_actual, n)
    df[!, :continuity_gap] = fill(first_pred - last_actual, n)
    df[!, :continuity_gap_pct] = fill((first_pred - last_actual) / last_actual * 100, n)
    df[!, :continuity_adjustment_applied] = fill(true, n)
    return df
end

end
