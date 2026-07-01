module ExportService

using DataFrames, XLSX, JSON3, Dates, Tables
using ..Formatters: prepare_json_for_export

function _records(value)
    value isa AbstractVector ? value : Any[]
end

function _sheet!(xf, index::Int, name::String)
    sheet = index == 1 ? xf[1] : XLSX.addsheet!(xf, name)
    try
        XLSX.rename!(sheet, name)
    catch
    end
    return sheet
end

function _write_rows!(xf, index::Int, name::String, rows)
    isempty(rows) && return
    df = DataFrame(rows)
    sheet = _sheet!(xf, index, name)
    XLSX.writetable!(sheet, collect(eachcol(df)), names(df); write_columnnames=true)
end

function _flatten_diagnostics(diagnostics)
    rows = Dict{String,Any}[]
    diagnostics isa AbstractDict || return rows
    for (section, values) in diagnostics
        if values isa AbstractDict
            for (key, value) in values
                push!(rows, Dict("section"=>string(section), "metric"=>string(key), "value"=>string(value)))
            end
        elseif values isa AbstractVector
            push!(rows, Dict("section"=>string(section), "metric"=>string(section), "value"=>join(string.(values), "; ")))
        else
            push!(rows, Dict("section"=>string(section), "metric"=>string(section), "value"=>string(values)))
        end
    end
    return rows
end

function _comparison_rows(results)
    comparison = get(results, "comparison", get(results, "results", []))
    rows = Dict{String,Any}[]
    for row in _records(comparison)
        row isa AbstractDict || continue
        metrics = get(row, "metrics", Dict())
        diagnostics = get(row, "diagnostics", Dict())
        scores = get(diagnostics, "scores", Dict())
        continuity = get(diagnostics, "continuity", Dict())
        push!(rows, Dict(
            "model"=>get(row, "model", ""),
            "rmse"=>get(metrics, "rmse", get(metrics, "RMSE", nothing)),
            "mae"=>get(metrics, "mae", get(metrics, "MAE", nothing)),
            "mape"=>get(metrics, "mape", get(metrics, "MAPE", nothing)),
            "r2"=>get(metrics, "r2", get(metrics, "R2", nothing)),
            "global_score"=>get(scores, "global", nothing),
            "continuity_score"=>get(scores, "continuity", nothing),
            "stability_score"=>get(scores, "stability", nothing),
            "continuity_gap_pct"=>get(continuity, "gapPct", nothing),
            "risk"=>get(diagnostics, "risk", nothing),
            "error"=>get(row, "error", nothing)
        ))
    end
    return rows
end

function _backtest_rows(backtest)
    rows = Dict{String,Any}[]
    summaries = Dict{String,Any}[]
    backtest isa AbstractDict || return rows, summaries
    models = get(backtest, "models", [])
    if !isempty(models)
        for model in models
            model isa AbstractDict || continue
            summary = get(model, "summary", Dict())
            push!(summaries, Dict(
                "model"=>get(model, "model", ""),
                "mode"=>get(model, "mode", ""),
                "cutoff_year"=>get(model, "cutoffYear", nothing),
                "test_start"=>get(model, "testStart", nothing),
                "test_end"=>get(model, "testEnd", nothing),
                "folds"=>length(get(model, "folds", [])),
                "rmse"=>get(summary, "rmse", get(summary, "RMSE", nothing)),
                "mae"=>get(summary, "mae", get(summary, "MAE", nothing)),
                "mape"=>get(summary, "mape", get(summary, "MAPE", nothing)),
                "r2"=>get(summary, "r2", get(summary, "R2", nothing)),
                "stability"=>get(model, "stability", nothing)
            ))
            for fold in get(model, "folds", [])
                fold isa AbstractDict || continue
                push!(rows, merge(Dict("model"=>get(model, "model", ""), "mode"=>get(model, "mode", "")), Dict(string(k)=>v for (k,v) in fold)))
            end
        end
    else
        for fold in get(backtest, "folds", [])
            fold isa AbstractDict && push!(rows, Dict(string(k)=>v for (k,v) in fold))
        end
    end
    return rows, summaries
