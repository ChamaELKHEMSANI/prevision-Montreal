module KenzaModels
using DataFrames, Statistics, LinearAlgebra, Random
using ..AbstractModel
using ..AbstractModel: AbstractForecastingModel, calculate_metrics, apply_forecast_continuity,
                       rolling_backtest_metrics, growth_rate,
                       INTERVAL_FORFAIT, INTERVAL_RESIDUALS, INTERVAL_BOOTSTRAP
using Optim

# Base for Kenza variants
abstract type AbstractKenzaModel <: AbstractForecastingModel end

mutable struct KenzaModel <: AbstractKenzaModel
    name::String
    description::String
    parameters::Dict{String,Any}
    is_fitted::Bool
    train_data::Union{DataFrame, Nothing}
    metrics::Dict{String,Float64}
    # Kenza-specific
    reference_year::Union{Int,Nothing}
    reference_gdp_per_cap::Union{Float64,Nothing}
    reference_ticket_price::Union{Float64,Nothing}
    continuity_adjustment_factor::Float64
    optimized_params::Dict{String,Float64}
end

function KenzaModel(; name="kenza", description="Kenza model based on income distribution")
    params = Dict{String,Any}(
        "curve_c" => -6.59917386,
        "curve_d" => 0.39546328,
        "distribution_a" => 1.1572,
        "distribution_b" => 4.3517429,
        "kenza_k2" => 30.0,
        "kenza_k1" => 0.8193343775346827,
        "optimize_parameters" => false
    )
    return KenzaModel(name, description, params, false, nothing, Dict(), nothing, nothing, nothing, 1.0, Dict())
end

# Helpers - UNE SEULE DÉFINITION
function _kenza_distribution(r, a::Real, b::Real, c::Real, d::Real)
    # Formule exacte Excel : MIN(1, a * (1 - 1 / (1 + EXP(b + c * r^d))))
    safe_r = max.(Float64.(r), 1e-8)
    exponent = Float64(b) .+ Float64(c) .* (safe_r .^ Float64(d))
    raw = Float64(a) .* (1.0 .- 1.0 ./ (1.0 .+ exp.(exponent)))
    return clamp.(raw, 0.0, 1.0)
end

function _kenza_elasticity(r, a::Real, b::Real, c::Real, d::Real)
    F = _kenza_distribution(r, a, b, c, d)
    safe_r = max.(Float64.(r), 1e-10)
    return Float64(c) .* Float64(d) .* (1 .- F ./ max(Float64(a), 1e-10)) .* (safe_r .^ Float64(d))
end

# Inverse de _kenza_distribution : retrouve r > 0 tel que _kenza_distribution(r,a,b,c,d) == F_target.
# Formule exacte Excel (feuille 'Indexed Kenza', colonne T) :
#   r = (( LN(1/(1-F/a) - 1) - b ) / c) ^ (1/d)
function _invert_kenza_distribution(F_target::Real, a::Real, b::Real, c::Real, d::Real)::Float64
    a, b, c, d = Float64(a), Float64(b), Float64(c), Float64(d)
    Ft = clamp(Float64(F_target), 1e-10, a - 1e-10)
    inner = 1.0 / (1.0 - Ft / a) - 1.0
    inner = max(inner, 1e-300)
    exponent = (log(inner) - b) / c
    exponent = max(exponent, 0.0)
    return exponent^(1.0 / d)
end

# Résout r > 0 tel que _kenza_elasticity(r,a,b,c,d) == target_elasticity.
# Reproduit par dichotomie ce qu'Excel fait par interpolation sur une table (colonnes B:D,
# pas de 0.002, feuille 'Indexed Kenza') — bien plus précis que la table Excel, avec un écart
# négligeable (< 1e-6) par rapport à la valeur trouvée dans le classeur.
function _solve_threshold_for_elasticity(target_elasticity::Real, a::Real, b::Real, c::Real, d::Real;
                                          lo::Float64=1e-6, hi::Float64=10.0,
                                          tol::Float64=1e-12, maxiter::Int=200)::Float64
    f(r) = _kenza_elasticity(r, a, b, c, d) - Float64(target_elasticity)
    flo, fhi = f(lo), f(hi)
    expand_iter = 0
    while sign(flo) == sign(fhi) && expand_iter < 60
        hi *= 1.5
        fhi = f(hi)
        expand_iter += 1
    end
    if sign(flo) == sign(fhi)
        error("Impossible de trouver un seuil r encadrant l'élasticité cible $target_elasticity")
    end
    for _ in 1:maxiter
        mid = (lo + hi) / 2
        fm = f(mid)
        if abs(fm) < tol || (hi - lo) < tol
            return mid
        end
        if sign(fm) == sign(flo)
            lo, flo = mid, fm
        else
            hi, fhi = mid, fm
        end
    end
    return (lo + hi) / 2
end


function _normalized_price(ticket_price, gdp_per_cap, ref_gdp::Float64)::Vector{Float64}
    return Float64.(ticket_price) .* (ref_gdp ./ max.(Float64.(gdp_per_cap), 1e-10))
end

function _full_kenza_index(ticket_price, gdp_per_cap, price_scale::Real)
    return Float64(price_scale) .* Float64.(ticket_price) ./ max.(Float64.(gdp_per_cap), 1e-10)
end

function _kw(kwargs, name::Symbol, default)
    return haskey(kwargs, name) ? kwargs[name] : default
end

