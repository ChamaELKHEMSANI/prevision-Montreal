# fetch_statcan_population.jl
#
# Recupere la population annuelle des regions metropolitaines de recensement (RMR) aupres
# de Statistique Canada et la restitue par code d'aeroport, au format attendu par
# `run/extract_city_pairs.jl --population`.
#
# Source
#   Statistique Canada, tableau 17-10-0135-01
#   "Estimations de la population au 1er juillet, par region metropolitaine de recensement
#    et agglomeration de recensement, limites de 2016"
#   https://www150.statcan.gc.ca/t1/tbl1/fr/tv.action?pid=1710013501
#   Diffuse sous la Licence du gouvernement ouvert - Canada.
#
# Pourquoi cette source
#   Le fichier `2019-2045 - CA.xlsx` du Drive porte une population de chalandise par
#   aeroport, mais seulement de 2019 a 2045 : il sert a PROJETER. Le trafic par paire
#   couvre 2005-2020. Ajuster un modele sur l'historique demande donc une population
#   historique, que ce tableau fournit de 2001 a 2022.
#
# Limite a garder en tete
#   Une RMR n'est pas une zone de chalandise. Pour Montreal en 2019 : RMR 4 334 308 contre
#   4 649 265 de chalandise dans le fichier du Drive, soit 7 % d'ecart, la chalandise
#   debordant les limites de la RMR. Les deux series ne sont donc pas interchangeables :
#   ne pas raccorder l'une a l'autre sans retraitement.
#
# Usage
#   julia --project=julia julia/run/fetch_statcan_population.jl \
#       --output julia/data/population_rmr.csv --years 2005-2020
#
#   --cache DIR   conserve l'archive telechargee (~16 Mo) pour eviter de la reprendre

import Pkg
const JULIA_ROOT = normpath(joinpath(@__DIR__, ".."))
Pkg.activate(JULIA_ROOT)

using CSV
using DataFrames
using Dates
using Downloads
using Printf

const PRODUCT_ID = "17100135"
const WDS_ENDPOINT = "https://www150.statcan.gc.ca/t1/wds/rest/getFullTableDownloadCSV/$PRODUCT_ID/en"

"""
Correspondance aeroport -> RMR, explicite et verifiable.

Un appariement geographique automatique par latitude/longitude serait plus court mais
opaque : une erreur d'affectation passerait inapercue dans les series de population, donc
dans les previsions. La table ci-dessous se relit.

Les intitules sont ceux du tableau 17-10-0135-01 et doivent correspondre au caractere pres,
accents compris. `--list-geo` affiche les intitules disponibles.
"""
const AIRPORT_TO_CMA = Dict(
    "YUL" => "Montréal (CMA), Quebec",
    "YMX" => "Montréal (CMA), Quebec",
    "YYZ" => "Toronto (CMA), Ontario",
    "YTZ" => "Toronto (CMA), Ontario",
    "YHM" => "Hamilton (CMA), Ontario",
    "YKF" => "Kitchener - Cambridge - Waterloo (CMA), Ontario",
    "YVR" => "Vancouver (CMA), British Columbia",
    "YYC" => "Calgary (CMA), Alberta",
    "YEG" => "Edmonton (CMA), Alberta",
    "YOW" => "Ottawa - Gatineau (CMA), Ontario/Quebec",
    "YQB" => "Québec (CMA), Quebec",
    "YHZ" => "Halifax (CMA), Nova Scotia",
    "YWG" => "Winnipeg (CMA), Manitoba",
    "YXE" => "Saskatoon (CMA), Saskatchewan",
    "YQR" => "Regina (CMA), Saskatchewan",
    "YYJ" => "Victoria (CMA), British Columbia",
    "YYT" => "St. John's (CMA), Newfoundland and Labrador",
    "YXU" => "London (CMA), Ontario",
    "YQG" => "Windsor (CMA), Ontario",
    "YFC" => "Fredericton (CA), New Brunswick",
    "YSJ" => "Saint John (CMA), New Brunswick",
    "YQM" => "Moncton (CMA), New Brunswick",
    "YLW" => "Kelowna (CMA), British Columbia",
    "YXX" => "Abbotsford - Mission (CMA), British Columbia",
    "YQT" => "Thunder Bay (CMA), Ontario",
    "YSB" => "Greater Sudbury (CMA), Ontario",
    "YTS" => "Timmins (CA), Ontario",
    "YQQ" => "Courtenay (CA), British Columbia",
    "YXS" => "Prince George (CA), British Columbia",
    "YXY" => "Whitehorse (CA), Yukon",
    "YZF" => "Yellowknife (CA), Northwest Territories",
    "YQX" => "Gander (CA), Newfoundland and Labrador",
    "YDF" => "Grand Falls-Windsor (CA), Newfoundland and Labrador",
    "YBG" => "Saguenay (CMA), Quebec",
    "YRQ" => "Trois-Rivières (CMA), Quebec",
    "YVO" => "Val-d'Or (CA), Quebec",
    # Iqaluit (YFB), Gaspe (YGP) et Chibougamau (YMT) sont volontairement absents : ces
    # localites ne constituent ni une RMR ni une AR au sens de Statistique Canada et n'ont
    # donc aucune population dans ce tableau. Les y chercher produirait un avertissement a
    # chaque execution sans qu'aucun ajout de correspondance puisse le lever.
)