end

function _sensitivity_rows(sensitivity)
    rows = Dict{String,Any}[]
    sensitivity isa AbstractDict || return rows
    for model in get(sensitivity, "models", [])
        model isa AbstractDict || continue
        for point in get(model, "points", [])
            point isa AbstractDict || continue
            push!(rows, Dict(
                "model"=>get(model, "model", ""),
                "parameter"=>get(sensitivity, "parameter", ""),
                "mode"=>get(sensitivity, "mode", ""),
                "value"=>get(point, "value", nothing),
                "label"=>get(point, "label", ""),
                "final_prediction"=>get(point, "finalPrediction", nothing),
                "impact_pct"=>get(point, "impactPct", nothing),
                "error"=>get(point, "error", nothing)
            ))
        end
    end
    isempty(rows) && append!(rows, [Dict(string(k)=>v for (k,v) in cell) for cell in get(sensitivity, "cells", []) if cell isa AbstractDict])
    return rows
end

function to_excel(results::Dict{String,Any})::Vector{UInt8}
    io = IOBuffer()
    XLSX.openxlsx(io, mode="w") do xf
        index = 1
        if haskey(results, "forecast") && !isempty(results["forecast"])
            _write_rows!(xf, index, "Forecast", results["forecast"]); index += 1
        end
        if haskey(results, "metrics")
            _write_rows!(xf, index, "Metrics", [results["metrics"]]); index += 1
        end
        _write_rows!(xf, index, "Info", [Dict("model"=>get(results,"model",""), "horizon"=>get(results,"horizon",""), "timestamp"=>Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))]); index += 1
        if haskey(results, "parameters") && !isempty(results["parameters"])
            _write_rows!(xf, index, "Parameters", [results["parameters"]]); index += 1
        end
        diagnostics = get(results, "diagnostics", Dict())
        diagnostic_rows = _flatten_diagnostics(diagnostics)
        if !isempty(diagnostic_rows)
            _write_rows!(xf, index, "Diagnostics", diagnostic_rows); index += 1
        end
        thresholds = get(results, "diagnostic_thresholds", diagnostics isa AbstractDict ? get(diagnostics, "thresholds", Dict()) : Dict())
        if thresholds isa AbstractDict && !isempty(thresholds)
            _write_rows!(xf, index, "Diagnostic_Thresholds", [thresholds]); index += 1
        end
        comparison = _comparison_rows(results)
        if !isempty(comparison)
            _write_rows!(xf, index, "Benchmark", comparison); index += 1
        end
        backtest_rows, backtest_summary = _backtest_rows(get(results, "backtest", Dict()))
        if !isempty(backtest_rows)
            _write_rows!(xf, index, "Backtesting", backtest_rows); index += 1
        end
        if !isempty(backtest_summary)
            _write_rows!(xf, index, "Validation_Models", backtest_summary); index += 1
        end
        sensitivity_rows = _sensitivity_rows(get(results, "sensitivity", Dict()))
        if !isempty(sensitivity_rows)
            _write_rows!(xf, index, "Sensitivity", sensitivity_rows); index += 1
        end
        scenarios = get(results, "scenario_summary", get(results, "summary", []))
        if scenarios isa AbstractVector && !isempty(scenarios)
            _write_rows!(xf, index, "Scenarios", scenarios); index += 1
        end
    end
    return take!(io)
end

function to_csv(results::Dict{String,Any})::String
    if !haskey(results, "forecast") || isempty(results["forecast"])
        error("No forecast data to export")
    end
    df = DataFrame(results["forecast"])
    lines = String[]
    push!(lines, join(names(df), ","))
    for row in eachrow(df)
        push!(lines, join([_csv_cell(row[col]) for col in names(df)], ","))
    end
    return join(lines, "\n")
end

function _csv_cell(value)
    text = value === missing || value === nothing ? "" : string(value)
    if occursin(",", text) || occursin("\"", text) || occursin("\n", text)
        return "\"" * replace(text, "\"" => "\"\"") * "\""
    end
    return text
