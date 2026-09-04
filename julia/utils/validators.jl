module Validators

using DataFrames, Dates, Statistics

struct DataValidator
    # No state needed
end

# Colonnes dont les valeurs extremes sont attendues et ne doivent pas etre signalees :
# `year` est monotone par construction, `actual_passengers` porte les chocs reels
# (2009, 2020) qu'on ne veut surtout pas traiter comme des anomalies de saisie.
const _NO_OUTLIER_CHECK = ("year",)

function _numeric_values(column)
    return Float64[Float64(v) for v in skipmissing(column) if v isa Number]
end

"""
    validate(::DataValidator, data) -> Dict

Controle un jeu de donnees SANS le modifier.

La version precedente faisait `df.year = Int.(df.year)` sur le DataFrame de l'appelant :
la validation modifiait silencieusement les donnees qu'elle etait censee inspecter. La
conversion de type est desormais explicite dans `DataService.coerce_schema!`.
"""
function validate(validator::DataValidator, data)

    df = data isa DataFrame ? data : DataFrame(data)
    errors = String[]
    warnings = String[]


    required = ["year", "actual_passengers"]
    # `missing` est le singleton de Base : le reutiliser comme nom de variable le masquait
    # dans toute la portee de la fonction.
    missing_columns = setdiff(required, names(df))
    if !isempty(missing_columns)
        push!(errors, "Missing required columns: $(join(missing_columns, ", "))")
    end


    if "year" in names(df)
        if !(nonmissingtype(eltype(df.year)) <: Integer)
            values = _numeric_values(df.year)
            if length(values) == count(!ismissing, df.year) && all(v -> v == floor(v), values)
                push!(warnings, "Year column holds non-integer types but integral values")
            else
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
        # `count(df[!, col] .< 0)` levait un TypeError des qu'une valeur etait `missing`
        # (comparaison renvoyant `missing`) : le validateur plantait precisement sur
        # l'entree qu'il existe pour signaler.
        neg = count(x -> !ismissing(x) && x isa Number && x < 0, df[!, "actual_passengers"])
        if neg > 0
            push!(errors, "Negative passenger values found in $neg rows")
        end
    end


    if "year" in names(df)
        present = collect(skipmissing(df[!, "year"]))
        if length(unique(present)) < length(present)
            push!(errors, "Duplicate years found")
        end
    end


    for col in names(df)
        col in _NO_OUTLIER_CHECK && continue
        values = _numeric_values(df[!, col])
        # quantile n'a pas de sens en dessous de quelques points.
        length(values) < 4 && continue
        q1 = quantile(values, 0.25)
        q3 = quantile(values, 0.75)
        iqr = q3 - q1
        iqr == 0 && continue
        lower = q1 - 3*iqr
        upper = q3 + 3*iqr
        outliers = count(x -> x < lower || x > upper, values)
        if outliers > 0
            push!(warnings, "Column '$col' has $outliers potential outliers")
        end
    end


    summary = Dict{String, Any}()
    if isempty(errors)
        for col in names(df)
            values = _numeric_values(df[!, col])
            isempty(values) && continue
            summary[col] = Dict(
                "min" => minimum(values),
                "max" => maximum(values),
                "mean" => mean(values),
                "std" => length(values) > 1 ? std(values) : NaN,
                "missing" => count(ismissing, df[!, col])
            )
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