function AbstractModel.fit!(model::KenzaModel, data::DataFrame; kwargs...)::Bool
    # Mise à jour des paramètres depuis kwargs
    _update_params!(model.parameters, kwargs)
    
    model.train_data = data
    model.reference_year = data[1, "year"]
    model.reference_gdp_per_cap = data[1, "gdp_per_capita"]
    model.reference_ticket_price = _reference_ticket_price(data)
    
    # Calcul du prix normalisé
    prices = _sanitize_prices(data.ticket_price, model.reference_ticket_price)
    rho_t = _full_kenza_index(prices, data.gdp_per_capita, model.parameters["kenza_k2"])
    
    a = Float64(model.parameters["distribution_a"])
    b = Float64(model.parameters["distribution_b"])
    
    if model.parameters["optimize_parameters"]
        pop = _sanitize_population(data.population)
        actual = data.actual_passengers
        
        # Définition de la fonction objectif
        penetration = Float64(model.parameters["kenza_k1"])
        loss(params) = _kenza_loss(params, rho_t, pop, actual, a, b, penetration)
        
        # Excel maps k1/k2 to the c/d coefficients of the Kenza curve.
        lower = [-20.0, 0.01]
        upper = [20.0, 5.0]
        initial = [Float64(model.parameters["curve_c"]), Float64(model.parameters["curve_d"])]
        
        # Optimisation avec L-BFGS avec bornes
        result = optimize(loss, lower, upper, initial, Fminbox(LBFGS()))
        best_k1, best_k2 = result.minimizer[1], result.minimizer[2]
        model.parameters["curve_c"] = best_k1
        model.parameters["curve_d"] = best_k2
        model.optimized_params = Dict("curve_c"=>best_k1, "curve_d"=>best_k2)
    end
    
    # Calcul des prédictions sur l'entraînement
    F = _kenza_distribution(rho_t, model.parameters["distribution_a"], model.parameters["distribution_b"],
                            model.parameters["curve_c"], model.parameters["curve_d"])
    pred = model.parameters["kenza_k1"] .* _sanitize_population(data.population) .* F
    
    # Facteur de continuité
    model.continuity_adjustment_factor = _recent_continuity_factor(data.actual_passengers, pred)
    
    adjusted = pred .* model.continuity_adjustment_factor
    model.metrics = calculate_metrics(data.actual_passengers, adjusted)
    model.is_fitted = true
    return true
end

function AbstractModel.predict(model::KenzaModel, horizon::Int; kwargs...)::DataFrame
    if !model.is_fitted
        error("Model not fitted")
    end
    
    # La projection macro passe par `_future_macro` plutot que d'etre redupliquee ici :
    # les trois `predict` en portaient chacun une copie, privee des gardes de l'original.
    # Un dernier prix a NaN donnait ainsi une prevision NaN, et un prix manquant une
    # MethodError, pour les seuls modeles qui n'appelaient pas `_future_macro`.
    # Le repli qui suivait ("si pas de prix futur, utiliser le dernier prix historique")
    # remplissait avec `last_price`, c'est-a-dire la valeur manquante elle-meme : sans effet.
    # `_future_macro` retient un prix valide en amont.
    last_year, pops, gdps, prices = _future_macro(model.train_data, horizon, kwargs)
    apply_continuity = _kw(kwargs, :apply_continuity_adjustment, true)
    future_years = collect(last_year+1 : last_year+horizon)

    rho_t = _full_kenza_index(prices, gdps, model.parameters["kenza_k2"])
    F = _kenza_distribution(rho_t, model.parameters["distribution_a"], model.parameters["distribution_b"],
                            model.parameters["curve_c"], model.parameters["curve_d"])
    pred = model.parameters["kenza_k1"] .* pops .* F
    
    if apply_continuity
        pred = pred .* model.continuity_adjustment_factor
    end
    
    # Confidence intervals via Monte Carlo
    n_sims = _kw(kwargs, :monte_carlo_simulations, 0)
    lower = similar(pred); upper = similar(pred)
    
    if n_sims > 0
        train_prices = _sanitize_prices(model.train_data.ticket_price, model.reference_ticket_price)
        train_rho = _full_kenza_index(train_prices, model.train_data.gdp_per_capita,
                                      model.parameters["kenza_k2"])
        train_F = _kenza_distribution(train_rho, model.parameters["distribution_a"], model.parameters["distribution_b"],
                                      model.parameters["curve_c"], model.parameters["curve_d"])
        residuals = model.train_data.actual_passengers .-
                    (model.parameters["kenza_k1"] .* _sanitize_population(model.train_data.population) .* train_F .*
                     model.continuity_adjustment_factor)
        resid_std = std(residuals)
        z = 1.96
        lower = max.(0, pred .- z * resid_std)
        upper = pred .+ z * resid_std
        method = INTERVAL_RESIDUALS
    else
        lower = pred .* 0.8
        upper = pred .* 1.2
        method = INTERVAL_FORFAIT
    end

    df = DataFrame(year=future_years, population=pops, gdp_per_capita=gdps,
                   ticket_price=prices, predicted_passengers=pred,
                   predicted_passengers_lower=lower,
                   predicted_passengers_upper=upper,
                   interval_method=fill(method, horizon))
    
    if apply_continuity
        df = apply_forecast_continuity(df, model.train_data)
    end
    
    df.growth_rate = growth_rate(df.predicted_passengers)
    return df
end

function AbstractModel.validate(model::KenzaModel, validation_data::DataFrame)::Dict{String,Float64}
    if !model.is_fitted
        error("Model not fitted")
    end
    horizon = nrow(validation_data)
    pred_df = predict(model, horizon)
    pred = pred_df.predicted_passengers
    actual = validation_data.actual_passengers
    return calculate_metrics(actual, pred)
end

mutable struct KenzaSimplifieModel <: AbstractKenzaModel
    name::String
    description::String
    parameters::Dict{String,Any}
    is_fitted::Bool
    train_data::Union{DataFrame, Nothing}
    metrics::Dict{String,Float64}
    reference_gdp_per_cap::Float64
    reference_ticket_price::Float64
    continuity_adjustment_factor::Float64
end

function KenzaSimplifieModel(; name="kenza_simplifie", description="Simplified Kenza: demand vs normalized price")
    params = Dict{String,Any}(
        "C1" => -0.5,
        "C2" => 0.5,
        "optimize_parameters" => false
    )
    return KenzaSimplifieModel(name, description, params, false, nothing, Dict(), 1.0, 1.0, 1.0)
end