end

function to_json(results::Dict{String,Any})::String
    export_data = copy(results)
    export_data["export_info"] = Dict("exported_at"=>Dates.format(now(), "yyyy-mm-dd HH:MM:SS"), "format"=>"json", "version"=>"1.0")
    return JSON3.write(prepare_json_for_export(export_data), pretty=true)
end

function _pdf_escape(text)
    return replace(string(text), "\\"=>"\\\\", "("=>"\\(", ")"=>"\\)")
end

_pdf_ascii(text) = replace(string(text), r"[^\x20-\x7e]" => "")

function _pdf_text!(ops::Vector{String}, x, y, text; size=10, bold=false, color="0 0 0")
    font = bold ? "F2" : "F1"
    safe = _pdf_escape(_pdf_ascii(text))
    push!(ops, "BT /$font $size Tf $color rg $x $y Td ($safe) Tj ET")
end

function _pdf_rect!(ops::Vector{String}, x, y, w, h; fill="1 1 1", stroke=nothing)
    if stroke === nothing
        push!(ops, "q $fill rg $x $y $w $h re f Q")
    else
        push!(ops, "q $fill rg $stroke RG $x $y $w $h re B Q")
    end
end

function _pdf_line!(ops::Vector{String}, x1, y1, x2, y2; color="0 0 0", width=1)
    push!(ops, "q $color RG $width w $x1 $y1 m $x2 $y2 l S Q")
end

function _pdf_polyline!(ops::Vector{String}, points; color="0 0 0", width=1)
    length(points) < 2 && return
    parts = ["q $color RG $width w $(points[1][1]) $(points[1][2]) m"]
    for point in points[2:end]
        push!(parts, "$(point[1]) $(point[2]) l")
    end
    push!(parts, "S Q")
    push!(ops, join(parts, " "))
end

function _pdf_number(value; decimals=0)
    if !(value isa Number) || !isfinite(Float64(value))
        return "N/A"
    end
    rounded = round(Float64(value), digits=decimals)
    return decimals == 0 ? string(Int(round(rounded))) : string(rounded)
end

function _pdf_metric(metrics, key; decimals=2)
    metrics isa AbstractDict || return "N/A"
    value = get(metrics, key, get(metrics, uppercase(key), get(metrics, lowercase(key), nothing)))
    return _pdf_number(value; decimals=decimals)
end

function _pdf_wrap(text, limit=86)
    words = split(_pdf_ascii(text))
    lines = String[]
    current = ""
    for word in words
        if isempty(current)
            current = word
        elseif length(current) + length(word) + 1 <= limit
            current *= " " * word
        else
            push!(lines, current)
            current = word
        end
    end
    !isempty(current) && push!(lines, current)
    return isempty(lines) ? ["N/A"] : lines
end

function _dict_get(row, key, default=nothing)
    row isa AbstractDict || return default
    return get(row, key, get(row, Symbol(key), default))
end

function _forecast_growth(forecast)
    forecast isa AbstractVector && length(forecast) >= 2 || return nothing
    first = _dict_get(forecast[1], "predicted_passengers", nothing)
    last = _dict_get(forecast[end], "predicted_passengers", nothing)
    first isa Number && last isa Number && first > 0 || return nothing
    return (last / first - 1) * 100
end

function _pdf_header!(ops, title, subtitle="")
    _pdf_rect!(ops, 0, 775, 595, 67; fill="0 0.345 0.745")
    _pdf_text!(ops, 42, 812, title; size=17, bold=true, color="1 1 1")
    _pdf_text!(ops, 42, 792, subtitle; size=9, color="0.86 0.91 1")
end

function _pdf_card!(ops, x, y, w, h, label, value)
    _pdf_rect!(ops, x, y, w, h; fill="0.95 0.97 0.99", stroke="0.82 0.86 0.92")
    _pdf_text!(ops, x + 12, y + h - 22, label; size=8, color="0.42 0.45 0.50")
    _pdf_text!(ops, x + 12, y + 18, value; size=12, bold=true, color="0.07 0.09 0.15")
