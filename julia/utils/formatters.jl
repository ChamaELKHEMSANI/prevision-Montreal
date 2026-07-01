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

function prepare_json_for_export(value)
    return value
end

end