function AbstractModel.fit!(model::KenzaSimplifieModel, data::DataFrame; kwargs...)::Bool
    _update_params!(model.parameters, kwargs)
    
    model.train_data = data
    model.reference_gdp_per_cap = data[1, "gdp_per_capita"]
    model.reference_ticket_price = _reference_ticket_price(data)
    
    # Normalisation identique à Excel
    ref_gdp = model.reference_gdp_per_cap
    ref_price = model.reference_ticket_price
    pn = (_sanitize_prices(data.ticket_price, ref_price) ./ data.gdp_per_capita) .* (ref_gdp / ref_price)
    pn = clamp.(pn, 0.2, 3.0)
    
    dn = data.actual_passengers ./ _sanitize_population(data.population)
    
    # "C1"/"C2" sont toujours poses par le constructeur : le test `haskey` etait donc toujours
    # vrai et la regression n'etait jamais atteinte. `optimize_parameters=true` etait
    # silencieusement sans effet et le modele tournait en permanence sur les valeurs de
    # remplissage C1=-0.5 / C2=0.5 (R2 = -7.56 sur data/sample.csv).
    if model.parameters["optimize_parameters"]
        X = hcat(pn, ones(length(pn)))
        coef = X \ dn
        model.parameters["C1"] = coef[1]
        model.parameters["C2"] = coef[2]
    end
    
    C1 = model.parameters["C1"]
    C2 = model.parameters["C2"]
    pred_dn = max.(0.0, C1 .* pn .+ C2)
    pred = pred_dn .* _sanitize_population(data.population)
    
    model.continuity_adjustment_factor = _continuity_factor(data.actual_passengers, pred)
    adjusted = pred .* model.continuity_adjustment_factor
    model.metrics = calculate_metrics(data.actual_passengers, adjusted)
    model.is_fitted = true
    return true
end

function AbstractModel.predict(model::KenzaSimplifieModel, horizon::Int; kwargs...)::DataFrame
    if !model.is_fitted
        error("Model not fitted")
    end
    
    # La projection macro passe par `_future_macro` plutot que d'etre redupliquee ici :
    # les trois `predict` en portaient chacun une copie, privee des gardes de l'original.
    # Un dernier prix a NaN donnait ainsi une prevision NaN, et un prix manquant une
    # MethodError, pour les seuls modeles qui n'appelaient pas `_future_macro`.
    last_year, pops, gdps, prices = _future_macro(model.train_data, horizon, kwargs)
    future_years = collect(last_year+1 : last_year+horizon)

    # Même normalisation que dans fit!
    ref_gdp = model.reference_gdp_per_cap
    ref_price = model.reference_ticket_price
    pn = (prices ./ gdps) .* (ref_gdp / ref_price)
    pn = clamp.(pn, 0.2, 3.0)
    
    # Le facteur issu de fit! est le RECALAGE du modele, partie integrante de la calibration
    # Excel des variantes simplifiees (le desactiver fait passer l'ecart Julia/Excel de ~5 %
    # a ~53 % de MAPE). Il reste donc toujours applique ici. `apply_continuity_adjustment`
    # ne pilote que la correction de SAUT entre historique et prevision, qu'Excel ne fait pas
    # et que run/validate.jl desactive explicitement.
    apply_continuity = _kw(kwargs, :apply_continuity_adjustment, true)
    C1 = model.parameters["C1"]; C2 = model.parameters["C2"]
    pred_dn = max.(0.0, C1 .* pn .+ C2)
    pred = pred_dn .* pops .* model.continuity_adjustment_factor

    lower = pred .* 0.8
    upper = pred .* 1.2

    df = DataFrame(year=future_years, population=pops, gdp_per_capita=gdps,
                   ticket_price=prices, predicted_passengers=pred,
                   predicted_passengers_lower=lower, predicted_passengers_upper=upper,
                   interval_method=fill(INTERVAL_FORFAIT, horizon))
    if apply_continuity
        df = apply_forecast_continuity(df, model.train_data)
    end
    df.growth_rate = growth_rate(df.predicted_passengers)
    return df
end

mutable struct KenzaSimplifieIndexeModel <: AbstractKenzaModel
    name::String
    description::String
    parameters::Dict{String,Any}
    is_fitted::Bool
    train_data::Union{DataFrame, Nothing}
    metrics::Dict{String,Float64}
    reference_gdp_per_cap::Float64
    continuity_adjustment_factor::Float64
end

mutable struct KenzaIndexedModel <: AbstractKenzaModel
    name::String
    description::String
    parameters::Dict{String,Any}
    is_fitted::Bool
    train_data::Union{DataFrame, Nothing}
    metrics::Dict{String,Float64}
    reference_gdp_per_cap::Float64
    continuity_adjustment_factor::Float64
    # K1 et K2 de la loi de Kenza (feuille 'Indexed Kenza', cellules B16/B17), calibrees
    # sur les donnees. Les coefficients de forme de la courbe sont parameters["curve_c"] /
    # ["curve_d"].
    kenza_k2::Float64   # Excel B16 : seuil normalisé calé sur l'élasticité de référence
    kenza_k1::Float64   # Excel B17 : échelle calée sur le trafic normalisé de l'année de référence
    last_implied_t::Float64   # Excel colonne T/W : dernier indice de prix implicite observé (historique)
end

function KenzaIndexedModel(; name="kenza_indexed", description="Indexed Kenza: logistic model without direct ticket price")
    params = Dict{String,Any}(
        # a,b,c,d de la courbe Kenza (identiques à Full Kenza : même lookup Ref pour le flux régional)
        "curve_c" => -6.59917386,
        "curve_d" => 0.39546328,
        "distribution_a" => 1.1572,
        "distribution_b" => 4.3517429,
        # Année/valeurs de référence Excel (feuille 'Indexed Kenza', cellules B2/B4/B5/B10) :
        # 0.0 => calculées automatiquement à partir de la 1ère ligne des données si non fournies.
        "ref_year" => 0,
        "ref_gdp_per_capita" => 0.0,
        "ref_normalized_traffic" => 0.0,
        # Élasticité de référence utilisée pour caler le seuil K2 (Excel B10 = 'Simplified Kenza'!X11).
        # Valeur par défaut issue du classeur Kenza.xlsx fourni (flux Canada-USA) ; à recalibrer pour
        # tout autre flux/région via ce paramètre.
        "ref_elasticity" => -1.728566864526717,
        # Excel A1/B1 "Fares (Estim./User's)" : 0 (par défaut Excel) => indice de prix implicite T
        # maintenu CONSTANT sur l'horizon de prévision. Une valeur non nulle le fait croître à ce taux.
        "fare_growth_rate" => 0.0,
        "optimize_parameters" => false
    )
    return KenzaIndexedModel(name, description, params, false, nothing, Dict(), 0.0, 1.0, 0.0, 0.0, 0.0)
end