end

function _summary_page(results)
    ops = String[]
    timestamp = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
    forecast = get(results, "forecast", [])
    metrics = get(results, "metrics", Dict())
    dataset = get(results, "dataset", Dict())
    recommendation = get(results, "recommendation", Dict())
    scenario = get(results, "scenario", Dict())
    model = get(results, "model_label", get(results, "selected_model", get(results, "model", "Unknown")))
    _pdf_header!(ops, "Rapport academique de prevision du trafic aerien", "Genere le $timestamp")

    _pdf_text!(ops, 42, 735, "Resume executif"; size=16, bold=true)
    rows = [
        ("Modele", model),
        ("Horizon", "$(get(results, "horizon", "N/A")) ans"),
        ("Dataset", dataset isa AbstractDict ? get(dataset, "filename", "N/A") : "N/A"),
        ("Observations", dataset isa AbstractDict ? get(dataset, "records", "N/A") : "N/A"),
        ("Confiance", "$(get(results, "confidence", "N/A"))%"),
        ("Recommendation", recommendation isa AbstractDict ? get(recommendation, "model", "N/A") : "N/A")
    ]
    y = 705
    for (label, value) in rows
        _pdf_text!(ops, 45, y, label; size=9, color="0.42 0.45 0.50")
        _pdf_text!(ops, 170, y, value; size=10, bold=true)
        y -= 20
    end

    first = forecast isa AbstractVector && !isempty(forecast) ? forecast[1] : Dict()
    last = forecast isa AbstractVector && !isempty(forecast) ? forecast[end] : Dict()
    growth = _forecast_growth(forecast)
    cards = [
        ("Premiere prevision", "$(_dict_get(first, "year", "N/A")) - $(_pdf_number(_dict_get(first, "predicted_passengers", nothing)))"),
        ("Derniere prevision", "$(_dict_get(last, "year", "N/A")) - $(_pdf_number(_dict_get(last, "predicted_passengers", nothing)))"),
        ("Croissance totale", growth === nothing ? "N/A" : "$(_pdf_number(growth; decimals=1))%"),
        ("RMSE", _pdf_metric(metrics, "rmse"; decimals=0)),
        ("MAPE", _pdf_metric(metrics, "mape"; decimals=2)),
        ("R2", _pdf_metric(metrics, "r2"; decimals=4))
    ]
    for (i, (label, value)) in enumerate(cards)
        col = (i - 1) % 2
        row = div(i - 1, 2)
        _pdf_card!(ops, 42 + col * 255, 420 - row * 78, 220, 56, label, value)
    end

    _pdf_text!(ops, 42, 230, "Hypotheses de scenario"; size=13, bold=true)
    if scenario isa AbstractDict
        text = "Croissance PIB: $(get(scenario, "gdpGrowth", "N/A"))% | Population: $(get(scenario, "populationGrowth", "N/A"))% | Indice prix billet: $(get(scenario, "ticketPriceIndex", "N/A"))"
        _pdf_text!(ops, 42, 208, text; size=10, color="0.22 0.25 0.32")
    end
    _pdf_text!(ops, 42, 165, "Interpretation"; size=13, bold=true)
    reason = recommendation isa AbstractDict ? get(recommendation, "reason", get(results, "model_explanation", "Aucune recommandation disponible.")) : get(results, "model_explanation", "Aucune recommandation disponible.")
    y = 143
    for line in _pdf_wrap(reason, 92)[1:min(end, 4)]
        _pdf_text!(ops, 42, y, line; size=9, color="0.22 0.25 0.32")
        y -= 15
    end
    return join(ops, "\n")
end

