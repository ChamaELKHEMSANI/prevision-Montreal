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

# MAPE n'est definie que pour les observations non nulles : un epsilon au denominateur
# ne "protege" pas la division, il fabrique une valeur arbitraire. On ecarte donc les
# observations nulles et on renvoie NaN si aucune n'est exploitable.
function _mape(actual::Vector{Float64}, errors::Vector{Float64})::Float64
    usable = abs.(actual) .> 0
    any(usable) || return NaN
    return mean(abs.(errors[usable] ./ actual[usable])) * 100
end

function calculate_metrics(actual::AbstractVector, predicted::AbstractVector)::Dict{String,Float64}
    n = min(length(actual), length(predicted))
    if n == 0
        return Dict("MAE"=>NaN, "MSE"=>NaN, "RMSE"=>NaN, "MAPE"=>NaN, "R2"=>NaN,
                    "mae"=>NaN, "mse"=>NaN, "rmse"=>NaN, "mape"=>NaN, "r2"=>NaN)
    end
    actual = Float64.(actual[1:n])
    predicted = Float64.(predicted[1:n])
    errors = actual - predicted
    mae = mean(abs.(errors))
    mse = mean(errors.^2)
    rmse = sqrt(mse)
    mape = _mape(actual, errors)
    denominator = sum((actual .- mean(actual)).^2)
    # Une variance nulle rend le R2 indefini : NaN est honnete, 0.0 se confond avec
    # "le modele fait aussi bien que la moyenne".
    r2 = denominator == 0 ? NaN : 1 - sum(errors.^2) / denominator
    return Dict("MAE"=>mae, "MSE"=>mse, "RMSE"=>rmse, "MAPE"=>mape, "R2"=>r2,
                "mae"=>mae, "mse"=>mse, "rmse"=>rmse, "mape"=>mape, "r2"=>r2)
end

"""
    rolling_backtest_metrics(model_factory, data; min_train, horizon, params) -> Dict{String,Float64}

Validation glissante multi-pas : pour chaque annee de coupure au-dela de `min_train`,
ajuste un modele neuf sur l'historique disponible, projette `horizon` annees et compare
chacune a l'observation correspondante.

Necessaire pour les modeles dont l'ajustement est une inversion analytique des donnees
observees (`KenzaIndexedModel`) : leurs metriques dans l'echantillon valent mecaniquement
R2 = 1 / RMSE = 0 et ne mesurent aucun pouvoir predictif.

L'horizon doit rester superieur a 1. Avec `apply_continuity_adjustment` actif — le defaut,
et le comportement de l'application — la premiere annee projetee est ancree sur la derniere
observation d'entrainement : un backtest a un pas reproduit donc exactement la prevision
naive "report de la derniere valeur", identique pour les cinq modeles, et ne les distingue
pas. Seules les annees suivantes revelent la dynamique propre du modele.

Les cles sont prefixees `oos_` (out-of-sample) pour ne jamais etre confondues avec les
metriques dans l'echantillon.
"""
function rolling_backtest_metrics(model_factory, data::DataFrame;
                                  min_train::Int=10, horizon::Int=5,
                                  params::Dict{String,Any}=Dict{String,Any}())
    n = nrow(data)
    start = max(min_train, 3)
    (n <= start || horizon < 1) && return Dict{String,Float64}()
    actuals = Float64[]
    preds = Float64[]
    folds = 0
    for cutoff in start:(n - 1)
        steps = min(horizon, n - cutoff)
        try
            model = model_factory()
            kwargs = [Symbol(k) => v for (k, v) in params]
            fit!(model, data[1:cutoff, :]; kwargs...)
            forecast = predict(model, steps; kwargs...)
            nrow(forecast) < steps && continue
            for step in 1:steps
                push!(preds, Float64(forecast.predicted_passengers[step]))
                push!(actuals, Float64(data[cutoff + step, "actual_passengers"]))
            end
            folds += 1
        catch err
            @debug "Backtest fold ignore" cutoff=data[cutoff, "year"] exception=err
        end
    end
    isempty(preds) && return Dict{String,Float64}()
    metrics = calculate_metrics(actuals, preds)
    out = Dict{String,Float64}("oos_folds" => Float64(folds),
                               "oos_horizon" => Float64(horizon),
                               "oos_points" => Float64(length(preds)))
    for key in ("MAE", "MSE", "RMSE", "MAPE", "R2")
        out["oos_" * key] = metrics[key]
    end
    return out
