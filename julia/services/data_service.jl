module DataService

using DataFrames, XLSX, Dates, Statistics, Logging, DelimitedFiles
using ..Validators: DataValidator, validate as validate_data

function validate(data)
    return validate_data(DataValidator(), data)
end

"""
    coerce_schema!(df) -> DataFrame

Ramene `year` a un entier lorsque c'est possible sans perte.

Cette conversion etait auparavant un effet de bord de `Validators.validate`, qui mutait le
DataFrame de l'appelant. Elle est desormais explicite et appelee au chargement.
"""
function coerce_schema!(df::DataFrame)
    "year" in names(df) || return df
    nonmissingtype(eltype(df.year)) <: Integer && return df
    values = df.year
    any(ismissing, values) && return df
    all(v -> v isa Number && isfinite(v) && v == floor(v), values) || return df
    df.year = Int.(values)
    return df
end

function process_uploaded_file(filepath::String)
    @info "Processing uploaded file" filepath
    df = if endswith(lowercase(filepath), ".csv")
        _read_csv_bytes(read(filepath))
    elseif endswith(lowercase(filepath), ".xlsx") || endswith(lowercase(filepath), ".xls")
        # `XLSX.readdata(path, "Sheet1")` attend une reference de cellule, pas un nom de
        # feuille : tout .xlsx echouait ici avec `XLSXError: Sheet1 is not a valid
        # SheetCellRef`. Le nom de feuille etait de surcroit code en dur. On utilise le meme
        # appel que process_uploaded_bytes, qui lit la premiere feuille avec ses en-tetes.
        XLSX.readtable(filepath, 1) |> DataFrame
    else
        error("Unsupported file type: $(splitext(filepath)[2])")
    end
    
    df = coerce_schema!(normalize_column_names(df))

    validation = validate(df)
    summary = generate_summary(df)
    success, error_message = _validation_verdict(validation)

    return Dict(
        "filename" => basename(filepath),
        "records" => nrow(df),
        "columns" => names(df),
        "validation" => validation,
        # "data" est un APERCU destine a l'affichage, limite a 100 lignes. Les consommateurs
        # qui ont besoin du jeu complet doivent lire "dataframe" : la GUI construisait son
        # jeu d'entrainement a partir de "data" et tronquait donc silencieusement a 100 ans.
        "data" => _records(first(df, min(100, nrow(df)))),
        "dataframe" => df,
        "summary" => summary,
        "success" => success,
        "error" => error_message
    )
end

"""
    _validation_verdict(validation) -> (Bool, Union{String,Nothing})

Traduit le rapport du validateur en couple `(success, error)`.

`validate` calculait deja le verdict — colonnes requises absentes, annees non entieres ou
dupliquees, trafic manquant ou negatif — mais `process_uploaded_bytes` posait
`"success" => true` sans jamais le consulter, et `process_uploaded_file` n'exposait aucune
cle `success`. La GUI ne regarde que `success` : elle acceptait donc un fichier declare
invalide, affichait « N lignes chargees », puis le premier « Lancer le modele » remontait
`MethodError: no method matching Float64(::Missing)` dans la barre d'etat — alors que le
validateur savait dire « Column 'actual_passengers' has 1 missing values ».

Les `warnings` ne sont pas bloquants : une valeur aberrante reste une donnee exploitable.
Le DataFrame est renvoye dans tous les cas, pour que l'appelant puisse montrer ce qui cloche.
"""
function _validation_verdict(validation::AbstractDict)
    errors = get(validation, "errors", String[])
    isempty(errors) && return true, nothing
    return false, join(errors, " ; ")
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

function _records(df::DataFrame)
    return [Dict(string(col) => row[col] for col in names(df)) for row in eachrow(df)]
end

function _read_csv_bytes(content::Vector{UInt8})
    # `String(::Vector{UInt8})` PREND POSSESSION du tableau et le laisse vide : la
    # fonction detruisait silencieusement les octets de son appelant, qui ne pouvait
    # ni les relire ni reessayer apres une erreur. La copie est le prix a payer pour
    # qu'un argument reste lisible apres l'appel.
    text = String(copy(content))
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
                    # Une seule cellule non numerique bascule TOUTE la colonne en texte, ce
                    # qui la rend inutilisable par les modeles. Le silence rendait le
                    # diagnostic impossible : on nomme la colonne et la valeur fautive.
                    numeric && @warn "Colonne traitee comme texte : valeur non numerique" colonne=header valeur=stripped
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
    df = coerce_schema!(normalize_column_names(df))
    validation = validate(df)
    summary = generate_summary(df)
    success, error_message = _validation_verdict(validation)
    return Dict(
        "filename" => filename,
        "records" => nrow(df),
        "columns" => names(df),
        "validation" => validation,
        # Voir process_uploaded_file : "data" est un apercu tronque, "dataframe" le jeu complet.
        "data" => _records(first(df, min(100, nrow(df)))),
        "dataframe" => df,
        "summary" => summary,
        "success" => success,
        "error" => error_message
    )
end

end