function _methodology_page(results)
    ops = String[]
    details = get(results, "model_details", Dict())
    parameters = get(results, "parameters", Dict())
    model = get(results, "model_label", get(results, "selected_model", get(results, "model", "Unknown")))
    _pdf_header!(ops, "Fiche scientifique du modele", string(model))
    sections = [
        ("Description", details isa AbstractDict ? get(details, "description", get(results, "model_explanation", "")) : get(results, "model_explanation", "")),
        ("Formule mathematique", details isa AbstractDict ? get(details, "formula", "") : ""),
        ("Parametres principaux", details isa AbstractDict ? join(string.(get(details, "parameters", [])), "; ") : ""),
        ("Avantages", details isa AbstractDict ? join(string.(get(details, "advantages", [])), "; ") : ""),
        ("Limites / risques", details isa AbstractDict ? join(string.(get(details, "limits", [])), "; ") : "")
    ]
    y = 730
    for (title, text) in sections
        _pdf_text!(ops, 42, y, title; size=12, bold=true)
        y -= 18
        for line in _pdf_wrap(text, 95)[1:min(end, 3)]
            _pdf_text!(ops, 42, y, line; size=9, color="0.22 0.25 0.32")
            y -= 14
        end
        y -= 18
    end
    _pdf_text!(ops, 42, max(y, 190), "Parametres utilises"; size=12, bold=true)
    y = max(y - 24, 166)
    if parameters isa AbstractDict && !isempty(parameters)
        for (i, (key, value)) in enumerate(collect(parameters)[1:min(length(parameters), 14)])
            col = (i - 1) % 2
            row = div(i - 1, 2)
            yy = y - row * 22
            _pdf_text!(ops, 42 + col * 260, yy, string(key); size=8, color="0.42 0.45 0.50")
            _pdf_text!(ops, 150 + col * 260, yy, string(value); size=8, bold=true)
        end
    else
        _pdf_text!(ops, 42, y, "Aucun parametre specifique fourni."; size=9, color="0.42 0.45 0.50")
    end
    _pdf_text!(ops, 42, 64, "Note: les resultats doivent etre interpretes avec les hypotheses du modele, la qualite du dataset et les diagnostics de validation."; size=8, color="0.42 0.45 0.50")
    return join(ops, "\n")
end

function _chart_page(results)
    ops = String[]
    forecast = get(results, "forecast", [])
    training = get(results, "training_data", [])
    _pdf_header!(ops, "Trajectoire historique et previsionnelle", "Donnees d entrainement, prevision brute et intervalle")
    _pdf_rect!(ops, 48, 145, 500, 550; fill="1 1 1", stroke="0.86 0.88 0.92")
    rows = Any[]
    training isa AbstractVector && append!(rows, training)
    forecast isa AbstractVector && append!(rows, forecast)
    years = Float64[]
    values = Float64[]
    for row in rows
        year = _dict_get(row, "year", nothing)
        value = _dict_get(row, "actual_passengers", _dict_get(row, "predicted_passengers", nothing))
        year isa Number && value isa Number && isfinite(Float64(value)) || continue
        push!(years, Float64(year)); push!(values, Float64(value))
    end
    if isempty(years) || isempty(values)
        _pdf_text!(ops, 70, 430, "Aucune donnee de forecast disponible."; size=12)
        return join(ops, "\n")
    end
    xmin, xmax = minimum(years), maximum(years)
    ymin, ymax = minimum(values), maximum(values)
    ymax == ymin && (ymax += 1)
    xmap(x) = 70 + (Float64(x) - xmin) / max(xmax - xmin, 1) * 455
    ymap(v) = 170 + (Float64(v) - ymin) / max(ymax - ymin, 1) * 490
    for i in 0:5
        y = 170 + i * 98
        _pdf_line!(ops, 70, y, 525, y; color="0.90 0.91 0.94", width=0.5)
    end
    if training isa AbstractVector && !isempty(training)
        pts = [(xmap(_dict_get(row, "year", 0)), ymap(_dict_get(row, "actual_passengers", 0))) for row in training if _dict_get(row, "year", nothing) isa Number && _dict_get(row, "actual_passengers", nothing) isa Number]
        _pdf_polyline!(ops, pts; color="0.06 0.70 0.50", width=2)
    end
    if forecast isa AbstractVector && !isempty(forecast)
        pts = [(xmap(_dict_get(row, "year", 0)), ymap(_dict_get(row, "predicted_passengers", 0))) for row in forecast if _dict_get(row, "year", nothing) isa Number && _dict_get(row, "predicted_passengers", nothing) isa Number]
        _pdf_polyline!(ops, pts; color="0 0.345 0.745", width=2.2)
    end
    _pdf_text!(ops, 70, 118, "Vert: historique | Bleu: prevision"; size=9, color="0.22 0.25 0.32")
    return join(ops, "\n")
