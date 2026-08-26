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

function format_percentage(value; decimals::Int=2)
    if value === nothing
        return ""
    end
    numeric = Float64(value)
    if 0 <= numeric <= 1
        numeric *= 100
    end
    return "$(round(numeric, digits=decimals))%"
end

function format_currency(value; currency="EUR", decimals::Int=2)
    symbols = Dict("EUR" => "EUR", "USD" => "\$", "GBP" => "GBP", "JPY" => "JPY")
    return "$(format_number(value, decimals=decimals)) $(get(symbols, currency, currency))"
end

function format_date(date; format_str="short")
    if date === nothing
        return ""
    elseif date isa Date
        return Dates.format(date, format_str == "iso" ? "yyyy-mm-dd" : "dd/mm/yyyy")
    end
    return string(date)
end

function format_file_size(bytes; decimals::Int=1)
    if bytes == 0
        return "0 Bytes"
    end
    sizes = ["Bytes", "KB", "MB", "GB", "TB"]
    idx = min(floor(Int, log(bytes) / log(1024)) + 1, length(sizes))
    size = bytes / (1024 ^ (idx - 1))
    return idx == 1 ? "$(Int(size)) $(sizes[idx])" : "$(round(size, digits=decimals)) $(sizes[idx])"
end

function truncate_text(text::String, max_length::Int=100)
    return length(text) <= max_length ? text : text[1:max_length-3] * "..."
end

function format_dataframe(df::DataFrame, column_formats::Dict{String,Dict}=Dict())
    formatted = copy(df)
    for (col, spec) in column_formats
        if col in names(formatted)
            fmt_type = get(spec, "type", "number")
            decimals = get(spec, "decimals", 2)
            formatter = fmt_type == "percentage" ? x -> format_percentage(x, decimals=decimals) :
                        fmt_type == "currency" ? x -> format_currency(x, currency=get(spec, "currency", "EUR"), decimals=decimals) :
                        fmt_type == "date" ? x -> format_date(x, format_str=get(spec, "format", "short")) :
                        x -> format_number(x, decimals=decimals)
            formatted[!, col] = map(formatter, formatted[!, col])
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
