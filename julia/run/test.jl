# test.jl


import Pkg
const JULIA_ROOT = normpath(joinpath(@__DIR__, ".."))
Pkg.activate(JULIA_ROOT)

include(joinpath(JULIA_ROOT, "AirTrafficForecaster.jl"))

using DataFrames
using Dates
using JSON3
using Random
using Statistics

using .AirTrafficForecaster

const Registry = AirTrafficForecaster.ModelRegistry
const ForecastService = AirTrafficForecaster.ForecastService
const DataService = AirTrafficForecaster.DataService


const KENZA_MODELS = [
    "kenza",
    "kenza_simplifie",
    "kenza_simplifie_indexe",
    "kenza_indexed",
    "kenza_simplifie_combine",
    "kenza_probabilistic"
]



function metric_value(metrics::Dict, names::Vector{String})
    for name in names
        if haskey(metrics, name)
            return metrics[name]
        end
    end
    return NaN
end

function format_metric(value)
    if value isa Number && isfinite(Float64(value))
        return string(round(Float64(value), digits=3))
    end
    return "n/a"
end

function forecast_interval_width(result::Dict)
    forecast = get(result, "forecast", Any[])
    isempty(forecast) && return NaN
    widths = Float64[]
    for point in forecast
        lower = get(point, "predicted_passengers_lower", nothing)
        upper = get(point, "predicted_passengers_upper", nothing)
        if lower isa Number && upper isa Number
            push!(widths, Float64(upper) - Float64(lower))
        end
    end
    return isempty(widths) ? NaN : mean(widths)
end




function load_data(filepath::String)
    response = DataService.process_uploaded_bytes(basename(filepath), read(filepath))
    if !get(response, "success", false)
        error(get(response, "error", "Unable to load data file"))
    end

    data = get(response, "data", Any[])
    df = DataFrame(data)
    if !("year" in names(df)) || !("actual_passengers" in names(df))
        error("Data must contain year and actual_passengers after normalization")
    end

    sort!(df, :year)
    return df
end

function print_dataset_info(df::DataFrame)
    println("Dataset: $(nrow(df)) observations, $(minimum(df.year))-$(maximum(df.year))")
    println("Columns: $(join(names(df), ", "))")
end


function test_model(
    model_name::String,
    data::DataFrame;
    horizon::Int=5,
    parameters::Dict{String,Any}=Dict{String,Any}(),
)
    println("\n--- Testing model: $model_name ---")

    try
        result = ForecastService.run_forecast(model_name, data, parameters, horizon)
        if haskey(result, "error")
            println("  ERROR: $(result["error"])")
            return result
        end

        metrics = get(result, "metrics", Dict{String,Any}())
        rmse = metric_value(metrics, ["RMSE", "rmse"])
        mae = metric_value(metrics, ["MAE", "mae"])
        r2 = metric_value(metrics, ["R2", "r2"])
        mape = metric_value(metrics, ["MAPE", "mape"])

        println("  RMSE: $(format_metric(rmse))")
        println("  MAE:  $(format_metric(mae))")
        println("  R2:   $(format_metric(r2))")
        println("  MAPE: $(format_metric(mape))")

        forecast = get(result, "forecast", Any[])
        println("  Forecast points: $(length(forecast))")
        println("  Mean interval width: $(format_metric(forecast_interval_width(result)))")

        return result
    catch err
        println("  ERROR: $err")
        return Dict{String,Any}("error" => string(err), "model" => model_name)
    end
end

function compare_models_on_data(
    model_names::Vector{String},
    data::DataFrame;
    horizon::Int=5,
    parameters::Dict{String,Any}=Dict{String,Any}(),
)
    rows = NamedTuple[]
    results = Dict{String,Any}()

    for model_name in model_names
        result = test_model(model_name, data; horizon=horizon, parameters=parameters)
        results[model_name] = result

        metrics = get(result, "metrics", Dict{String,Any}())
        push!(rows, (
            model=model_name,
            status=haskey(result, "error") ? "error" : "ok",
            rmse=metric_value(metrics, ["RMSE", "rmse"]),
            mae=metric_value(metrics, ["MAE", "mae"]),
            r2=metric_value(metrics, ["R2", "r2"]),
            mape=metric_value(metrics, ["MAPE", "mape"]),
            interval_width=forecast_interval_width(result),
        ))
    end

    summary = DataFrame(rows)
    sort!(summary, [:status, :rmse])
    return results, summary
end


function run_tests(;
    data::Union{DataFrame,Nothing}=nothing,
    data_file::Union{String,Nothing}=nothing,
    synthetic::Bool=false,
    n::Int=30,
    models::Vector{String}=KENZA_MODELS,   
    horizon::Int=20,
    parameters::Dict{String,Any}=Dict{String,Any}(),
)
    df = if data !== nothing
        data
    elseif data_file !== nothing
        println("Loading data from file: $data_file")
        load_data(data_file)
    else
        error("Provide data, data_file")
    end

    print_dataset_info(df)

    available = Registry.list_models()
    missing = setdiff(models, available)
    if !isempty(missing)
        error("Unknown models: $(join(missing, ", ")). Available: $(join(available, ", "))")
    end

    println("Available models: $(join(available, ", "))")
    results, summary = compare_models_on_data(models, df; horizon=horizon, parameters=parameters)

    println("\nSummary:")
    show(summary, allcols=true, allrows=true)
    println()



    return results, summary
end

if abspath(PROGRAM_FILE) == @__FILE__
    println("=== Air Traffic Forecaster Model Test Suite ===")
    csv_file=joinpath(JULIA_ROOT, "data","sample.csv")
    run_tests(data_file=csv_file, horizon=20)
    println("\nDone.")
end