end

function _training_page(results)
    ops = String[]
    training = get(results, "training_data", [])
    continuity = get(results, "continuity_diagnostic", Dict())
    _pdf_header!(ops, "Donnees d entrainement et continuite", "Controle du raccord historique / prevision")
    if training isa AbstractVector && !isempty(training)
        first, last = training[1], training[end]
        _pdf_text!(ops, 42, 730, "Historique utilise"; size=13, bold=true)
        _pdf_text!(ops, 42, 705, "Periode: $(_dict_get(first, "year", "N/A")) - $(_dict_get(last, "year", "N/A"))"; size=10)
        _pdf_text!(ops, 42, 685, "Dernier historique: $(_pdf_number(_dict_get(last, "actual_passengers", nothing))) passagers"; size=10)
        _pdf_table!(ops, 42, 630, ["Annee", "Passagers", "Population", "PIB/hab."],
            [[_dict_get(row, "year", ""), _pdf_number(_dict_get(row, "actual_passengers", nothing)), _pdf_number(_dict_get(row, "population", nothing)), _pdf_number(_dict_get(row, "gdp_per_capita", nothing))] for row in training[max(1, end-9):end]],
            [70, 135, 135, 115])
    end
    _pdf_text!(ops, 42, 255, "Diagnostic de continuite"; size=13, bold=true)
    lines = if continuity isa AbstractDict && !isempty(continuity)
        [
            "Dernier historique: $(_pdf_number(get(continuity, "reference", nothing)))",
            "Premiere prevision brute: $(_pdf_number(get(continuity, "raw", nothing)))",
            "Ecart brut: $(_pdf_number(get(continuity, "gap", nothing)))",
            "Ecart relatif: $(_pdf_number(get(continuity, "gapPct", nothing); decimals=2))%",
            "Facteur d ajustement: $(_pdf_number(get(continuity, "factor", nothing); decimals=4))"
        ]
    else
        ["Aucun diagnostic de continuite disponible."]
    end
    y = 228
    for line in lines
        _pdf_text!(ops, 42, y, line; size=10, color="0.22 0.25 0.32")
        y -= 18
    end
    return join(ops, "\n")
end

function _pdf_table!(ops, x, y, headers, rows, widths; row_h=20, size=8)
    total = sum(widths)
    _pdf_rect!(ops, x, y, total, row_h; fill="0 0.345 0.745")
    xx = x
    for (i, h) in enumerate(headers)
        _pdf_text!(ops, xx + 4, y + 6, h; size=size, bold=true, color="1 1 1")
        xx += widths[i]
    end
    yy = y - row_h
    for row in rows
        _pdf_rect!(ops, x, yy, total, row_h; fill="1 1 1", stroke="0.90 0.91 0.94")
        xx = x
        for (i, cell) in enumerate(row)
            _pdf_text!(ops, xx + 4, yy + 6, cell; size=size, color="0.07 0.09 0.15")
            xx += widths[i]
        end
        yy -= row_h
    end
end