mutable struct KenzaSimplifieCombineModel <: AbstractKenzaModel
    name::String
    description::String
    parameters::Dict{String,Any}
    is_fitted::Bool
    train_data::Union{DataFrame, Nothing}
    metrics::Dict{String,Float64}
    reference_year::Int
    reference_gdp_per_cap::Float64
    reference_ticket_price::Float64
    trend_coef::Vector{Float64}
    elasticity_coef::Vector{Float64}
    continuity_adjustment_factor::Float64
end

function KenzaSimplifieCombineModel(; name="kenza_simplifie_combine", description="Simplified Kenza with trend and elasticity components")
    params = Dict{String,Any}(
        "trend_weight" => 0.5,
        "optimize_parameters" => false,
        "ticket_price_inflation" => 0.02,
        "population_growth_rate" => 0.01,
        "gdp_growth_rate" => 0.03
    )
    return KenzaSimplifieCombineModel(name, description, params, false, nothing, Dict(), 0, 1.0, 1.0,
                                      Float64[0.0, 0.0], Float64[0.0, 0.0], 1.0)
end

function KenzaSimplifieIndexeModel(; name="kenza_simplifie_indexe", description="Simplified indexed Kenza without direct ticket price")
    params = Dict{String,Any}("C1"=>-0.5, "C2"=>0.5, "optimize_parameters"=>false)
    return KenzaSimplifieIndexeModel(name, description, params, false, nothing, Dict(), 1.0, 1.0)
end

mutable struct KenzaProbabilisticModel <: AbstractForecastingModel
    name::String
    description::String
    parameters::Dict{String,Any}
    is_fitted::Bool
    train_data::Union{DataFrame,Nothing}
    metrics::Dict{String,Float64}
    n_simulations::Int
    bootstrap_type::Symbol
    param_distribution::Union{Dict,Nothing}
    forecast_samples::Union{Matrix{Float64},Nothing}
    quantiles::Union{Dict,Nothing}
    continuity_adjustment_factor::Float64
end

function KenzaProbabilisticModel(; name="kenza_probabilistic",
                                 description="Kenza model with probabilistic calibration via bootstrap",
                                 n_simulations=1000,
                                 bootstrap_type=:parametric)
    params = Dict{String,Any}(
        "curve_c" => -6.59917386,
        "curve_d" => 0.39546328,
        "distribution_a" => 1.1572,
        "distribution_b" => 4.3517429,
        "optimize_parameters" => false,
        "monte_carlo_simulations" => n_simulations,
        # Sans graine, deux executions identiques renvoyaient des previsions differentes
        # (le tirage des residus alimente directement predicted_passengers). 0 = pas de graine.
        "random_seed" => 42
    )
    return KenzaProbabilisticModel(name, description, params, false, nothing, Dict(),
                                   n_simulations, bootstrap_type, nothing, nothing, nothing, 1.0)
end

function AbstractModel.fit!(model::KenzaProbabilisticModel, data::DataFrame; kwargs...)::Bool
    _update_params!(model.parameters, kwargs)
    
    model.train_data = data
    reference_year = data[1, "year"]
    reference_gdp_per_cap = data[1, "gdp_per_capita"]
    reference_ticket_price = _reference_ticket_price(data)
    
    seed = Int(model.parameters["random_seed"])
    seed != 0 && Random.seed!(seed)

    n_sim = model.n_simulations
    k1_samples = Float64[]
    k2_samples = Float64[]

    # Sans optimisation, chacune des n_sim iterations rejouait le meme calcul et empilait
    # des k1/k2 IDENTIQUES (ecart-type nul) : 1000 reechantillonnages pour un resultat
    # constant. On court-circuite la boucle ; l'incertitude vient alors des residus seuls,
    # ce que `param_bootstrap` signale explicitement.
    if !model.parameters["optimize_parameters"]
        k1_samples = fill(Float64(model.parameters["curve_c"]), n_sim)
        k2_samples = fill(Float64(model.parameters["curve_d"]), n_sim)
    end

    for b in (isempty(k1_samples) ? (1:n_sim) : (1:0))
        idx = rand(1:nrow(data), nrow(data))
        boot_data = data[idx, :]
        
        T_t = _sanitize_prices(boot_data.ticket_price, reference_ticket_price) ./ reference_ticket_price
        rho_t = _normalized_price(T_t, boot_data.gdp_per_capita, reference_gdp_per_cap)
        
        if model.parameters["optimize_parameters"]
            pop = _sanitize_population(boot_data.population)
            actual = boot_data.actual_passengers
            best_error = Inf
            best_k1 = Float64(model.parameters["curve_c"])
            best_k2 = Float64(model.parameters["curve_d"])
            
            for k1 in range(-20.0, 20.0, length=41), k2 in range(0.05, 5.0, length=30)
                F = _kenza_distribution(rho_t, model.parameters["distribution_a"], model.parameters["distribution_b"], k1, k2)
                pred = pop .* F
                err = sum((actual .- pred).^2)
                if err < best_error
                    best_error = err
                    best_k1 = Float64(k1)
                    best_k2 = Float64(k2)
                end
            end
        else
            best_k1 = model.parameters["curve_c"]
            best_k2 = model.parameters["curve_d"]
        end
        
        push!(k1_samples, best_k1)
        push!(k2_samples, best_k2)
    end
    
    model.param_distribution = Dict(
        "curve_c" => k1_samples,
        "curve_d" => k2_samples,
        "curve_c_mean" => mean(k1_samples),
        "curve_c_std" => std(k1_samples),
        "curve_d_mean" => mean(k2_samples),
        "curve_d_std" => std(k2_samples)
    )
    
    model.param_distribution["param_bootstrap"] = model.parameters["optimize_parameters"]

    model.parameters["curve_c"] = mean(k1_samples)
    model.parameters["curve_d"] = mean(k2_samples)
    
    T_t = _sanitize_prices(data.ticket_price, reference_ticket_price) ./ reference_ticket_price
    rho_t = _normalized_price(T_t, data.gdp_per_capita, reference_gdp_per_cap)
    F = _kenza_distribution(rho_t, model.parameters["distribution_a"], model.parameters["distribution_b"],
                            model.parameters["curve_c"], model.parameters["curve_d"])
    pred = _sanitize_population(data.population) .* F
    
    model.continuity_adjustment_factor = _recent_continuity_factor(data.actual_passengers, pred)

    adjusted = pred .* model.continuity_adjustment_factor
    residuals = Float64.(data.actual_passengers .- adjusted)
    residuals .-= mean(residuals)
    model.param_distribution["residuals"] = residuals
    model.metrics = calculate_metrics(data.actual_passengers, adjusted)
    
    model.is_fitted = true
    return true
