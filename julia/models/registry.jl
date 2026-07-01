module ModelRegistry

using JSON3
using ..AbstractModel: AbstractForecastingModel
using ..KenzaModels: KenzaModel, KenzaSimplifieModel, KenzaSimplifieIndexeModel,
                     KenzaIndexedModel, KenzaSimplifieCombineModel, KenzaProbabilisticModel


const _models = Dict{String, Type{<:AbstractForecastingModel}}()
const _metadata_cache = Ref{Union{Nothing,Dict{String,Any}}}(nothing)
const _model_order = String[]

function _metadata_path()
    return joinpath(dirname(@__DIR__), "config", "model_metadata.json")
end

function _json_to_dict(value)
    if value isa AbstractDict
        return Dict{String,Any}(string(k) => _json_to_dict(v) for (k, v) in pairs(value))
    elseif value isa AbstractVector
        return Any[_json_to_dict(v) for v in value]
    else
        return value
    end
end

function load_model_metadata()::Dict{String,Any}
    if _metadata_cache[] !== nothing
        return _metadata_cache[]::Dict{String,Any}
    end
    path = joinpath(dirname(@__DIR__), "config", "model_metadata.json")
    if !isfile(path)
        _metadata_cache[] = Dict{String,Any}()
        return _metadata_cache[]::Dict{String,Any}
    end
    parsed = JSON3.read(read(path, String))
    _metadata_cache[] = _json_to_dict(parsed)
    return _metadata_cache[]::Dict{String,Any}
end

function get_metadata(model_name::String)::Dict{String,Any}
    metadata = load_model_metadata()
    item = get(metadata, model_name, Dict{String,Any}())
    return item isa Dict{String,Any} ? item : _json_to_dict(item)
end

function get_default_params(model_name::String)::Dict{String,Any}
    metadata = get_metadata(model_name)
    params = get(metadata, "default_params", nothing)
    if params isa AbstractDict
        return _json_to_dict(params)
    end
    info = get_model_info(model_name)
    fallback = info === nothing ? Dict{String,Any}() : get(info, "parameters", Dict{String,Any}())
    return fallback isa AbstractDict ? Dict{String,Any}(string(k) => v for (k, v) in pairs(fallback)) : Dict{String,Any}()
end

function register_model(name::String, model_type::Type{<:AbstractForecastingModel})
    if !haskey(_models, name)
        push!(_model_order, name)
    end
    _models[name] = model_type
    
end

function get_model(name::String)::Union{Type{<:AbstractForecastingModel}, Nothing}
    return get(_models, name, nothing)
end

function get_model_or_error(name::String)::Type{<:AbstractForecastingModel}
    model = get_model(name)
    if model === nothing
        error("Model '$name' not found")
    end
    return model
end

function list_models()::Vector{String}
    return copy(_model_order)
end

function list_models_by_category()::Dict{String, Vector{Dict{String,Any}}}

    categories = Dict(
        "traditional" => ["kenza", "kenza_simplifie", "kenza_simplifie_combine","kenza_indexed", "kenza_simplifie_indexe","kenza_probabilistic"],

    )
    result = Dict{String, Vector{Dict{String,Any}}}()
    for (cat, names) in categories
        models = []
        for name in names
            if haskey(_models, name)

                try
                    instance = _models[name]()
                    metadata = get_metadata(name)
                    push!(models, Dict("name"=>name, "label"=>name, "description"=>instance.description,
                                       "parameters"=>get(metadata, "default_params", instance.parameters),
                                       "metadata"=>metadata))
                catch
                    push!(models, Dict("name"=>name, "label"=>name, "description"=>"Model $name"))
                end
            end
        end
        if !isempty(models)
            result[cat] = models
        end
    end
    return result
end

function get_model_info(model_name::String)::Union{Dict{String,Any}, Nothing}
    model_type = get_model(model_name)
    if model_type === nothing
        return nothing
    end
    try
        instance = model_type()
        info = get_model_info(instance)
        metadata = get_metadata(model_name)
        # Add metadata
        info["metadata"] = metadata
        info["parameters"] = get(metadata, "default_params", instance.parameters)
        info["label"] = get(metadata, "label", get(info, "name", model_name))
        info["category"] = get(metadata, "category", get(info, "category", "other"))
        info["explanation"] = get(metadata, "explanation", get(info, "description", ""))
        return info
    catch
        return Dict("name"=>model_name, "description"=>"Model $model_name", "parameters"=>Dict())
    end
end

function validate_model_data_requirements(model_name::String, columns::Vector{String})::Dict{String,Any}

    required = Dict(
        "kenza" => ["actual_passengers", "gdp_per_capita", "population", "ticket_price"],
        "kenza_simplifie" => ["actual_passengers", "gdp_per_capita", "population", "ticket_price"],
        "kenza_simplifie_combine" => ["actual_passengers", "gdp_per_capita", "population", "ticket_price"],
        "kenza_simplifie_indexe" => ["actual_passengers", "gdp_per_capita", "population"],
        "kenza_indexed" => ["actual_passengers", "gdp_per_capita", "population"],
        "kenza_probabilistic" => ["actual_passengers", "gdp_per_capita", "population", "ticket_price"]
     )
    req = get(required, model_name, ["actual_passengers"])
    missing = setdiff(req, columns)
    score = length(req) == 0 ? 0 : (length(req) - length(missing)) / length(req) * 100
    return Dict("required_columns"=>req, "missing_columns"=>missing,
                "compatibility_score"=>score, "is_compatible"=>isempty(missing))
end

function get_model_capabilities(model_name::String)::Dict{String,Any}
    
    capabilities = Dict(
        "kenza" => Dict("best_for"=>"Long-term forecasting (5+ years)", "time_horizon"=>"Long-term",
                        "category"=>"traditional", "complexity"=>"High", "interpretability"=>"Medium"),
        "kenza_simplifie" => Dict("best_for"=>"Short to medium-term forecasting (1-5 years)", "time_horizon"=>"Medium-term",
                                  "category"=>"traditional", "complexity"=>"Medium", "interpretability"=>"High"),
        "kenza_simplifie_indexe" => Dict("best_for"=>"Short to medium-term forecasting (1-5 years) with indexation", "time_horizon"=>"Medium-term",
                                        "category"=>"traditional", "complexity"=>"Medium", "interpretability"=>"High"),
        "kenza_probabilistic" => Dict("best_for"=>"Probabilistic forecasting and uncertainty quantification", "time_horizon"=>"Variable",
                                      "category"=>"traditional", "complexity"=>"High", "interpretability"=>"Medium")
    )  

    return get(capabilities, model_name, Dict("best_for"=>"General forecasting", "time_horizon"=>"Variable",
                                              "category"=>"other", "complexity"=>"Unknown", "interpretability"=>"Medium"))
end


function _register_defaults()
    register_model("kenza", KenzaModel)
    register_model("kenza_simplifie", KenzaSimplifieModel)
    register_model("kenza_simplifie_indexe", KenzaSimplifieIndexeModel)
    register_model("kenza_indexed", KenzaIndexedModel)
    register_model("kenza_simplifie_combine", KenzaSimplifieCombineModel)
    register_model("kenza_probabilistic", KenzaProbabilisticModel)
end

_register_defaults()

end