function _diagnostics_page(results)
    ops = String[]
    metrics = get(results, "metrics", Dict())
    diagnostics = get(results, "diagnostics", Dict())
    comparison = _comparison_rows(results)
    _pdf_header!(ops, "Model diagnostics", "Metriques, benchmark et scores de fiabilite")
    _pdf_text!(ops, 42, 730, "Metriques du modele courant"; size=13, bold=true)
    metric_rows = [[uppercase(k), _pdf_metric(metrics, k; decimals=k == "r2" ? 4 : 2)] for k in ["mae", "rmse", "mape", "r2"]]
    _pdf_table!(ops, 42, 700, ["Metric", "Value"], metric_rows, [130, 130])
    scores = diagnostics isa AbstractDict ? get(diagnostics, "scores", Dict()) : Dict()
    _pdf_text!(ops, 330, 730, "Scores de fiabilite"; size=13, bold=true)
    if scores isa AbstractDict && !isempty(scores)
        _pdf_table!(ops, 330, 700, ["Score", "Value"], [[string(k), _pdf_number(v; decimals=1)] for (k, v) in scores], [120, 80]; size=7)
    end
    _pdf_text!(ops, 42, 470, "Benchmark RMSE"; size=13, bold=true)
    if !isempty(comparison)
        rows = [[get(row, "model", ""), _pdf_number(get(row, "rmse", nothing)), _pdf_number(get(row, "global_score", nothing); decimals=1), string(get(row, "risk", ""))] for row in comparison[1:min(end, 10)]]
        _pdf_table!(ops, 42, 440, ["Modele", "RMSE", "Score", "Risk"], rows, [135, 120, 80, 95])
    else
        _pdf_text!(ops, 42, 440, "Aucune comparaison disponible."; size=10)
    end
    warnings = diagnostics isa AbstractDict ? get(diagnostics, "warnings", []) : []
    if warnings isa AbstractVector && !isempty(warnings)
        _pdf_text!(ops, 42, 160, "Warnings"; size=13, bold=true)
        y = 138
        for warning in warnings[1:min(end, 5)]
            _pdf_text!(ops, 54, y, "- $warning"; size=9, color="0.55 0.10 0.10")
            y -= 16
        end
    end
    return join(ops, "\n")
end

function _backtest_page(results)
    ops = String[]
    backtest = get(results, "backtest", Dict())
    folds = backtest isa AbstractDict ? get(backtest, "folds", []) : []
    isempty(folds) && return ""
    _pdf_header!(ops, "Validation temporelle hors echantillon", "Backtesting automatique")
    _pdf_text!(ops, 42, 730, "Stabilite: $(_pdf_number(get(backtest, "stability", nothing); decimals=1))%"; size=13, bold=true)
    rows = [[
        _dict_get(fold, "fold", ""),
        _dict_get(fold, "train", ""),
        _dict_get(fold, "year", _dict_get(fold, "test", "")),
        _pdf_number(_dict_get(fold, "actual_passengers", nothing)),
        _pdf_number(_dict_get(fold, "predicted_passengers", nothing)),
        _pdf_number(_dict_get(fold, "error", nothing)),
        _pdf_number(_dict_get(fold, "mape", nothing); decimals=2)
    ] for fold in folds[1:min(end, 14)]]
    _pdf_table!(ops, 30, 690, ["Fold", "Train", "Test", "Reel", "Predit", "Erreur", "MAPE %"], rows, [45, 82, 55, 88, 88, 88, 62]; size=7)
    return join(ops, "\n")
end

function _forecast_table_page(results)
    ops = String[]
    forecast = get(results, "forecast", [])
    _pdf_header!(ops, "Forecast table", "Valeurs previsionnelles et bornes")
    if !(forecast isa AbstractVector) || isempty(forecast)
        _pdf_text!(ops, 42, 730, "Aucune prevision disponible."; size=11)
        return join(ops, "\n")
    end
    rows = [[
        _dict_get(row, "year", ""),
        _pdf_number(_dict_get(row, "predicted_passengers_raw", _dict_get(row, "predicted_passengers", nothing))),
        _pdf_number(_dict_get(row, "predicted_passengers_adjusted", nothing)),
        _pdf_number(_dict_get(row, "predicted_passengers_lower", nothing)),
        _pdf_number(_dict_get(row, "predicted_passengers_upper", nothing)),
        _pdf_number(_dict_get(row, "growth_rate", nothing); decimals=2)
    ] for row in forecast[1:min(end, 20)]]
    _pdf_table!(ops, 28, 720, ["Annee", "Brut", "Ajuste", "Basse", "Haute", "Croissance %"], rows, [58, 96, 96, 96, 96, 94]; size=7)
    return join(ops, "\n")