end

function AbstractModel.predict(model::KenzaProbabilisticModel, horizon::Int; kwargs...)::DataFrame
    if !model.is_fitted
        error("Model not fitted")
    end
    
    k1_samples = model.param_distribution["curve_c"]
    k2_samples = model.param_distribution["curve_d"]
    residuals = get(model.param_distribution, "residuals", Float64[])
    n_sim = length(k1_samples)
    
    # La projection macro passe par `_future_macro` plutot que d'etre redupliquee ici :
    # les trois `predict` en portaient chacun une copie, privee des gardes de l'original.
    # Un dernier prix a NaN donnait ainsi une prevision NaN, et un prix manquant une
    # MethodError, pour les seuls modeles qui n'appelaient pas `_future_macro`.
    last_year, pops, gdps, prices = _future_macro(model.train_data, horizon, kwargs)
    apply_continuity = _kw(kwargs, :apply_continuity_adjustment, true)
    future_years = collect(last_year+1 : last_year+horizon)
    
    # Doit reproduire exactement la reference retenue par fit!, garde compris.
    reference_ticket_price = _reference_ticket_price(model.train_data)
    reference_gdp_per_cap = model.train_data[1, "gdp_per_capita"]
    T_t = prices ./ reference_ticket_price
    rho_t = _normalized_price(T_t, gdps, reference_gdp_per_cap)
    
    seed = Int(get(model.parameters, "random_seed", 0))
    seed != 0 && Random.seed!(seed)

    all_preds = Matrix{Float64}(undef, n_sim, horizon)

    for b in 1:n_sim
        k1 = k1_samples[b]
        k2 = k2_samples[b]
        F = _kenza_distribution(rho_t, model.parameters["distribution_a"], model.parameters["distribution_b"], k1, k2)
        pred = pops .* F
        if apply_continuity
            pred .*= model.continuity_adjustment_factor
        end
        if !isempty(residuals)
            pred .+= rand(residuals, horizon)
            pred .= max.(0.0, pred)
        end
        all_preds[b, :] = pred
    end
    
    mean_pred = vec(mean(all_preds, dims=1))
    lower_05 = [quantile(all_preds[:, j], 0.05) for j in 1:horizon]
    lower_25 = [quantile(all_preds[:, j], 0.25) for j in 1:horizon]
    upper_75 = [quantile(all_preds[:, j], 0.75) for j in 1:horizon]
    upper_95 = [quantile(all_preds[:, j], 0.95) for j in 1:horizon]
    
    df = DataFrame(
        year = future_years,
        population = pops,
        gdp_per_capita = gdps,
        ticket_price = prices,
        predicted_passengers = mean_pred,
        predicted_passengers_lower = lower_05,
        predicted_passengers_upper = upper_95,
        predicted_passengers_q25 = lower_25,
        predicted_passengers_q75 = upper_75,
        interval_method = fill(INTERVAL_BOOTSTRAP, horizon)
    )
    
    model.forecast_samples = all_preds
    model.quantiles = Dict(
        "mean" => mean_pred,
        "lower_05" => lower_05,
        "upper_95" => upper_95,
        "lower_25" => lower_25,
        "upper_75" => upper_75
    )
    
    df.growth_rate = growth_rate(df.predicted_passengers)
    
    return df
end

function AbstractModel.validate(model::KenzaProbabilisticModel, validation_data::DataFrame)::Dict{String,Float64}
    if !model.is_fitted
        error("Model not fitted")
    end
    horizon = nrow(validation_data)
    pred_df = predict(model, horizon)
    pred = pred_df.predicted_passengers
    actual = validation_data.actual_passengers
    return calculate_metrics(actual, pred)
end

function get_forecast_samples(model::KenzaProbabilisticModel)
    return model.forecast_samples
end

function AbstractModel.fit!(model::KenzaSimplifieIndexeModel, data::DataFrame; kwargs...)::Bool
    _update_params!(model.parameters, kwargs)
    model.train_data = data
    model.reference_gdp_per_cap = data[1, "gdp_per_capita"]
    
    # Normalisation indexée (inverse du PIB/hab) - CORRECT pour Indexed Kenza
    pn = model.reference_gdp_per_cap ./ max.(data.gdp_per_capita, 1e-8)
    pn = clamp.(pn, 0.2, 3.0)
    
    dn = data.actual_passengers ./ _sanitize_population(data.population)
    
    if model.parameters["optimize_parameters"]
        coef = hcat(pn, ones(length(pn))) \ dn
        model.parameters["C1"] = coef[1]
        model.parameters["C2"] = coef[2]
    end
    
    pred = max.(0.0, model.parameters["C1"] .* pn .+ model.parameters["C2"]) .* _sanitize_population(data.population)
    model.continuity_adjustment_factor = _continuity_factor(data.actual_passengers, pred)
    model.metrics = calculate_metrics(data.actual_passengers, pred .* model.continuity_adjustment_factor)
    model.is_fitted = true
    return true
end

function AbstractModel.predict(model::KenzaSimplifieIndexeModel, horizon::Int; kwargs...)::DataFrame
    _ensure_fitted(model)
    last_year, pops, gdps, prices = _future_macro(model.train_data, horizon, kwargs)
    # Le facteur issu de fit! est le RECALAGE du modele, partie integrante de la calibration
    # Excel des variantes simplifiees (le desactiver fait passer l'ecart Julia/Excel de ~5 %
    # a ~53 % de MAPE). Il reste donc toujours applique ici. `apply_continuity_adjustment`
    # ne pilote que la correction de SAUT entre historique et prevision, qu'Excel ne fait pas
    # et que run/validate.jl desactive explicitement.
    apply_continuity = _kw(kwargs, :apply_continuity_adjustment, true)
    pn = model.reference_gdp_per_cap ./ max.(gdps, 1e-10)
    pred = max.(0, model.parameters["C1"] .* pn .+ model.parameters["C2"]) .* pops .* model.continuity_adjustment_factor
    return _forecast_df(last_year, pops, gdps, prices, pred;
                        training_df=model.train_data, apply_continuity=apply_continuity)
