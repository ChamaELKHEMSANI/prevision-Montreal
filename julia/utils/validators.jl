module Validators

using DataFrames, Dates, Statistics

struct DataValidator
    # No state needed
end

function validate(validator::DataValidator, data)
    
    df = data isa DataFrame ? data : DataFrame(data)
    errors = String[]
    warnings = String[]
    
    
    required = ["year", "actual_passengers"]
    missing = setdiff(required, names(df))
    if !isempty(missing)
        push!(errors, "Missing required columns: $(join(missing, ", "))")
    end
    
    
    if "year" in names(df)
        if !(eltype(df.year) <: Integer)
            try
                df.year = Int.(df.year)
                push!(warnings, "Year column converted to integer")
            catch
                push!(errors, "Year column must contain integer values")
            end
        end
    end
    
    
    for col in required
        if col in names(df)
            n_missing = count(ismissing, df[!, col])
            if n_missing > 0
                push!(errors, "Column '$col' has $n_missing missing values")
            end
        end
    end
    
    
    if "actual_passengers" in names(df)
        neg = count(df[!, "actual_passengers"] .< 0)
        if neg > 0
            push!(errors, "Negative passenger values found in $neg rows")
        end
    end
    
    
    if "year" in names(df)
        duplicates = df[!, "year"] |> unique |> length < nrow(df)
        if duplicates
            push!(errors, "Duplicate years found")
        end
    end
    
    
    for col in names(df)
        if eltype(df[!, col]) <: Number
            q1 = quantile(skipmissing(df[!, col]), 0.25)
            q3 = quantile(skipmissing(df[!, col]), 0.75)
            iqr = q3 - q1
            lower = q1 - 3*iqr
            upper = q3 + 3*iqr
            outliers = count(x -> x < lower || x > upper, skipmissing(df[!, col]))
            if outliers > 0
                push!(warnings, "Column '$col' has $outliers potential outliers")
            end
        end
    end
    
    
    summary = Dict{String, Any}()
    if isempty(errors)
        for col in names(df)
            if eltype(df[!, col]) <: Number
                vals = skipmissing(df[!, col])
                summary[col] = Dict(
                    "min" => minimum(vals),
                    "max" => maximum(vals),
                    "mean" => mean(vals),
                    "std" => std(vals),
                    "missing" => count(ismissing, df[!, col])
                )
            end
        end
    end
    
    return Dict(
        "valid" => isempty(errors),
        "errors" => errors,
        "warnings" => warnings,
        "summary" => summary,
        "records" => nrow(df),
        "columns" => names(df)
    )
end

end 
