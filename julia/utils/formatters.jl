module Formatters

using Dates, DataFrames

function format_number(value; decimals::Int=2)
    if value === nothing
        return ""
    end
    try
        rounded = round(Float64(value), digits=decimals)
        return replace(string(rounded), "." => ",")
    catch
        return string(value)
    end
end

"""
    format_percentage(value; decimals=2)

Rend un pourcentage a partir d'une fraction ou d'une valeur deja exprimee en pourcent.

Deux corrections par rapport a la version initiale.

`Float64(value)` etait appele sans filet, la ou `format_number` protege le sien : un
`missing` ou une chaine levait une `MethodError`. Or `format_dataframe` applique cette
fonction colonne par colonne, et une colonne de resultats porte regulierement des `missing`
— une seule cellule vide faisait echouer la mise en forme du tableau entier.

Le seuil de conversion etait `0 <= v <= 1`, donc asymetrique : une croissance de +0,05
devenait « 5.0% » mais une decroissance de -0,05 restait « -0.05% ». Les taux de croissance
de ce projet sont negatifs sur plusieurs paires de villes (Montreal-Toronto perd 35 % entre
2007 et 2019), l'asymetrie n'etait donc pas theorique. Le seuil est desormais `abs(v) <= 1`.

L'heuristique elle-meme reste ambigue — 0,5 peut signifier 0,5 % comme 50 % — mais elle est
au moins coherente dans les deux sens.
"""
function format_percentage(value; decimals::Int=2)
    if value === nothing
        return ""
    end
    numeric = try
        Float64(value)
    catch
        return string(value)
    end
    isfinite(numeric) || return string(numeric)
    if abs(numeric) <= 1
        numeric *= 100
    end
    return "$(round(numeric, digits=decimals))%"
end

function format_currency(value; currency="EUR", decimals::Int=2)
    symbols = Dict("EUR" => "EUR", "USD" => "\$", "GBP" => "GBP", "JPY" => "JPY")
    return "$(format_number(value, decimals=decimals)) $(get(symbols, currency, currency))"
end

# `date isa Date` etait faux pour un `DateTime`, qui retombait donc sur `string(date)` et
# ignorait `format_str` : une date-heure s'affichait « 2020-01-02T03:00:00 » au milieu d'une
# colonne au format « dd/mm/yyyy ». Les deux types partagent le meme formateur.
function format_date(date; format_str="short")
    if date === nothing
        return ""
    elseif date isa Union{Date,DateTime}
        return Dates.format(date, format_str == "iso" ? "yyyy-mm-dd" : "dd/mm/yyyy")
    end
    return string(date)
end

# Une taille negative ou non finie faisait lever `DomainError` a `log`. Le signe est
# desormais traite a part, la magnitude seule passant par le logarithme.
function format_file_size(bytes; decimals::Int=1)
    numeric = try
        Float64(bytes)
    catch
        return string(bytes)
    end
    (isfinite(numeric) && numeric != 0) || return "0 Bytes"
    sign = numeric < 0 ? "-" : ""
    magnitude = abs(numeric)
    sizes = ["Bytes", "KB", "MB", "GB", "TB"]
    idx = clamp(floor(Int, log(magnitude) / log(1024)) + 1, 1, length(sizes))
    size = magnitude / (1024 ^ (idx - 1))
    return idx == 1 ? "$sign$(round(Int, size)) $(sizes[idx])" :
                      "$sign$(round(size, digits=decimals)) $(sizes[idx])"
end