end

function AbstractModel.fit!(model::KenzaIndexedModel, data::DataFrame; kwargs...)::Bool
    _update_params!(model.parameters, kwargs)
    model.train_data = data

    a = Float64(model.parameters["distribution_a"])
    b = Float64(model.parameters["distribution_b"])
    c = Float64(model.parameters["curve_c"])
    d = Float64(model.parameters["curve_d"])

    ref_idx = 1
    if haskey(model.parameters, "ref_year") && Int(model.parameters["ref_year"]) > 0
        found = findfirst(==(Int(model.parameters["ref_year"])), data.year)
        found !== nothing && (ref_idx = found)
    end

    ref_gdp = (haskey(model.parameters, "ref_gdp_per_capita") && Float64(model.parameters["ref_gdp_per_capita"]) > 0) ?
              Float64(model.parameters["ref_gdp_per_capita"]) : Float64(data[ref_idx, "gdp_per_capita"])
    model.reference_gdp_per_cap = ref_gdp

    ref_norm_pax = (haskey(model.parameters, "ref_normalized_traffic") && Float64(model.parameters["ref_normalized_traffic"]) > 0) ?
                   Float64(model.parameters["ref_normalized_traffic"]) :
                   Float64(data[ref_idx, "actual_passengers"]) / _sanitize_population(data.population)[ref_idx]

    ref_elasticity = Float64(get(model.parameters, "ref_elasticity", -1.728566864526717))

    k2 = _solve_threshold_for_elasticity(ref_elasticity, a, b, c, d)
    Fk2 = _kenza_distribution(k2, a, b, c, d)
    k1 = ref_norm_pax / max(Fk2, 1e-12)
    model.kenza_k2 = k2
    model.kenza_k1 = k1

    S = ref_gdp ./ max.(Float64.(data.gdp_per_capita), 1e-10)
    P = Float64.(data.actual_passengers) ./ _sanitize_population(data.population)
    T = [_invert_kenza_distribution(P[i] / k1, a, b, c, d) / max(k2 * S[i], 1e-12) for i in eachindex(P)]
    model.last_implied_t = T[end]

    pred_hist = k1 .* _kenza_distribution(k2 .* T .* S, a, b, c, d) .* _sanitize_population(data.population)
    model.continuity_adjustment_factor = 1.0
    model.is_fitted = true

    # `T` est reconstruit en inversant analytiquement la distribution a partir du trafic
    # OBSERVE ; le reappliquer redonne exactement les donnees d'entree. Les metriques dans
    # l'echantillon valent donc mecaniquement R2 = 1 / RMSE = 0 et ne mesurent aucun pouvoir
    # predictif : run/test.jl classait ce modele premier pour cette seule raison.
    # On publie donc des metriques de validation glissante hors echantillon, en conservant
    # les valeurs in-sample sous des cles `in_sample_*` a titre de controle de calage.
    in_sample = calculate_metrics(data.actual_passengers, pred_hist)
    metrics = Dict{String,Float64}("in_sample_" * k => v for (k, v) in in_sample)
    if _kw(kwargs, :compute_backtest, true)
        backtest = rolling_backtest_metrics(KenzaIndexedModel, data;
                                            params=Dict{String,Any}("compute_backtest" => false))
        merge!(metrics, backtest)
        for key in ("MAE", "MSE", "RMSE", "MAPE", "R2")
            value = get(backtest, "oos_" * key, NaN)
            metrics[key] = value
            metrics[lowercase(key)] = value
        end
    end
    model.metrics = metrics
    return true
end

function AbstractModel.predict(model::KenzaIndexedModel, horizon::Int; kwargs...)::DataFrame
    _ensure_fitted(model)
    last_year, pops, gdps, prices = _future_macro(model.train_data, horizon, kwargs)

    a = Float64(model.parameters["distribution_a"])
    b = Float64(model.parameters["distribution_b"])
    c = Float64(model.parameters["curve_c"])
    d = Float64(model.parameters["curve_d"])

    fare_growth = Float64(_kw(kwargs, :fare_growth_rate, model.parameters["fare_growth_rate"]))
    t_future = model.last_implied_t .* (1.0 .+ fare_growth) .^ (1:horizon)
    s_future = model.reference_gdp_per_cap ./ max.(Float64.(gdps), 1e-10)

    F = _kenza_distribution(model.kenza_k2 .* t_future .* s_future, a, b, c, d)
    pred = model.kenza_k1 .* pops .* F

    return _forecast_df(last_year, pops, gdps, prices, pred;
                        training_df=model.train_data,
                        apply_continuity=_kw(kwargs, :apply_continuity_adjustment, true))
end


function AbstractModel.fit!(model::KenzaSimplifieCombineModel, data::DataFrame; kwargs...)::Bool
    _update_params!(model.parameters, kwargs)
    model.train_data = data
    model.reference_year = Int(data[1, "year"])
    model.reference_gdp_per_cap = Float64(data[1, "gdp_per_capita"])
    model.reference_ticket_price = _reference_ticket_price(data)
    
    dn = Float64.(data.actual_passengers) ./ _sanitize_population(data.population)
    year_index = Float64.(data.year .- model.reference_year)
    pn = _price_index(data.ticket_price, data.gdp_per_capita, model.reference_ticket_price, model.reference_gdp_per_cap)
    
    model.trend_coef = hcat(year_index, ones(length(year_index))) \ dn
    model.elasticity_coef = hcat(pn, ones(length(pn))) \ dn
    
    trend_dn = model.trend_coef[1] .* year_index .+ model.trend_coef[2]
    elasticity_dn = model.elasticity_coef[1] .* pn .+ model.elasticity_coef[2]
    w = clamp(Float64(model.parameters["trend_weight"]), 0.0, 1.0)
    pred_dn = max.(0.0, w .* trend_dn .+ (1.0 - w) .* elasticity_dn)
    pred = pred_dn .* _sanitize_population(data.population)
    
    model.continuity_adjustment_factor = _continuity_factor(data.actual_passengers, pred)
    model.metrics = calculate_metrics(data.actual_passengers, pred .* model.continuity_adjustment_factor)
    model.is_fitted = true
    return true
end

