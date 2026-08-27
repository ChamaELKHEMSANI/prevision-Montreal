# extract_city_pairs.jl
#
# Construit, a partir des fichiers annuels de trafic vrai origine-destination
# (`CA - <annee> - pax.xlsx`), les series annuelles par paire de villes attendues par les
# modeles Kenza.
#
# Ces fichiers donnent les passagers par paire origine-destination reelle, acheminement
# compris, pour les flux transitant par le Canada. Ils ne portent PAS de tarif : les series
# produites conviennent donc a `kenza_indexed` et `kenza_simplifie_indexe`, qui n'utilisent
# pas le prix, et non a `kenza` ou `kenza_simplifie`, qui l'exigent.
#
# La base BTS DB1B, elle, porte des tarifs mais est exclusivement domestique americaine :
# ni YUL ni YYZ n'y figurent. Elle ne peut pas servir pour un flux canadien.
#
# Exemples
#
#   julia --project=julia julia/run/extract_city_pairs.jl \
#       --source "/chemin/Data DS" --airport YUL --output julia/data/yul_pairs.csv
#
#   julia --project=julia julia/run/extract_city_pairs.jl \
#       --source "/chemin/Data DS" --pair YUL-JFK --pair YUL-LGA \
#       --macro julia/data/macro_canada.csv --output julia/data/yul_nyc.csv

import Pkg
const JULIA_ROOT = normpath(joinpath(@__DIR__, ".."))
Pkg.activate(JULIA_ROOT)

using CSV
using DataFrames
using Printf
using XLSX

const ORIGIN_COLUMN = Symbol("True Orig Code")
const DEST_COLUMN = Symbol("True Dest Code")
const ORIGIN_COUNTRY = Symbol("Orig Country")
const DEST_COUNTRY = Symbol("Dest Country")

function usage()
    println("""
    Usage: julia --project=julia julia/run/extract_city_pairs.jl [options]

      --source DIR        repertoire contenant les fichiers "CA - <annee> - pax.xlsx" (requis)
      --airport CODE      toutes les paires touchant cet aeroport (repetable)
      --pair A-B          une paire precise (repetable)
      --years 2005-2019   restreint la plage d'annees
      --directional       rapporte A->B et B->A separement (par defaut ils sont cumules)
      --macro FILE.csv    CSV a joindre sur `year` (population, gdp_per_capita, ...)
      --output FILE.csv   fichier de sortie (defaut: stdout)
      --help

    Sans --airport ni --pair, toutes les paires sont extraites : le resultat est volumineux.
    """)
end

function parse_args(args::Vector{String})
    opts = Dict{String,Any}("airports" => String[], "pairs" => Tuple{String,String}[],
                            "directional" => false, "years" => nothing,
                            "source" => nothing, "macro" => nothing, "output" => nothing)
    i = 1
    while i <= length(args)
        a = args[i]
        if a in ("--help", "-h")
            usage(); exit(0)
        elseif a == "--directional"
            opts["directional"] = true; i += 1
        elseif i == length(args)
            error("Option '$a' sans valeur")
        elseif a == "--source"
            opts["source"] = args[i + 1]; i += 2
        elseif a == "--macro"
            opts["macro"] = args[i + 1]; i += 2
        elseif a == "--output"
            opts["output"] = args[i + 1]; i += 2
        elseif a == "--airport"
            push!(opts["airports"], uppercase(strip(args[i + 1]))); i += 2
        elseif a == "--pair"
            parts = split(uppercase(strip(args[i + 1])), '-')
            length(parts) == 2 || error("Paire mal formee: '$(args[i + 1])' (attendu A-B)")
            push!(opts["pairs"], (String(parts[1]), String(parts[2]))); i += 2
        elseif a == "--years"
            parts = split(args[i + 1], '-')
            length(parts) == 2 || error("Plage mal formee: '$(args[i + 1])' (attendu 2005-2019)")
            opts["years"] = parse(Int, parts[1]):parse(Int, parts[2]); i += 2
        else
            error("Option inconnue: '$a'")
        end
    end
    opts["source"] === nothing && (usage(); error("--source est requis"))
    return opts
end

"""
    source_files(dir, years) -> Vector{Tuple{Int,String}}

Fichiers annuels du repertoire, apparies a leur annee, tries. L'annee est lue dans le nom
du fichier plutot que dans son contenu : la colonne de passagers porte l'annee pour titre,
ce qui la rend impossible a nommer a l'avance.
"""
function source_files(dir::String, years)
    isdir(dir) || error("Repertoire introuvable: $dir")
    found = Tuple{Int,String}[]
    for name in readdir(dir)
        m = match(r"(\d{4}).*\.xlsx$"i, name)
        m === nothing && continue
        startswith(name, "~\$") && continue
        year = parse(Int, m.captures[1])
        years !== nothing && !(year in years) && continue
        push!(found, (year, joinpath(dir, name)))
    end
    sort!(found, by = first)
    isempty(found) && error("Aucun fichier annuel exploitable dans $dir")
    return found
