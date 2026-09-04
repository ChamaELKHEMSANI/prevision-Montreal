# evaluate_pair.jl
#
# Ajuste les modeles Kenza sur une paire de villes et rapporte leur performance HORS
# ECHANTILLON, comparee a des references naives.
#
# Pourquoi des references naives
#   Un R2 dans l'echantillon ne dit rien du pouvoir predictif — pour `kenza_indexed` il vaut
#   meme 1 par construction. Et un R2 hors echantillon negatif signifie « moins bon que la
#   moyenne ». Un modele qui ne bat pas le report de la derniere valeur observee n'apporte
#   rien qu'une regle d'une ligne ne donnerait.
#
# Portee
#   Les series produites par `extract_city_pairs.jl` ne portent pas de tarif : seuls les
#   modeles indexes sont evaluables. `kenza` et `kenza_simplifie` exigent `ticket_price`.
#
# Usage
#   julia --project=julia julia/run/evaluate_pair.jl \
#       --series julia/data/yul_series.csv --pair YUL-YYZ --horizon 3

import Pkg
const JULIA_ROOT = normpath(joinpath(@__DIR__, ".."))
Pkg.activate(JULIA_ROOT)

# Reinclure le module en creerait une SECONDE instance, distincte de la premiere : les
# types n'y sont pas les memes, et `fit!(::KenzaModel, ::DataFrame)` echouerait avec une
# MethodError deroutante. On ne l'inclut donc que s'il n'est pas deja charge — cas d'un
# script inclus depuis une session, par exemple run/regressions.jl.
isdefined(Main, :AirTrafficForecaster) || include(joinpath(JULIA_ROOT, "AirTrafficForecaster.jl"))

using CSV
using DataFrames
using Printf
using Statistics
using .AirTrafficForecaster

const Abstract = AirTrafficForecaster.AbstractModel
const Registry = AirTrafficForecaster.ModelRegistry

# Modeles n'exigeant pas `ticket_price`, cf. ModelRegistry.validate_model_data_requirements.
const PRICE_FREE_MODELS = ["kenza_indexed", "kenza_simplifie_indexe"]

function usage()
    println("""
    Usage: julia --project=julia julia/run/evaluate_pair.jl [options]

      --series FILE.csv   sortie de extract_city_pairs.jl, population et PIB joints (requis)
      --pair A-B          paire a evaluer (defaut: la plus fournie en passagers)
      --horizon H         horizon du backtest en annees (defaut: 3)
      --min-train N       annees minimales d'entrainement (defaut: 8)
      --list              enumere les paires disponibles, puis quitte
      --help
    """)
end

function parse_args(args::Vector{String})
    opts = Dict{String,Any}("series" => nothing, "pair" => nothing,
                            "horizon" => 3, "min_train" => 8, "list" => false)
    i = 1
    while i <= length(args)
        a = args[i]
        if a in ("--help", "-h"); usage(); exit(0)
        elseif a == "--list"; opts["list"] = true; i += 1
        elseif i == length(args); error("Option '$a' sans valeur")
        elseif a == "--series"; opts["series"] = args[i + 1]; i += 2
        elseif a == "--horizon"; opts["horizon"] = parse(Int, args[i + 1]); i += 2
        elseif a == "--min-train"; opts["min_train"] = parse(Int, args[i + 1]); i += 2
        elseif a == "--pair"
            parts = split(uppercase(strip(args[i + 1])), '-')
            length(parts) == 2 || error("Paire mal formee: '$(args[i + 1])'")
            opts["pair"] = (String(parts[1]), String(parts[2])); i += 2
        else; error("Option inconnue: '$a'")
        end
    end
    opts["series"] === nothing && (usage(); error("--series est requis"))
    return opts
end