function AbstractModel.predict(model::KenzaSimplifieCombineModel, horizon::Int; kwargs...)::DataFrame
    _ensure_fitted(model)
    last_year, pops, gdps, prices = _future_macro(model.train_data, horizon, kwargs)
    years = collect(last_year+1:last_year+horizon)
    year_index = Float64.(years .- model.reference_year)
    pn = _price_index(prices, gdps, model.reference_ticket_price, model.reference_gdp_per_cap)
    
    trend_dn = model.trend_coef[1] .* year_index .+ model.trend_coef[2]
    elasticity_dn = model.elasticity_coef[1] .* pn .+ model.elasticity_coef[2]
    w = clamp(Float64(model.parameters["trend_weight"]), 0.0, 1.0)
    pred_dn = max.(0.0, w .* trend_dn .+ (1.0 - w) .* elasticity_dn)
    # Le facteur issu de fit! est le RECALAGE du modele, partie integrante de la calibration
    # Excel des variantes simplifiees (le desactiver fait passer l'ecart Julia/Excel de ~5 %
    # a ~53 % de MAPE). Il reste donc toujours applique ici. `apply_continuity_adjustment`
    # ne pilote que la correction de SAUT entre historique et prevision, qu'Excel ne fait pas
    # et que run/validate.jl desactive explicitement.
    apply_continuity = _kw(kwargs, :apply_continuity_adjustment, true)
    pred = pred_dn .* pops .* model.continuity_adjustment_factor

    return _forecast_df(last_year, pops, gdps, prices, pred;
                        training_df=model.train_data, apply_continuity=apply_continuity)
end

"""
Anciens noms de parametres, acceptes pour ne pas casser les appels existants.

`k1` et `k2` designaient les coefficients de forme "c" et "d" de la courbe de Kenza, PAS
les constantes K1 et K2 de la loi — lesquelles vivaient sous `full_penetration` et
`full_price_scale` pour Full Kenza, et sous des champs `calibration_*` pour Indexed Kenza.
Trois conventions pour deux constantes : c'est tres probablement l'origine de l'erreur de
KenzaProbabilisticModel, qui applique la loi en laissant K1 et K2 implicitement a 1.
"""
const _PARAM_ALIASES = Dict(
    "k1" => "curve_c",
    "k2" => "curve_d",
    "k1_c" => "curve_c",
    "k2_d" => "curve_d",
    "full_penetration" => "kenza_k1",
    "full_price_scale" => "kenza_k2",
)

_canonical_param(name) = get(_PARAM_ALIASES, string(name), string(name))

function _update_params!(parameters::Dict{String,Any}, kwargs)
    for (k, v) in kwargs
        key = _canonical_param(k)
        if haskey(parameters, key)
            parameters[key] = v
        end
    end
end

function _ensure_fitted(model)
    model.is_fitted || error("Model not fitted")
end

"""
    _reference_ticket_price(data) -> Float64

Prix de l'annee de reference, garanti fini et strictement positif.

Cette valeur sert de DIVISEUR dans `_price_index` et dans la normalisation de
KenzaSimplifieModel, et de valeur de remplacement des prix individuels invalides. Un zero
ou un NaN en premiere ligne se propageait donc a toute la serie : prevision entierement
nulle pour `kenza_simplifie`, NaN pour `kenza_simplifie_combine`.

Le repli est le premier prix valide de la SERIE, et non 1.0. 1.0 n'a pas d'unite commune
avec un prix de billet : sur des donnees ou le PIB/hab vaut ~3e4, il porte le prix
normalise a ~200, que le `clamp(., 0.2, 3.0)` de KenzaSimplifieModel ramene a 3.0, d'ou
une prevision nulle — le defaut meme que ce garde doit empecher. 1.0 ne subsiste qu'en
dernier recours, si aucune annee ne porte de prix exploitable.
"""
function _reference_ticket_price(data::DataFrame)::Float64
    valid(v) = !ismissing(v) && v isa Number && isfinite(Float64(v)) && Float64(v) > 0
    value = data[1, "ticket_price"]
    valid(value) && return Float64(value)
    idx = findfirst(valid, data.ticket_price)
    if idx === nothing
        @warn "Aucun prix de billet exploitable, prix de reference force a 1.0"
        return 1.0
    end
    @warn "Prix de reference invalide en premiere ligne, repli sur la premiere annee valide" valeur=value annee=data[idx, "year"] remplacement=data[idx, "ticket_price"]
    return Float64(data[idx, "ticket_price"])
end

"""
    _sanitize_population(population) -> Vector{Float64}

Population annuelle garantie finie et strictement positive, chaque valeur inexploitable
etant remplacee par celle de l'annee valide la plus proche.

La population sert de DIVISEUR pour passer au trafic par habitant (`dn = trafic / pop`) et
de MULTIPLICATEUR pour revenir au trafic. Les cinq modeles se protegeaient par
`max.(population, 1e-8)`, ce qui ne protege de rien : une population nulle ne produit plus
une division par zero, elle produit un `dn` de l'ordre de 1e15. Cette valeur domine ensuite
la regression aux moindres carres de KenzaSimplifieCombineModel, dont la droite de tendance
plonge, et le `max.(0.0, .)` qui suit ecrase toute la projection — la prevision sortait
ENTIEREMENT NULLE, sans message, pour un seul zero en premiere ligne.

C'est le meme defaut que celui deja corrige pour les prix (`_reference_ticket_price`), avec
la meme conclusion : substituer une valeur plausible et le dire, plutot que laisser une
donnee degeneree traverser silencieusement le calcul.

Le repli est l'annee valide la plus proche, et non la premiere ni la mediane : une
population evolue de quelques pour cent par an, la voisine immediate en est de loin le
meilleur estimateur.
"""
function _sanitize_population(population)::Vector{Float64}
    valid(v) = !ismissing(v) && v isa Number && isfinite(Float64(v)) && Float64(v) > 0
    n = length(population)
    good = [i for i in 1:n if valid(population[i])]
    isempty(good) && error("Aucune population exploitable : toutes les valeurs sont " *
                           "manquantes, nulles ou negatives.")
    length(good) == n && return Float64[Float64(v) for v in population]
    @warn "Population invalide remplacee par l'annee valide la plus proche" lignes=setdiff(1:n, good) maxlog=1
    nearest(i) = good[argmin(abs.(good .- i))]
    return Float64[Float64(population[valid(population[i]) ? i : nearest(i)]) for i in 1:n]