end

"""
    market_key(origin, dest, directional) -> Tuple{String,String}

Cle d'agregation. Hors mode directionnel, A->B et B->A designent le meme marche et sont
cumules sous la paire triee alphabetiquement.
"""
function market_key(origin::String, dest::String, directional::Bool)
    directional && return (origin, dest)
    return origin <= dest ? (origin, dest) : (dest, origin)
end

function build_selector(opts)
    airports = Set(opts["airports"])
    pairs = Set(opts["pairs"])
    directional = opts["directional"]
    if isempty(airports) && isempty(pairs)
        return (_, _) -> true
    end
    # Les deux orientations sont toujours retenues : `--directional` demande de RAPPORTER
    # les deux sens separement, pas de n'en garder qu'un. Hors mode directionnel,
    # `market_key` les normalise vers la meme cle et le Set n'en garde qu'une.
    wanted = Set{Tuple{String,String}}()
    for (a, b) in pairs
        push!(wanted, market_key(a, b, directional))
        push!(wanted, market_key(b, a, directional))
    end
    return function (origin, dest)
        (origin in airports || dest in airports) && return true
        return market_key(origin, dest, directional) in wanted
    end
end

function extract_year(path::String, year::Int, selector, directional::Bool)
    sheet = XLSX.readxlsx(path)["Data"]
    rows = XLSX.eachtablerow(sheet)
    labels = XLSX.get_column_labels(rows)
    pax_column = Symbol(string(year))
    if !(pax_column in labels)
        # Repli : la colonne de passagers est la derniere, quel que soit son intitule.
        pax_column = labels[end]
        @warn "Colonne de passagers nommee autrement que l'annee" fichier=basename(path) utilisee=pax_column
    end

    totals = Dict{Tuple{String,String},Float64}()
    countries = Dict{Tuple{String,String},Tuple{String,String}}()
    scanned = 0
    for row in rows
        scanned += 1
        origin = row[ORIGIN_COLUMN]
        dest = row[DEST_COLUMN]
        (origin isa AbstractString && dest isa AbstractString) || continue
        origin = String(origin); dest = String(dest)
        selector(origin, dest) || continue
        passengers = row[pax_column]
        passengers isa Number || continue
        key = market_key(origin, dest, directional)
        totals[key] = get(totals, key, 0.0) + Float64(passengers)
        if !haskey(countries, key)
            oc = row[ORIGIN_COUNTRY]; dc = row[DEST_COUNTRY]
            countries[key] = (oc isa AbstractString ? String(oc) : "",
                              dc isa AbstractString ? String(dc) : "")
        end
    end
    return totals, countries, scanned
end

function main()
    opts = parse_args(copy(ARGS))
    files = source_files(opts["source"], opts["years"])
    selector = build_selector(opts)
    directional = opts["directional"]

    println(stderr, "Fichiers a traiter : $(length(files)) ($(first(files)[1])-$(last(files)[1]))")
    frames = DataFrame[]
    for (year, path) in files
        elapsed = @elapsed begin
            totals, countries, scanned = extract_year(path, year, selector, directional)
        end
        @printf(stderr, "  %d  %7d lignes lues  %5d paires retenues  %6.1f s\n",
                year, scanned, length(totals), elapsed)
        isempty(totals) && continue
        keys_sorted = sort!(collect(keys(totals)))
        push!(frames, DataFrame(
            year = fill(year, length(keys_sorted)),
            origin = first.(keys_sorted),
            dest = last.(keys_sorted),
            origin_country = [countries[k][1] for k in keys_sorted],
            dest_country = [countries[k][2] for k in keys_sorted],
            actual_passengers = [totals[k] for k in keys_sorted],
        ))
    end
    isempty(frames) && error("Aucune paire trouvee. Verifier --airport / --pair.")

    result = vcat(frames...)
    sort!(result, [:origin, :dest, :year])

    if opts["macro"] !== nothing
        macro_df = CSV.read(opts["macro"], DataFrame)
        "year" in names(macro_df) || error("Le fichier --macro doit contenir une colonne 'year'")
        result = leftjoin(result, macro_df, on = :year)
        sort!(result, [:origin, :dest, :year])
        missing_years = unique(result.year[ismissing.(result[!, names(macro_df)[2]])])
        isempty(missing_years) ||
            @warn "Annees sans correspondance dans le fichier macro" annees=missing_years
    end

    pairs_found = length(unique(zip(result.origin, result.dest)))
    println(stderr, "Paires : $pairs_found   lignes : $(nrow(result))")
    println(stderr, "Rappel : ces fichiers ne portent pas de tarif. Les series conviennent a")
    println(stderr, "kenza_indexed et kenza_simplifie_indexe, pas a kenza ni kenza_simplifie.")

    if opts["output"] === nothing
        CSV.write(stdout, result; delim = ';')
    else
        mkpath(dirname(abspath(opts["output"])))
        CSV.write(opts["output"], result; delim = ';')
        println(stderr, "Ecrit dans $(opts["output"])")
    end
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main()