function usage()
    println("""
    Usage: julia --project=julia julia/run/fetch_statcan_population.jl [options]

      --output FILE.csv   fichier de sortie (defaut: stdout)
      --years 2005-2020   restreint la plage d'annees (defaut: tout le tableau)
      --cache DIR         conserve/reutilise l'archive telechargee (~16 Mo)
      --list-geo          affiche les intitules geographiques du tableau, puis quitte
      --help

    Sortie: year;airport;cma;population
    Source: Statistique Canada, tableau 17-10-0135-01, Licence du gouvernement ouvert.
    """)
end

function parse_args(args::Vector{String})
    opts = Dict{String,Any}("output" => nothing, "years" => nothing,
                            "cache" => nothing, "list_geo" => false)
    i = 1
    while i <= length(args)
        a = args[i]
        if a in ("--help", "-h"); usage(); exit(0)
        elseif a == "--list-geo"; opts["list_geo"] = true; i += 1
        elseif i == length(args); error("Option '$a' sans valeur")
        elseif a == "--output"; opts["output"] = args[i + 1]; i += 2
        elseif a == "--cache"; opts["cache"] = args[i + 1]; i += 2
        elseif a == "--years"
            parts = split(args[i + 1], '-')
            length(parts) == 2 || error("Plage mal formee: '$(args[i + 1])' (attendu 2005-2020)")
            opts["years"] = parse(Int, parts[1]):parse(Int, parts[2]); i += 2
        else; error("Option inconnue: '$a'")
        end
    end
    return opts
end

"""
    download_table(cache_dir) -> String

Chemin local de l'archive du tableau. Le service WDS renvoie l'URL de l'archive plutot que
l'archive elle-meme : deux requetes sont donc necessaires.
"""
function download_table(cache_dir)
    if cache_dir !== nothing
        mkpath(cache_dir)
        cached = joinpath(cache_dir, "$PRODUCT_ID-eng.zip")
        if isfile(cached)
            println(stderr, "Archive en cache : $cached")
            return cached
        end
    end
    println(stderr, "Interrogation du service WDS de Statistique Canada...")
    response = read(Downloads.download(WDS_ENDPOINT), String)
    m = match(r"\"object\"\s*:\s*\"([^\"]+)\"", response)
    m === nothing && error("Reponse WDS inattendue : $response")
    url = m.captures[1]
    target = cache_dir === nothing ? tempname() * ".zip" : joinpath(cache_dir, "$PRODUCT_ID-eng.zip")
    println(stderr, "Telechargement de $url")
    Downloads.download(url, target)
    @printf(stderr, "Archive : %.1f Mo\n", filesize(target) / 1024^2)
    return target
end

"""
    read_population(zip_path, years) -> DataFrame

Lit l'archive en flux et ne retient que les lignes "Both sexes" / "All ages". Le CSV
decompresse pese plus de 200 Mo : il n'est jamais charge en entier.
"""
function read_population(zip_path::String, years)
    Sys.which("unzip") === nothing && error("La commande 'unzip' est requise")
    rows = NamedTuple{(:year, :geo, :population),Tuple{Int,String,Float64}}[]
    open(`unzip -p $zip_path $PRODUCT_ID.csv`) do io
        readline(io)  # en-tete
        for line in eachline(io)
            # Champs cites et separes par des virgules ; on decoupe sur `","`.
            fields = split(line, "\",\"")
            length(fields) >= 12 || continue
            fields[4] == "Both sexes" && fields[5] == "All ages" || continue
            year = tryparse(Int, strip(fields[1], ['"', ' ']))
            year === nothing && continue
            years !== nothing && !(year in years) && continue
            value = tryparse(Float64, fields[12])
            value === nothing && continue
            push!(rows, (year = year, geo = fields[2], population = value))
        end
    end
    isempty(rows) && error("Aucune ligne exploitable extraite du tableau")
    return DataFrame(rows)
end

function main()
    opts = parse_args(copy(ARGS))
    zip_path = download_table(opts["cache"])
    table = read_population(zip_path, opts["list_geo"] ? nothing : opts["years"])

    if opts["list_geo"]
        for geo in sort(unique(table.geo)); println(geo); end
        return
    end

    @printf(stderr, "Tableau : %d lignes, %d entites, %d-%d\n",
            nrow(table), length(unique(table.geo)), minimum(table.year), maximum(table.year))

    available = Set(table.geo)
    unknown = sort([code for (code, cma) in AIRPORT_TO_CMA if !(cma in available)])
    isempty(unknown) ||
        @warn "Intitules RMR introuvables dans le tableau (aeroports ignores)" aeroports=unknown

    lookup = Dict((row.geo, row.year) => row.population for row in eachrow(table))
    out = NamedTuple{(:year, :airport, :cma, :population),Tuple{Int,String,String,Float64}}[]
    for year in sort(unique(table.year)), (code, cma) in AIRPORT_TO_CMA
        haskey(lookup, (cma, year)) || continue
        push!(out, (year = year, airport = code, cma = cma, population = lookup[(cma, year)]))
    end
    result = sort!(DataFrame(out), [:airport, :year])

    @printf(stderr, "Sortie : %d lignes, %d aeroports\n", nrow(result), length(unique(result.airport)))
    println(stderr, "Source : Statistique Canada, tableau 17-10-0135-01, consulte le $(today()).")
    println(stderr, "Licence du gouvernement ouvert - Canada.")
    println(stderr, "Rappel : une RMR n'est pas une zone de chalandise (7 % d'ecart pour Montreal en 2019).")

    if opts["output"] === nothing
        CSV.write(stdout, result; delim = ';')
    else
        mkpath(dirname(abspath(opts["output"])))
        CSV.write(opts["output"], result; delim = ';')
        println(stderr, "Ecrit dans $(opts["output"])")
    end
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main()
