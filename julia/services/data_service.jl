module DataService

using DataFrames, XLSX, Dates, Statistics, Logging, DelimitedFiles
using ..Validators: DataValidator, validate as validate_data

function validate(data)
    return validate_data(DataValidator(), data)
end

function process_uploaded_file(filepath::String)
    @info "Processing uploaded file" filepath
    df = if endswith(lowercase(filepath), ".csv")
        _read_csv_bytes(read(filepath))
    elseif endswith(lowercase(filepath), ".xlsx") || endswith(lowercase(filepath), ".xls")
        XLSX.readdata(filepath, "Sheet1") |> DataFrame
    else
        error("Unsupported file type: $(splitext(filepath)[2])")
    end
    
    df = normalize_column_names(df)
    
    validation = validate(df)
    summary = generate_summary(df)
    
    first_rows = _records(first(df, min(100, nrow(df))))
    return Dict(
        "filename" => basename(filepath),
        "records" => nrow(df),
        "columns" => names(df),
        "validation" => validation,
        "data" => first_rows,
        "summary" => summary
    )
end

function generate_summary(df::DataFrame)
    summary = Dict("total_records"=>nrow(df), "columns"=>Dict(), "missing_values"=>Dict(),
                   "data_types"=>Dict())
    for col in names(df)
        summary["data_types"][col] = string(eltype(df[!, col]))
        miss = count(ismissing, df[!, col])
        summary["missing_values"][col] = miss
        if eltype(df[!, col]) <: Number
            d = collect(skipmissing(df[!, col]))
            if !isempty(d)
                summary["columns"][col] = Dict(
                    "type"=>"numeric",
                    "min"=>minimum(d), "max"=>maximum(d),
                    "mean"=>mean(d), "std"=>std(d),
                    "missing"=>miss
                )
            else
                summary["columns"][col] = Dict("type"=>"numeric", "missing"=>miss)
            end
        elseif eltype(df[!, col]) <: Union{Date, DateTime}
            d = collect(skipmissing(df[!, col]))
            if !isempty(d)
                summary["columns"][col] = Dict(
                    "type"=>"datetime",
                    "min"=>string(minimum(d)), "max"=>string(maximum(d)),
                    "missing"=>miss
                )
            end
        else
            d = collect(skipmissing(df[!, col]))
            summary["columns"][col] = Dict(
                "type"=>"categorical",
                "unique_values"=>length(unique(d)),
                "missing"=>miss
            )
        end
    end
    return summary
end

function normalize_column_names(df::DataFrame)
    
    new_names = String[]
    for col in names(df)
        new_name = strip(lowercase(col))
        
        mapping = Dict(
            "annee" => "year", "date" => "year", "t" => "year",
            "passagers" => "actual_passengers", "passengers" => "actual_passengers",
            "traffic" => "actual_passengers", "volume" => "actual_passengers", "y" => "actual_passengers",
            "population" => "population", "pop" => "population", "pop_total" => "population",
            "gdp" => "gdp_per_capita", "pib" => "gdp_per_capita", "income" => "gdp_per_capita",
            "price" => "ticket_price", "prix" => "ticket_price", "fare" => "ticket_price"
        )
        new_name = get(mapping, new_name, new_name)
        push!(new_names, new_name)
    end
    
    unique_names = String[]
    for name in new_names
        if name in unique_names
            i = 2
            while "$(name)_$i" in unique_names
                i += 1
            end
            push!(unique_names, "$(name)_$i")
        else
            push!(unique_names, name)
        end
    end
    rename!(df, Symbol.(unique_names))
    return df
end

function clean_data(df::DataFrame)
    cleaned = copy(df)
    
    for col in names(cleaned)
        if eltype(cleaned[!, col]) <: Number
            med = median(skipmissing(cleaned[!, col]))
            replace!(cleaned[!, col], missing=>med)
        else
            counts = Dict{Any,Int}()
            for value in skipmissing(cleaned[!, col])
                counts[value] = get(counts, value, 0) + 1
            end
            if !isempty(counts)
                mode = first(sort(collect(counts), by=last, rev=true)).first
                replace!(cleaned[!, col], missing=>mode)
            end
        end
    end
    
    unique!(cleaned)
    
    for col in names(cleaned)
        if eltype(cleaned[!, col]) <: Number
            d = collect(skipmissing(cleaned[!, col]))
            if length(d) >= 4
                q1, q3 = quantile(d, [0.25, 0.75])
                iqr = q3 - q1
                lower = q1 - 1.5iqr
                upper = q3 + 1.5iqr
                cleaned[!, col] = clamp.(cleaned[!, col], lower, upper)
            end
        end
    end
    return cleaned
end

function _records(df::DataFrame)
    return [Dict(string(col) => row[col] for col in names(df)) for row in eachrow(df)]
end

function _read_csv_bytes(content::Vector{UInt8})
    text = String(content)
    first_line = first(split(text, '\n'))
    delimiter = count(==(';'), first_line) > count(==(','), first_line) ? ';' : ','
    matrix = readdlm(IOBuffer(text), delimiter, String; quotes=true)
    size(matrix, 1) < 1 && return DataFrame()
    headers = [strip(String(value)) for value in matrix[1, :]]
    df = DataFrame()
    for (idx, header) in enumerate(headers)
        values = Vector{Any}(matrix[2:end, idx])
        parsed = Any[]
        numeric = true
        for value in values
            stripped = strip(String(value))
            if isempty(stripped)
                push!(parsed, missing)
            else
                number = tryparse(Float64, replace(stripped, "," => "."))
                if number === nothing
                    numeric = false
                    push!(parsed, stripped)
                else
                    push!(parsed, number)
                end
            end
        end
        df[!, Symbol(header)] = numeric ? [value === missing ? missing : Float64(value) for value in parsed] : parsed
    end
    return df
end

function process_uploaded_bytes(filename::String, content::Vector{UInt8})
    @info "Processing uploaded bytes" filename bytes=length(content)
    ext = lowercase(splitext(filename)[2])
    df = if ext == ".csv"
        _read_csv_bytes(content)
    elseif ext == ".xlsx" || ext == ".xls"
        path = tempname() * ext
        write(path, content)
        try
            XLSX.readtable(path, 1) |> DataFrame
        finally
            isfile(path) && rm(path; force=true)
        end
    else
        error("Unsupported file type: $ext")
    end
    df = normalize_column_names(df)
    validation = validate(df)
    summary = generate_summary(df)
    first_rows = _records(first(df, min(100, nrow(df))))
    return Dict(
        "filename" => filename,
        "records" => nrow(df),
        "columns" => names(df),
        "validation" => validation,
        "data" => first_rows,
        "summary" => summary,
        "success"=>  true
    )
end

end
