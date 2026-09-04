# build_macro_series.jl
#
# Extrait la serie annuelle de PIB par habitant d'un pays, au format attendu par
# `run/extract_city_pairs.jl --macro`.
#
# Source
#   Chaine GDP du projet (`GDP/data/processed/gdp_unified_2000_2030.csv`), construite a
#   partir des Perspectives de l'economie mondiale du FMI. Couvre 2000-2030, prevision
#   comprise ; la colonne `is_forecast` distingue historique et projection.
#
# Portee
#   Ce PIB est NATIONAL. Pour une paire de villes, c'est une approximation : Montreal et
#   Toronto n'ont ni le meme revenu par habitant ni la meme dynamique. Le classeur Kenza
#   d'origine raisonnait deja au niveau national, ce qui rend cette approximation
#   acceptable pour une premiere preuve de concept, mais elle attribue a toutes les paires
#   d'un meme pays exactement le meme prix normalise `pn`.
#
#   Statistique Canada publie un PIB par division de recensement (tableau 36-10-0468-01) si
#   l'on veut descendre au niveau metropolitain.
#
# Usage
#   julia --project=julia julia/run/build_macro_series.jl \
#       --source "/chemin/GDP/data/processed/gdp_unified_2000_2030.csv" \
#       --country CAN --years 2005-2020 --output julia/data/macro_canada.csv

import Pkg
const JULIA_ROOT = normpath(joinpath(@__DIR__, ".."))
Pkg.activate(JULIA_ROOT)

using CSV
using DataFrames
using Printf

function usage()
    println("""
    Usage: julia --project=julia julia/run/build_macro_series.jl [options]

      --source FILE       gdp_unified_2000_2030.csv (requis)
      --country CODE      code ISO3, ex. CAN, USA (defaut: CAN)
      --years 2005-2020   restreint la plage d'annees
      --with-forecast     conserve aussi les annees de prevision (exclues par defaut)
      --output FILE.csv   fichier de sortie (defaut: stdout)
      --help

    Sortie: year;gdp_per_capita;is_forecast
    """)
end

function parse_args(args::Vector{String})
    opts = Dict{String,Any}("source" => nothing, "country" => "CAN", "years" => nothing,
                            "output" => nothing, "with_forecast" => false)
    i = 1
    while i <= length(args)
        a = args[i]
        if a in ("--help", "-h"); usage(); exit(0)
        elseif a == "--with-forecast"; opts["with_forecast"] = true; i += 1
        elseif i == length(args); error("Option '$a' sans valeur")
        elseif a == "--source"; opts["source"] = args[i + 1]; i += 2
        elseif a == "--country"; opts["country"] = uppercase(args[i + 1]); i += 2
        elseif a == "--output"; opts["output"] = args[i + 1]; i += 2
        elseif a == "--years"
            parts = split(args[i + 1], '-')
            length(parts) == 2 || error("Plage mal formee: '$(args[i + 1])'")
            opts["years"] = parse(Int, parts[1]):parse(Int, parts[2]); i += 2
        else; error("Option inconnue: '$a'")
        end
    end
    opts["source"] === nothing && (usage(); error("--source est requis"))
    return opts
end

"""
    macro_series(path, country, years, with_forecast) -> DataFrame

Serie `year;gdp_per_capita;is_forecast` pour un pays.

Les annees de prevision sont ecartees par defaut : les melanger a l'historique dans un jeu
d'ajustement reviendrait a calibrer un modele sur les projections d'un autre.
"""
function macro_series(path::String, country::String, years, with_forecast::Bool)
    isfile(path) || error("Fichier introuvable: $path")
    table = CSV.read(path, DataFrame)
    code_column = names(table)[1]        # l'en-tete porte un BOM UTF-8
    "GDP_Per_Capita_USD" in names(table) ||
        error("Colonne 'GDP_Per_Capita_USD' absente de $path")

    rows = filter(r -> r[code_column] == country, table)
    isempty(rows) && error("Pays '$country' absent du fichier")

    out = DataFrame(year = Int.(rows.year),
                    gdp_per_capita = rows.GDP_Per_Capita_USD,
                    is_forecast = rows.is_forecast)
    with_forecast || (out = filter(r -> !r.is_forecast, out))
    years !== nothing && (out = filter(r -> r.year in years, out))
    out = filter(r -> !ismissing(r.gdp_per_capita), out)
    isempty(out) && error("Aucune annee retenue pour '$country'")
    return sort!(out, :year)
end

function main()
    opts = parse_args(copy(ARGS))
    result = macro_series(opts["source"], opts["country"], opts["years"], opts["with_forecast"])

    @printf(stderr, "%s : %d annees (%d-%d), PIB/hab de %.0f a %.0f USD\n",
            opts["country"], nrow(result), minimum(result.year), maximum(result.year),
            minimum(result.gdp_per_capita), maximum(result.gdp_per_capita))
    println(stderr, "Source : FMI, Perspectives de l'economie mondiale, via la chaine GDP du projet.")
    println(stderr, "PIB NATIONAL : toutes les paires d'un meme pays partagent donc le meme pn.")

    if opts["output"] === nothing
        CSV.write(stdout, result; delim = ';')
    else
        mkpath(dirname(abspath(opts["output"])))
        CSV.write(opts["output"], result; delim = ';')
        println(stderr, "Ecrit dans $(opts["output"])")
    end
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main()
