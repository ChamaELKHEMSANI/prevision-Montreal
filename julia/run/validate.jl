import Pkg

using CSV
using DataFrames
using Statistics
using Tables

const JULIA_ROOT = normpath(joinpath(@__DIR__, ".."))
Pkg.activate(JULIA_ROOT)

include(joinpath(JULIA_ROOT, "AirTrafficForecaster.jl"))
using .AirTrafficForecaster

const ForecastService = AirTrafficForecaster.ForecastService

const DEFAULT_INPUT = joinpath(JULIA_ROOT, "old", "kenza_excel_validation_input.csv")
const DEFAULT_FULL_INPUT = joinpath(JULIA_ROOT, "old", "kenza_excel_validation_full_input.csv")
const DEFAULT_EXPECTED = joinpath(JULIA_ROOT, "old", "kenza_excel_validation_expected.csv")
const DEFAULT_PARAMS = joinpath(JULIA_ROOT, "old", "kenza_excel_validation_params.csv")
const DEFAULT_OUTPUT = joinpath(JULIA_ROOT, "old", "kenza_excel_validation_report.csv")

function parse_args()
    args = Dict{String,String}()
    i = 1
    while i <= length(ARGS)
        if ARGS[i] in ["--input", "--full-input", "--expected", "--params", "--output"] && i < length(ARGS)
            args[ARGS[i][3:end]] = ARGS[i + 1]
            i += 2
        elseif ARGS[i] in ["--help", "-h"]
            println("Usage: julia julia_1/run/validate.jl [--input CSV] [--full-input CSV] [--expected CSV] [--params CSV] [--output CSV]")
            exit(0)
        else
            i += 1
        end
    end
    return args
end

function numeric_or_nan(v)
    if v === missing || v === nothing
        return NaN
    elseif v isa Number
        return Float64(v)
    else
        s = strip(String(v))
        isempty(s) && return NaN
        try
            return parse(Float64, s)
        catch
            return NaN
        end
    end
end

function param_value(params::DataFrame, source::String, name::String; default=NaN)
    rows = filter(row -> row.source == source && row.name == name, params)
    nrow(rows) == 0 && return default
    return numeric_or_nan(rows.value[1])
end

function forecast_dataframe(result)::DataFrame
    raw = get(result, "forecast", Any[])
    raw isa DataFrame && return raw
    return DataFrame(raw)
end

function run_model(model_name::String, input::DataFrame, params::Dict{String,Any}, horizon::Int)::DataFrame
    result = ForecastService.run_forecast(model_name, input, params, horizon)
    if haskey(result, "error")
        error(result["error"])
    end
    return forecast_dataframe(result)
end

# NOTE (trouvé en validant kenza_indexed) : dans certains exports "expected.csv", la colonne
# excel_indexed_forecast est décalée d'une année : la valeur stockée à l'année Y correspond en
# réalité au calcul Excel de l'année Y+1 (vérifié cellule par cellule sur Kenza.xlsx : la colonne
# L de la feuille 'Indexed Kenza' pour l'année Y correspond à expected[Y-1, excel_indexed_forecast]).
# `year_shift` permet de corriger cet alignement sans modifier le fichier source. Mettre à 0 si le
# fichier "expected" a été régénéré correctement (colonnes alignées sur la bonne année).
function compare_forecast(model_name::String, actual::DataFrame, expected::DataFrame, expected_col::Symbol;
                          year_shift::Int=0)
    expected_shifted = select(expected, :year, expected_col => :excel_prediction)
    expected_shifted.year .-= year_shift
    joined = innerjoin(
        select(actual, :year, :predicted_passengers => :julia_prediction),
        expected_shifted;
        on=:year
    )
    joined.model .= model_name
    joined.excel_column .= String(expected_col)
    joined.error .= joined.julia_prediction .- joined.excel_prediction
    joined.abs_error .= abs.(joined.error)
    joined.pct_error .= ifelse.(joined.excel_prediction .!= 0,
                                100 .* joined.error ./ joined.excel_prediction,
                                NaN)
    return joined
end

function metric_summary(model_name::String, details::DataFrame)
    valid = filter(row -> isfinite(row.excel_prediction) && isfinite(row.julia_prediction), details)
    if nrow(valid) == 0
        return (model=model_name, n=0, mae=NaN, rmse=NaN, mape=NaN, max_abs_error=NaN)
    end
    err = valid.error
    return (
        model=model_name,
        n=nrow(valid),
        mae=mean(abs.(err)),
        rmse=sqrt(mean(err .^ 2)),
        mape=mean(abs.(valid.pct_error)),
        max_abs_error=maximum(abs.(err)),
    )
end