end

function _build_pdf_pages(page_streams::Vector{String})::Vector{UInt8}
    streams = [stream for stream in page_streams if !isempty(strip(stream))]
    objects = Vector{String}()
    page_ids = Int[]
    font_regular_id = 3
    font_bold_id = 4
    push!(objects, "1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n")
    push!(objects, "__PAGES__")
    push!(objects, "3 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj\n")
    push!(objects, "4 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >> endobj\n")
    next_id = 5
    for stream in streams
        page_id = next_id
        content_id = next_id + 1
        next_id += 2
        push!(page_ids, page_id)
        push!(objects, "$page_id 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 $font_regular_id 0 R /F2 $font_bold_id 0 R >> >> /Contents $content_id 0 R >> endobj\n")
        push!(objects, "$content_id 0 obj << /Length $(ncodeunits(stream)) >> stream\n$stream\nendstream endobj\n")
    end
    objects[2] = "2 0 obj << /Type /Pages /Kids [" * join(["$id 0 R" for id in page_ids], " ") * "] /Count $(length(page_ids)) >> endobj\n"

    pdf = Vector{UInt8}(codeunits("%PDF-1.4\n"))
    offsets = Int[]
    for obj in objects
        push!(offsets, length(pdf))
        append!(pdf, codeunits(obj))
    end
    xref_start = length(pdf)
    append!(pdf, codeunits("xref\n0 $(length(objects) + 1)\n0000000000 65535 f \n"))
    for offset in offsets
        text = string(offset)
        append!(pdf, codeunits(repeat("0", max(0, 10 - length(text))) * text * " 00000 n \n"))
    end
    append!(pdf, codeunits("trailer << /Size $(length(objects) + 1) /Root 1 0 R >>\nstartxref\n$xref_start\n%%EOF\n"))
    return pdf
end

function to_pdf(results::Dict{String,Any})::Vector{UInt8}
    pages = [
        _summary_page(results),
        _methodology_page(results),
        _chart_page(results),
        _training_page(results),
        _diagnostics_page(results),
        _backtest_page(results),
        _forecast_table_page(results)
    ]
    return _build_pdf_pages(pages)
end

function to_html(results::Dict{String,Any})::String
    timestamp = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
    model = get(results, "model", "Unknown")
    horizon = get(results, "horizon", "N/A")
    metrics_table = ""
    if haskey(results, "metrics")
        metrics_table = "<table>" * join(["<tr><td><strong>$k</strong></td><td>$v</td></tr>" for (k,v) in results["metrics"]], "") * "</table>"
    end
    forecast_table = ""
    if haskey(results, "forecast") && !isempty(results["forecast"])
        df = DataFrame(results["forecast"])
        forecast_table = "<table><tr>" * join(["<th>$c</th>" for c in names(df)], "") * "</tr>"
        for row in eachrow(df)
            forecast_table *= "<tr>" * join(["<td>$(row[col])</td>" for col in names(df)], "") * "</tr>"
        end
        forecast_table *= "</table>"
    end
    return """
    <!DOCTYPE html>
    <html><head><title>Forecast Report</title>
    <style>body{font-family:Arial;margin:40px} table{border-collapse:collapse;width:100%;margin:20px 0} th,td{border:1px solid #ddd;padding:8px} th{background:#0058be;color:white}</style>
    </head><body>
    <h1>Air Traffic Forecast Report</h1>
    <p><strong>Generated:</strong> $timestamp</p>
    <p><strong>Model:</strong> $model</p>
    <p><strong>Horizon:</strong> $horizon</p>
    <h2>Performance Metrics</h2>$metrics_table
    <h2>Forecast Data</h2>$forecast_table
    </body></html>
    """
end

end