"""
    naive_metrics(actual, min_train, horizon) -> Dict

Deux references, evaluees exactement sur le meme protocole que les modeles : meme decoupe,
meme horizon, memes points compares.

- report : la derniere valeur observee, maintenue sur tout l'horizon ;
- tendance : prolongement de la pente des cinq dernieres annees.
"""
function naive_metrics(actual::Vector{Float64}, min_train::Int, horizon::Int)
    n = length(actual)
    out = Dict{String,Dict{String,Float64}}()
    for (label, project) in ("report" => (cut, s) -> actual[cut],
                             "tendance" => (cut, s) -> begin
                                 back = max(1, cut - 5)
                                 slope = (actual[cut] - actual[back]) / max(cut - back, 1)
                                 actual[cut] + s * slope
                             end)
        preds = Float64[]; truth = Float64[]
        for cut in min_train:(n - 1), step in 1:min(horizon, n - cut)
            push!(preds, project(cut, step)); push!(truth, actual[cut + step])
        end
        isempty(preds) && continue
        out[label] = Abstract.calculate_metrics(truth, preds)
    end
    return out
end

function main()
    opts = parse_args(copy(ARGS))
    series = CSV.read(opts["series"], DataFrame; delim = ';')
    for col in ("year", "origin", "dest", "actual_passengers", "population", "gdp_per_capita")
        col in names(series) || error("Colonne '$col' absente. Joindre --population et --macro a l'extraction.")
    end

    totals = combine(groupby(series, [:origin, :dest]),
                     :actual_passengers => sum => :total, nrow => :years)
    sort!(totals, :total, rev = true)

    if opts["list"]
        println("paire            annees   passagers cumules")
        for r in eachrow(totals)
            @printf("%-16s %6d %18.0f\n", string(r.origin, "-", r.dest), r.years, r.total)
        end
        return
    end

    pair = opts["pair"] === nothing ? (totals[1, :origin], totals[1, :dest]) : opts["pair"]
    data = filter(r -> (r.origin, r.dest) == pair || (r.dest, r.origin) == pair, series)
    isempty(data) && error("Paire $(pair[1])-$(pair[2]) absente. Utiliser --list.")
    sort!(data, :year)
    data = select(data, :year, :actual_passengers, :population, :gdp_per_capita)
    dropmissing!(data)

    @printf("Paire %s-%s : %d annees (%d-%d)\n", pair[1], pair[2], nrow(data),
            minimum(data.year), maximum(data.year))
    @printf("  passagers : %.0f -> %.0f\n", data.actual_passengers[1], data.actual_passengers[end])
    @printf("  population: %.0f -> %.0f\n", data.population[1], data.population[end])
    @printf("  PIB/hab   : %.0f -> %.0f USD\n\n", data.gdp_per_capita[1], data.gdp_per_capita[end])

    nrow(data) <= opts["min_train"] + 1 &&
        error("Serie trop courte ($(nrow(data)) annees) pour --min-train $(opts["min_train"])")

    actual = Float64.(data.actual_passengers)
    @printf("Backtest glissant, horizon %d an(s), entrainement minimal %d ans\n",
            opts["horizon"], opts["min_train"])
    println(repeat("-", 74))
    @printf("%-26s %10s %10s %12s\n", "", "R2 in-samp", "R2 hors-ech", "MAPE hors-ech")
    println(repeat("-", 74))

    for name in PRICE_FREE_MODELS
        model = Registry.get_model(name)
        model === nothing && continue
        instance = model()
        in_sample = NaN
        try
            Abstract.fit!(instance, data)
            in_sample = get(instance.metrics, "in_sample_R2", get(instance.metrics, "R2", NaN))
        catch err
            @printf("%-26s %s\n", name, "ajustement impossible : $(first(sprint(showerror, err), 30))")
            continue
        end
        oos = Abstract.rolling_backtest_metrics(model, data;
                                                min_train = opts["min_train"],
                                                horizon = opts["horizon"])
        @printf("%-26s %10.3f %10.3f %12.1f\n", name, in_sample,
                get(oos, "oos_R2", NaN), get(oos, "oos_MAPE", NaN))
    end

    println(repeat("-", 74))
    for (label, m) in sort(collect(naive_metrics(actual, opts["min_train"], opts["horizon"])); by = first)
        @printf("%-26s %10s %10.3f %12.1f\n", "[naif : $label]", "-", m["R2"], m["MAPE"])
    end
    println(repeat("-", 74))
    println("\nUn R2 hors echantillon negatif signifie : moins bon que la moyenne de la serie.")
    println("Un modele qui ne bat pas la reference naive n'apporte rien d'exploitable.")
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main()