"""
    truncate_text(text, max_length=100)

Tronque a `max_length` CARACTERES, points de suspension compris.

`length(text)` compte des caracteres mais `text[1:n]` indexe des OCTETS : sur du texte
accentue les deux ne coincident pas. `truncate_text("aeroport de Montreal", 6)` — avec le
vrai « é » — levait `StringIndexError` en coupant au milieu d'un caractere multi-octets, et
quand la coupe tombait par chance sur une frontiere valide le resultat faisait environ la
moitie de la longueur demandee. `first(text, n)` compte en caracteres et ne peut pas couper
un caractere en deux.

La version initiale renvoyait aussi « ... », soit trois caracteres, pour `max_length` de 0,
1 ou 2 : le resultat depassait la limite qu'il devait respecter. En deca de quatre
caracteres il n'y a pas la place pour l'ellipse, on rend donc le debut du texte tel quel.
"""
function truncate_text(text::AbstractString, max_length::Int=100)
    length(text) <= max_length && return String(text)
    max_length <= 3 && return String(first(text, max(max_length, 0)))
    return String(first(text, max_length - 3)) * "..."
end

"""
    format_dataframe(df, column_formats=Dict())

Applique un format par colonne, decrit par `"type"` (`number`, `percentage`, `currency`,
`date`) et ses options.

La signature etait `column_formats::Dict{String,Dict}`, et la fonction en devenait
inappelable sous ses deux formes. Sans argument d'abord : la valeur par defaut `Dict()` est
un `Dict{Any,Any}`, qui ne descend pas de `Dict{String,Dict}` — les types parametriques de
Julia sont invariants — d'ou `MethodError`. Avec argument ensuite : le litteral naturel
`Dict("a" => Dict("type" => "percentage"))` s'infere en `Dict{String,Dict{String,String}}`,
qui ne descend pas davantage de `Dict{String,Dict}`. Il fallait ecrire l'annotation complete
`Dict{String,Dict}(...)` pour atteindre la methode.

`AbstractDict` accepte les trois formes.
"""
function format_dataframe(df::DataFrame, column_formats::AbstractDict=Dict{String,Any}())
    formatted = copy(df)
    for (col, spec) in column_formats
        name = string(col)
        if name in names(formatted)
            fmt_type = get(spec, "type", "number")
            decimals = get(spec, "decimals", 2)
            formatter = fmt_type == "percentage" ? x -> format_percentage(x, decimals=decimals) :
                        fmt_type == "currency" ? x -> format_currency(x, currency=get(spec, "currency", "EUR"), decimals=decimals) :
                        fmt_type == "date" ? x -> format_date(x, format_str=get(spec, "format", "short")) :
                        x -> format_number(x, decimals=decimals)
            formatted[!, name] = map(formatter, formatted[!, name])
        end
    end
    return formatted
end

"""
    prepare_json_for_export(value)

Rend une structure serialisable en JSON.

Le format JSON n'admet ni NaN ni Infinity : `JSON3.write` refuse d'ecrire un tel nombre et
leve `NaN not allowed to be written in JSON spec`. Or ces valeurs sont produites
legitimement — `growth_rate` sur une prevision nulle, `R2` sur une serie de variance nulle —
et faisaient donc echouer `ExportService.to_json` sur des resultats par ailleurs valides,
alors que les exports CSV, Excel, PDF et HTML les acceptaient sans broncher.

Cette fonction retournait auparavant son argument inchange, alors que son nom et son unique
appelant annoncaient cette conversion.

Les nombres non finis deviennent `nothing`, rendu `null` en JSON, comme `missing`. Dates et
symboles deviennent des chaines. Le parcours est recursif.
"""
function prepare_json_for_export(value)
    if value isa AbstractDict
        return Dict{String,Any}(string(k) => prepare_json_for_export(v) for (k, v) in pairs(value))
    elseif value isa DataFrame
        return Any[prepare_json_for_export(Dict(pairs(row))) for row in eachrow(value)]
    elseif value isa AbstractVector || value isa Tuple
        return Any[prepare_json_for_export(v) for v in value]
    elseif value isa AbstractFloat
        return isfinite(value) ? value : nothing
    elseif value isa Union{Date,DateTime,Time}
        return string(value)
    elseif value isa Symbol
        return string(value)
    else
        return value
    end
end

end