function main()
    args = parse_args()
    input_path = get(args, "input", DEFAULT_INPUT)
    full_input_path = get(args, "full-input", DEFAULT_FULL_INPUT)
    expected_path = get(args, "expected", DEFAULT_EXPECTED)
    params_path = get(args, "params", DEFAULT_PARAMS)
    output_path = get(args, "output", DEFAULT_OUTPUT)

    for path in (input_path, full_input_path, expected_path, params_path)
        isfile(path) || error("Fichier introuvable: $path")
    end

    input = CSV.read(input_path, DataFrame)
    full_input = CSV.read(full_input_path, DataFrame)
    expected_all = CSV.read(expected_path, DataFrame)
    params_table = CSV.read(params_path, DataFrame)

    expected_future = filter(row -> row.is_future == true, expected_all)
    expected_future = filter(row -> row.year <= 2049, expected_future)
    horizon = nrow(expected_future)

    full_params = Dict{String,Any}(
        "distribution_a" => param_value(params_table, "Full Kenza", "distribution_a"),
        "distribution_b" => param_value(params_table, "Full Kenza", "distribution_b"),
        "k1" => param_value(params_table, "Full Kenza", "k1_c"),
        "k2" => param_value(params_table, "Full Kenza", "k2_d"),
        "full_price_scale" => param_value(params_table, "Full Kenza", "full_price_scale"),
        "full_penetration" => param_value(params_table, "Full Kenza", "full_penetration"),
        "optimize_parameters" => false,
        "apply_continuity_adjustment" => false,
        "monte_carlo_simulations" => 0,
    )

    simplified_params = Dict{String,Any}(
        "C1" => param_value(params_table, "Simplified  Kenza", "linear_a"),
        "C2" => param_value(params_table, "Simplified  Kenza", "linear_b"),
        "optimize_parameters" => false,
        "apply_continuity_adjustment" => false,
    )

    indexed_params = Dict{String,Any}(
        "C1" => param_value(params_table, "Simplified  Kenza", "linear_a"),
        "C2" => param_value(params_table, "Simplified  Kenza", "linear_b"),
        "optimize_parameters" => false,
        "apply_continuity_adjustment" => false,
    )

   indexed_logistic_params = Dict{String,Any}(
        "distribution_a" => param_value(params_table, "Indexed Kenza", "distribution_a"),
        "distribution_b" => param_value(params_table, "Indexed Kenza", "distribution_b"),
        "k1" => param_value(params_table, "Indexed Kenza", "k1_c"),
        "k2" => param_value(params_table, "Full Kenza", "k2_d"),
        "ref_year" => param_value(params_table, "Indexed Kenza", "ref_year"),
        "ref_gdp_per_capita" => param_value(params_table, "Indexed Kenza", "ref_gdp_per_capita"),
        "ref_normalized_traffic" => param_value(params_table, "Indexed Kenza", "ref_normalized_traffic"),
        "ref_elasticity" => param_value(params_table, "Indexed Kenza", "simplified_elasticity"),
        "fare_growth_rate" => 0.0,
        "optimize_parameters" => false,
    )

    simplified_combine_params = Dict{String,Any}(
        "trend_weight" => 0.5,
        "optimize_parameters" => true,
    )

    model_specs = [
        ("kenza", full_params, :excel_full_forecast),
        ("kenza_simplifie", simplified_params, :excel_simplified_forecast),
        ("kenza_simplifie_combine", simplified_combine_params, :excel_simplified_forecast),
        ("kenza_simplifie_indexe", indexed_params, :excel_indexed_forecast),
        ("kenza_indexed", indexed_logistic_params, :excel_indexed_forecast),
    ]

    println("Validation Kenza depuis l'ancien classeur Excel")
    println("Input:    $input_path")
    println("Full input: $full_input_path")
    println("Expected: $expected_path")
    println("Horizon compare: $(first(expected_future.year))-$(last(expected_future.year)) ($horizon annees)")
    println()

    all_details = DataFrame()
    summaries = NamedTuple[]

    for (model_name, model_params, excel_col) in model_specs
        println("Execution du modele: $model_name")
        model_input = model_name == "kenza" ? full_input : input
        forecast = run_model(model_name, model_input, model_params, horizon)
        # Décalage connu du fichier "expected" fourni pour excel_indexed_forecast (cf. commentaire
        # sur compare_forecast). Mettre INDEXED_YEAR_SHIFT=0 en variable d'env. si le CSV est corrigé.
        shift = excel_col == :excel_indexed_forecast ? parse(Int, get(ENV, "INDEXED_YEAR_SHIFT", "1")) : 0
        details = compare_forecast(model_name, forecast, expected_future, excel_col; year_shift=shift)
        append!(all_details, details, promote=true)
        push!(summaries, metric_summary(model_name, details))
    end

    summary_df = DataFrame(summaries)
    println()
    println("Resume des ecarts Julia vs Excel")
    show(summary_df, allcols=true, allrows=true)
    println()
    println()
    println("Note: cette validation compare les sorties applicatives Julia avec les sorties cachees Excel.")
    println("Les ecarts peuvent provenir a la fois de la formule et des hypotheses de projection macro futures.")

    output_dir = dirname(output_path)
    !isempty(output_dir) && !isdir(output_dir) && mkpath(output_dir)
    CSV.write(output_path, all_details, writeheader=true, delim=';', quotechar='"', missingstring="NA",
              floatformat=:compact, decimal=',', dateformat="yyyy-mm-dd", timeformat="HH:MM:SS")
    println("Detail annee par annee ecrit dans: $output_path")
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