end

function get_model_info(model::AbstractForecastingModel)::Dict{String,Any}
    return Dict("name"=>model.name, "description"=>model.description, "parameters"=>model.parameters,
                "is_fitted"=>model.is_fitted, "metrics"=>model.metrics)
end


"""
    apply_forecast_continuity(forecast_df, training_df) -> DataFrame

Supprime le saut entre la derniere observation historique et la premiere valeur predite.

`predicted_passengers` (ainsi que les bornes) contient toujours la prevision **finale**,
celle que tracent l'interface et qu'exportent les rapports. La valeur d'avant correction
est conservee dans `predicted_passengers_raw` a des fins de diagnostic.

Auparavant cette fonction ecrivait le resultat dans une colonne separee
`predicted_passengers_adjusted` en laissant `predicted_passengers` inchangee : le
graphique de la GUI et le tableau du PDF affichaient alors deux previsions differentes
(ecart de ~30 % sur `data/sample.csv`) pour un meme calcul.
"""
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
    if !isfinite(factor) || factor <= 0
        return forecast_df
    end
    df = copy(forecast_df)
    df[!, :predicted_passengers_raw] = df.predicted_passengers
    df[!, :predicted_passengers] = df.predicted_passengers .* factor

    for col in ["predicted_passengers_lower", "predicted_passengers_upper"]
        if col in names(df)
            df[!, Symbol(col * "_raw")] = df[!, Symbol(col)]
            df[!, Symbol(col)] = df[!, Symbol(col)] .* factor
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

# Provenance des bornes `predicted_passengers_lower` / `_upper`. Elle est portee par la
# colonne `interval_method` de chaque prevision, pour que l'interface et les exports
# nomment la bande d'apres ce qu'elle est reellement.
#
# L'interface intitulait "IC 95 %" une bande qui, avec les parametres par defaut des cinq
# modeles, vaut exactement pred*0.8 .. pred*1.2 : un forfait sans contenu statistique. La
# branche calculant un vrai intervalle sur les residus ne s'active que si
# `monte_carlo_simulations > 0`, ce qui n'est le defaut d'aucun modele.
const INTERVAL_FORFAIT = "forfait_20pct"
const INTERVAL_RESIDUALS = "residus_z95"
const INTERVAL_BOOTSTRAP = "quantiles_bootstrap"

const _INTERVAL_LABELS = Dict(
    INTERVAL_FORFAIT    => "Bande +/-20 % (indicative, non statistique)",
    INTERVAL_RESIDUALS  => "IC 95 % (residus, z = 1.96)",
    INTERVAL_BOOTSTRAP  => "Intervalle 5-95 % (bootstrap)",
)

"""
    interval_label(method) -> String

Intitule lisible d'une methode d'intervalle, pour les graphiques et les rapports.
Une methode inconnue est nommee prudemment plutot que presentee comme un IC.
"""
interval_label(method) = get(_INTERVAL_LABELS, string(method), "Intervalle (methode inconnue)")

"""
    interval_method(forecast_df) -> String

Methode d'intervalle portee par une prevision. Les previsions produites avant l'ajout de
la colonne sont traitees comme des forfaits, ce qu'elles etaient.
"""
function interval_method(forecast_df)::String
    if forecast_df isa AbstractDataFrame && "interval_method" in names(forecast_df) && nrow(forecast_df) > 0
        return string(forecast_df.interval_method[1])
    end
    return INTERVAL_FORFAIT
end

"""
    growth_rate(values) -> Vector{Float64}

Croissance annuelle en %. Une prevision nulle rend la croissance indefinie (NaN) plutot
que de produire un `Inf`/`NaN` implicite par division par zero, ou un chiffre invente en
plafonnant le denominateur a 1.0 comme le faisait `_forecast_df`.
"""
function growth_rate(values::AbstractVector)::Vector{Float64}
    n = length(values)
    n <= 1 && return zeros(Float64, n)
    v = Float64.(values)
    rates = Vector{Float64}(undef, n)
    rates[1] = 0.0
    for i in 2:n
        rates[i] = v[i - 1] == 0 ? NaN : (v[i] - v[i - 1]) / v[i - 1] * 100
    end
    return rates
end

end