end

"""
    _sanitize_prices(ticket_price, reference) -> Vector{Float64}

Remplace par `reference` les prix inexploitables (manquants, nuls, negatifs, non finis).

`_price_index` appliquait deja cette substitution ; KenzaModel et KenzaSimplifieModel
consommaient au contraire `data.ticket_price` brut, si bien qu'un seul `missing` dans la
serie historique propageait une MethodError depuis `Float64(::Missing)` — et ce alors que
Validators n'exige la completude que de `year` et `actual_passengers`.

Le test `ismissing` doit precede tout appel a `Float64`, qui n'accepte pas `missing`.
"""
function _sanitize_prices(ticket_price, reference::Float64)::Vector{Float64}
    valid(v) = !ismissing(v) && v isa Number && isfinite(Float64(v)) && Float64(v) > 0
    return Float64[valid(v) ? Float64(v) : reference for v in ticket_price]
end

function _price_index(ticket_price, gdp_per_capita, reference_ticket_price::Float64, reference_gdp::Float64)
    safe_price = _sanitize_prices(ticket_price, reference_ticket_price)
    return safe_price ./ reference_ticket_price .* (reference_gdp ./ max.(gdp_per_capita, 1e-10))
end

function _future_macro(data::DataFrame, horizon::Int, kwargs)
    last_year = data[end, "year"]
    # Une derniere population invalide contaminait toute la projection, comme le faisait
    # un dernier prix invalide avant `_sanitize_prices`.
    last_pop = _sanitize_population(data.population)[end]
    last_gdp = data[end, "gdp_per_capita"]

    gdp_growth = _kw(kwargs, :gdp_growth_rate, 0.03)
    pop_growth = _kw(kwargs, :population_growth_rate, 0.01)
    price_inflation = _kw(kwargs, :ticket_price_inflation, 0.02)

    pops = last_pop .* (1 .+ pop_growth) .^ (1:horizon)
    gdps = last_gdp .* (1 .+ gdp_growth) .^ (1:horizon)

    # `ticket_price` n'intervient dans la formule d'aucun modele indexe : elle n'est lue ici
    # que pour renseigner la colonne de sortie du meme nom. Cette lecture inconditionnelle
    # faisait pourtant echouer `kenza_simplifie_indexe` et `kenza_indexed` sur un fichier
    # sans prix, alors que ModelRegistry.validate_model_data_requirements les declare — a
    # juste titre — utilisables sans. On renvoie `missing` plutot qu'une serie fabriquee a
    # partir d'un prix de reference invente.
    if !("ticket_price" in names(data))
        return last_year, pops, gdps, Vector{Union{Missing,Float64}}(missing, horizon)
    end

    last_price = data[end, "ticket_price"]
    if ismissing(last_price) || !isfinite(Float64(last_price)) || Float64(last_price) <= 0
        last_price = 1.0
    end
    prices = last_price .* (1 .+ price_inflation) .^ (1:horizon)

    return last_year, pops, gdps, prices
end

# `training_df` est optionnel : lorsqu'il est fourni et que `apply_continuity` est vrai, la
# correction de continuite est appliquee ici, comme dans KenzaModel.predict. Auparavant les
# modeles passant par ce constructeur (simplifie indexe, combine, indexed) ignoraient
# totalement le kwarg `apply_continuity_adjustment`.
function _forecast_df(last_year, pops, gdps, prices, pred;
                      training_df=nothing, apply_continuity::Bool=false)
    future_years = collect(last_year+1:last_year+length(pred))
    lower = max.(0, pred .* 0.8)
    upper = pred .* 1.2
    
    df = DataFrame(year=future_years, population=pops, gdp_per_capita=gdps, ticket_price=prices,
                   predicted_passengers=pred, predicted_passengers_lower=lower, predicted_passengers_upper=upper,
                   interval_method=fill(INTERVAL_FORFAIT, length(pred)))
    if apply_continuity && training_df !== nothing
        df = apply_forecast_continuity(df, training_df)
    end
    df.growth_rate = growth_rate(df.predicted_passengers)
    return df
end

"""
    _recent_continuity_factor(actual, pred) -> Float64

Recale le modele sur les dernieres annees observees (20 % de l'echantillon, au moins 3 ans).

La fenetre est bornee par `length(pred)` : `max(3, ...)` seul provoquait un `BoundsError`
des que l'echantillon comptait moins de 3 lignes.
"""
function _recent_continuity_factor(actual, pred)::Float64
    n = length(pred)
    n == 0 && return 1.0
    n_years = clamp(max(3, Int(floor(n * 0.2))), 1, n)
    recent_actual = actual[end - n_years + 1:end]
    recent_pred = pred[end - n_years + 1:end]
    total = sum(recent_pred)
    return total > 0 ? sum(recent_actual) / total : 1.0
end

# UNE SEULE DÉFINITION - Version avec poids croissants (plus proche d'Excel)
function _continuity_factor(actual, pred)
    n = length(pred)
    if n == 0
        return 1.0
    end
    # Utilise toutes les données avec poids croissant
    weights = collect(1.0:1.0:n) ./ sum(1.0:1.0:n)
    if sum(weights .* pred) > 0
        return sum(weights .* actual) / sum(weights .* pred)
    end
    return 1.0
end

function _calibrate_penetration(actual, raw, default::Float64)
    valid = raw .> 0
    any(valid) || return default
    ratio = median(actual[valid] ./ raw[valid])
    return isfinite(ratio) && ratio > 0 ? Float64(ratio) : default
end

_proxy_or_ticket_price(model, data::DataFrame) = data.ticket_price

# `penetration` doit refleter exactement ce que predit le modele. Sans lui, l'optimiseur
# minimisait la SSE de `pop .* F` alors que KenzaModel predit `kenza_k1 .* pop .* F`
# (SSE 1.5x differente sur data/sample.csv) : les k1/k2 retenus n'etaient donc pas optimaux
# pour le modele reellement utilise.
function _kenza_loss(params, rho, pop, actual, a, b, penetration::Real=1.0)
    k1, k2 = params[1], params[2]
    F = _kenza_distribution(rho, a, b, k1, k2)
    pred = Float64(penetration) .* pop .* F
    return sum((actual .- pred).^2)
end

end