# gui.jl
# Graphical interactive interface for AirTrafficForecaster

import Pkg
const JULIA_ROOT = normpath(joinpath(@__DIR__, ".."))
Pkg.activate(JULIA_ROOT)

include(joinpath(JULIA_ROOT, "AirTrafficForecaster.jl"))

ENV["GKSwstype"] = "100"

using Gtk, GtkReactive, Cairo, Plots, DataFrames, CSV, XLSX, Dates, Statistics, Random, JSON3
using .AirTrafficForecaster

gr(show=false)

const Registry = AirTrafficForecaster.ModelRegistry
const ForecastService = AirTrafficForecaster.ForecastService
const DataService = AirTrafficForecaster.DataService

function gtk_text_buffer(view::GtkTextView)
    return view[:buffer, GtkTextBuffer]
end

function set_text!(view::GtkTextView, content::AbstractString)
    gtk_text_buffer(view)[String] = String(content)
end

function get_text(view::GtkTextView)
    buffer = gtk_text_buffer(view)
    start_iter = Gtk.mutable(Gtk.GtkTextIter(buffer))
    stop_iter = Gtk.mutable(Gtk.GtkTextIter(buffer, length(buffer) + 1))
    ptr = ccall((:gtk_text_buffer_get_text, Gtk.libgtk), Ptr{UInt8},
        (Ptr{Gtk.GObject}, Ptr{Gtk.GtkTextIter}, Ptr{Gtk.GtkTextIter}, Cint),
        buffer, start_iter, stop_iter, true)
    return Gtk.bytestring(ptr)
end

function parse_parameters_json(text::AbstractString)
    cleaned = strip(String(text))
    isempty(cleaned) && return Dict{String,Any}()
    parsed = JSON3.read(cleaned, Dict{String,Any})
    return Dict{String,Any}(parsed)
end

function pretty_json(value)
    return sprint(io -> JSON3.pretty(io, value))
end

function render_plot(p)
    tempfile = tempname() * ".png"
    savefig(p, tempfile)
    try
        return Gtk.GdkPixbuf(filename=tempfile, width=600, height=400, preserve_aspect_ratio=true)
    finally
        isfile(tempfile) && rm(tempfile; force=true)
    end
end

function plot_forecast(result, data, model_name)
    forecast_df = DataFrame(result["forecast"])
    p = plot(data.year, data.actual_passengers, label="Historique", lw=2, marker=:circle, color=:blue)
    plot!(p, forecast_df.year, forecast_df.predicted_passengers, label="Prévision", lw=2, linestyle=:dash, color=:red, marker=:square)
    if :predicted_passengers_lower in propertynames(forecast_df)
        lower = forecast_df[!, :predicted_passengers_lower]
        upper = :predicted_passengers_upper in propertynames(forecast_df) ? forecast_df[!, :predicted_passengers_upper] : forecast_df.predicted_passengers
        plot!(p, forecast_df.year, lower,
              fillrange=upper, fillalpha=0.25, color=:red, label="IC 95 %", lw=0)
    end
    plot!(p, xlabel="Année", ylabel="Passagers", title="Prévision : $model_name", legend=:topleft)
    return p
end

function plot_comparison(results, data, model_names)
    p = plot(data.year, data.actual_passengers, label="Historique", lw=3, color=:black)
    colors = [:red, :blue, :green, :purple, :orange, :brown]
    for (i, m) in enumerate(model_names)
        if haskey(results[m], "forecast")
            fdf = DataFrame(results[m]["forecast"])
            col = colors[mod1(i, length(colors))]
            plot!(p, fdf.year, fdf.predicted_passengers, label=m, lw=2, linestyle=:dash, color=col)
        end
    end
    plot!(p, xlabel="Année", ylabel="Passagers", title="Comparaison des modèles", legend=:topleft)
    return p
end

function align_forecast_years!(result, last_input_year::Int)
    forecast = get(result, "forecast", Any[])
    for (i, row) in enumerate(forecast)
        row["year"] = last_input_year + i
    end
    return result
end

# ----------------------------------------------------------------------
# Data helpers 
# ----------------------------------------------------------------------

function generate_synthetic_data(n::Int=30)
    Random.seed!(42)
    years = collect(1995:(1995 + n - 1))
    index = collect(1:n)
    trend = 1_250_000 .+ 72_000 .* index
    cycle = 115_000 .* sin.(2 * pi * index ./ 8)
    shock = [year in 2009:2010 ? -180_000 : year == 2020 ? -520_000 : 0 for year in years]
    noise = 35_000 .* randn(n)
    passengers = max.(50_000, trend .+ cycle .+ shock .+ noise)
    population = 31_000_000 .+ 185_000 .* index .+ 40_000 .* randn(n)
    gdp = 2_900 .+ 85 .* index .+ 45 .* randn(n)
    price = 160 .+ 1.8 .* index .+ 3 .* randn(n)
    return DataFrame(
        year=years,
        actual_passengers=passengers,
        population=population,
        gdp_per_capita=gdp,
        ticket_price=price,
    )
end

function load_data(filepath::String)
    bytes = read(filepath)
    response = DataService.process_uploaded_bytes(basename(filepath), bytes)
    if !get(response, "success", false)
        error(get(response, "error", "Failed to load data"))
    end
    data = get(response, "data", Any[])
    df = DataFrame(data)
    if !("year" in names(df)) || !("actual_passengers" in names(df))
        error("Data must contain 'year' and 'actual_passengers'")
    end
    sort!(df, :year)
    return df
end

# ----------------------------------------------------------------------
# GUI state
# ----------------------------------------------------------------------

mutable struct AppState
    data::Union{DataFrame,Nothing}
    models::Vector{String}
    horizon::Int
    parameters::Dict{String,Any}
    results::Dict{String,Any}
    current_plot::Union{Plots.Plot,Nothing}
    status::String
end

function AppState()
    return AppState(nothing, String[], 10, Dict{String,Any}(), Dict{String,Any}(), nothing, "Prêt")
end

# ----------------------------------------------------------------------
# GUI construction
# ----------------------------------------------------------------------

function build_gui()

    win = GtkWindow("Prévision du trafic aérien", 1100, 750)
    set_gtk_property!(win, :border_width, 5)


    main_pane = GtkPaned(:h)
    push!(win, main_pane)

  
    left_panel = GtkBox(:v, spacing=10)
    set_gtk_property!(left_panel, :width_request, 300)
    main_pane[1, false, false] = left_panel

    lbl_title = GtkLabel("Contrôles")
    set_gtk_property!(lbl_title, :xalign, 0)
    set_gtk_property!(lbl_title, :label, "Contrôles")
    push!(left_panel, lbl_title)


    data_box = GtkBox(:h, spacing=5)
    btn_load = GtkButton("Charger CSV")
    set_gtk_property!(btn_load, :label, "Charger CSV")
    lbl_data_status = GtkLabel("Aucune donnée chargée")
    push!(data_box, btn_load, lbl_data_status)
    push!(left_panel, data_box)

    training_period_box = GtkBox(:v, spacing=4)
    lbl_training_period = GtkLabel("Période d'entraînement")
    set_gtk_property!(lbl_training_period, :xalign, 0)
    training_period_controls = GtkBox(:h, spacing=5)
    spin_start_year = GtkSpinButton(0, 9999, 1)
    spin_end_year = GtkSpinButton(0, 9999, 1)
    set_gtk_property!(spin_start_year, :sensitive, false)
    set_gtk_property!(spin_end_year, :sensitive, false)
    push!(training_period_controls, GtkLabel("Début :"), spin_start_year, GtkLabel("Fin :"), spin_end_year)
    push!(training_period_box, lbl_training_period, training_period_controls)
    push!(left_panel, training_period_box)


    model_box = GtkBox(:v, spacing=5)
    lbl_model = GtkLabel("Modèle")
    set_gtk_property!(lbl_model, :xalign, 0)
    push!(model_box, lbl_model)


    combo_models = GtkComboBoxText()


    single_controls_box = GtkBox(:v, spacing=5)
    lbl_single = GtkLabel("Modèle unique")
    set_gtk_property!(lbl_single, :xalign, 0)
    push!(single_controls_box, lbl_single)
    push!(single_controls_box, combo_models)
    push!(model_box, single_controls_box)

    comparison_controls_box = GtkBox(:v, spacing=5)
    comparison_checkboxes = Dict{String,Any}()
    lbl_multi = GtkLabel("Modèles à comparer")
    set_gtk_property!(lbl_multi, :xalign, 0)
    push!(comparison_controls_box, lbl_multi)
    comparison_checks_box = GtkBox(:v, spacing=2)
    sw_models = GtkScrolledWindow()
    set_gtk_property!(sw_models, :height_request, 150)
    set_gtk_property!(sw_models, :width_request, 280)
    push!(sw_models, comparison_checks_box)
    push!(comparison_controls_box, sw_models)
    lbl_comparison_params_model = GtkLabel("Paramètres du modèle :")
    set_gtk_property!(lbl_comparison_params_model, :xalign, 0)
    combo_comparison_params = GtkComboBoxText()
    push!(comparison_controls_box, lbl_comparison_params_model, combo_comparison_params)
    push!(model_box, comparison_controls_box)

    push!(left_panel, model_box)


    horizon_box = GtkBox(:h, spacing=5)
    lbl_horizon = GtkLabel("Horizon :")
    spin_horizon = GtkSpinButton(1, 30, 1)
    set_gtk_property!(spin_horizon, :value, 10)
    push!(horizon_box, lbl_horizon, spin_horizon)
    push!(left_panel, horizon_box)

    params_box = GtkBox(:v, spacing=5)
    lbl_params = GtkLabel("Paramètres du modèle (JSON)")
    set_gtk_property!(lbl_params, :xalign, 0)
    push!(params_box, lbl_params)
    set_gtk_property!(lbl_params, :label, "Paramètres du modèle")
    parameter_controls_box = GtkBox(:v, spacing=4)
    parameter_widgets = Dict{String,Any}()
    parameter_rows = Any[]
    sw_params = GtkScrolledWindow()
    set_gtk_property!(sw_params, :width_request, 280)
    set_gtk_property!(sw_params, :height_request, 180)
    push!(sw_params, parameter_controls_box)
    push!(params_box, sw_params)
    push!(left_panel, params_box)


    btn_run_single = GtkButton("Lancer le modèle")
    btn_run_compare = GtkButton("Lancer la comparaison")
    set_gtk_property!(btn_run_single, :label, "Lancer le modèle")
    set_gtk_property!(btn_run_compare, :label, "Lancer la comparaison")
    single_action_box = GtkBox(:v, spacing=5)
    comparison_action_box = GtkBox(:v, spacing=5)
    push!(single_action_box, btn_run_single)
    push!(comparison_action_box, btn_run_compare)
    push!(left_panel, single_action_box, comparison_action_box)


    lbl_status = GtkLabel("Statut : prêt")
    set_gtk_property!(lbl_status, :xalign, 0)
    push!(left_panel, GtkLabel(""))
    push!(left_panel, lbl_status)


    right_panel = GtkBox(:v, spacing=5)
    set_gtk_property!(right_panel, :hexpand, true)
    set_gtk_property!(right_panel, :vexpand, true)
    main_pane[2, true, true] = right_panel
    set_gtk_property!(main_pane, :position, 320)


    notebook = GtkNotebook()
    set_gtk_property!(notebook, :hexpand, true)
    set_gtk_property!(notebook, :vexpand, true)
    push!(right_panel, notebook)


    tab_single = GtkBox(:v, spacing=5)
    set_gtk_property!(tab_single, :hexpand, true)
    set_gtk_property!(tab_single, :vexpand, true)
    push!(notebook, tab_single, "Modèle unique")


    lbl_metrics = GtkLabel("Indicateurs")
    set_gtk_property!(lbl_metrics, :xalign, 0)
    text_metrics = GtkTextView()
    set_text!(text_metrics, "Aucun résultat pour le moment.")
    sw_metrics = GtkScrolledWindow()
    set_gtk_property!(sw_metrics, :height_request, 120)
    set_gtk_property!(sw_metrics, :hexpand, true)
    push!(sw_metrics, text_metrics)
    push!(tab_single, lbl_metrics, sw_metrics)


    lbl_plot = GtkLabel("Prévision")
    set_gtk_property!(lbl_plot, :xalign, 0)
    img_plot = GtkImage()
    set_gtk_property!(img_plot, :hexpand, true)
    set_gtk_property!(img_plot, :vexpand, true)

    push!(tab_single, lbl_plot, img_plot)


    export_box = GtkBox(:h, spacing=5)
    btn_export_csv = GtkButton("Exporter CSV")
    btn_export_excel = GtkButton("Exporter Excel")
    btn_export_pdf = GtkButton("Exporter PDF")
    set_gtk_property!(btn_export_csv, :label, "Exporter CSV")
    set_gtk_property!(btn_export_excel, :label, "Exporter Excel")
    set_gtk_property!(btn_export_pdf, :label, "Exporter PDF")
    push!(export_box, btn_export_csv, btn_export_excel, btn_export_pdf)
    push!(tab_single, export_box)


    tab_compare = GtkBox(:v, spacing=5)
    set_gtk_property!(tab_compare, :hexpand, true)
    set_gtk_property!(tab_compare, :vexpand, true)
    push!(notebook, tab_compare, "Comparaison")

    lbl_comp_metrics = GtkLabel("Indicateurs de comparaison")
    set_gtk_property!(lbl_comp_metrics, :xalign, 0)
    text_comp_metrics = GtkTextView()
    set_text!(text_comp_metrics, "Lancez une comparaison pour afficher les résultats.")
    sw_comp_metrics = GtkScrolledWindow()
    set_gtk_property!(sw_comp_metrics, :height_request, 200)
    set_gtk_property!(sw_comp_metrics, :hexpand, true)
    push!(sw_comp_metrics, text_comp_metrics)
    push!(tab_compare, lbl_comp_metrics, sw_comp_metrics)


    lbl_comp_plot = GtkLabel("Graphique de comparaison")
    set_gtk_property!(lbl_comp_plot, :xalign, 0)
    img_comp_plot = GtkImage()
    set_gtk_property!(img_comp_plot, :hexpand, true)
    set_gtk_property!(img_comp_plot, :vexpand, true)
    push!(tab_compare, lbl_comp_plot, img_comp_plot)


    available = Registry.list_models()
    for m in available
        push!(combo_models, m, m)
        push!(combo_comparison_params, m, m)
        check = GtkCheckButton(m)
        set_gtk_property!(check, :active, m in ["kenza", "kenza_simplifie", "kenza_simplifie_indexe"])
        comparison_checkboxes[m] = check
        push!(comparison_checks_box, check)
    end

    function active_model_name()
        return get_gtk_property(combo_models, "active-id", String)
    end

    function active_comparison_parameter_model()
        return get_gtk_property(combo_comparison_params, "active-id", String)
    end

    function clear_parameter_controls!()
        for row in parameter_rows
            try
                destroy(row)
            catch
            end
        end
        empty!(parameter_rows)
        empty!(parameter_widgets)
    end

    function parameter_text_value(value)
        if value === nothing
            return ""
        elseif value isa AbstractVector || value isa AbstractDict
            return pretty_json(value)
        else
            return string(value)
        end
    end

    function add_parameter_control!(name::String, value)
        row = GtkBox(:h, spacing=5)
        label = GtkLabel(name)
        set_gtk_property!(label, :xalign, 0)
        set_gtk_property!(label, :width_request, 125)

        widget = if value isa Bool
            check = GtkCheckButton("")
            set_gtk_property!(check, :active, value)
            check
        elseif value isa Integer
            spin = GtkSpinButton(-1.0e9, 1.0e9, 1.0)
            set_gtk_property!(spin, :value, Float64(value))
            spin
        elseif value isa Real
            spin = GtkSpinButton(-1.0e9, 1.0e9, 0.01)
            set_gtk_property!(spin, :value, Float64(value))
            spin
        else
            text = GtkTextView()
            set_gtk_property!(text, :wrap_mode, 2)
            set_text!(text, parameter_text_value(value))
            scroller = GtkScrolledWindow()
            set_gtk_property!(scroller, :height_request, 42)
            set_gtk_property!(scroller, :width_request, 135)
            push!(scroller, text)
            parameter_widgets[name] = ("text", text, value)
            push!(row, label, scroller)
            push!(parameter_controls_box, row)
            push!(parameter_rows, row)
            return
        end

        parameter_widgets[name] = ("value", widget, value)
        push!(row, label, widget)
        push!(parameter_controls_box, row)
        push!(parameter_rows, row)
    end

    function parse_parameter_text(raw::String, original)
        value = strip(raw)
        isempty(value) && return original === nothing ? nothing : ""
        if original isa AbstractVector || original isa AbstractDict || original === nothing
            try
                return JSON3.read(value)
            catch
                return value
            end
        end
        return value
    end

    function collect_parameter_values()::Dict{String,Any}
        params = Dict{String,Any}()
        for (name, spec) in parameter_widgets
            kind, widget, original = spec
            if kind == "text"
                params[name] = parse_parameter_text(get_text(widget), original)
            elseif original isa Bool
                params[name] = get_gtk_property(widget, :active, Bool)
            elseif original isa Integer
                params[name] = Int(round(get_gtk_property(widget, :value, Float64)))
            elseif original isa Real
                params[name] = get_gtk_property(widget, :value, Float64)
            else
                params[name] = get_gtk_property(widget, :value, Float64)
            end
        end
        return params
    end

    function load_params!(params::AbstractDict)
        clear_parameter_controls!()
        for name in sort(collect(keys(params)))
            add_parameter_control!(name, params[name])
        end
        Gtk.showall(parameter_controls_box)
    end

    single_parameters = Dict{String,Dict{String,Any}}(
        model => Registry.get_default_params(model) for model in available
    )
    comparison_parameters = Dict{String,Dict{String,Any}}(
        model => Registry.get_default_params(model) for model in available
    )
    parameter_editor_model = Ref("")
    parameter_editor_mode = Ref(:single)

    function save_current_parameters!()
        model_name = parameter_editor_model[]
        isempty(model_name) && return
        values = collect_parameter_values()
        if parameter_editor_mode[] == :single
            single_parameters[model_name] = values
        else
            comparison_parameters[model_name] = values
        end
    end

    function show_parameters!(mode::Symbol, model_name::String)
        isempty(model_name) && return
        save_current_parameters!()
        parameter_editor_mode[] = mode
        parameter_editor_model[] = model_name
        params = mode == :single ? single_parameters[model_name] : comparison_parameters[model_name]
        load_params!(params)
        set_gtk_property!(lbl_params, :label,
            mode == :single ? "Paramètres du modèle" : "Paramètres de $model_name")
    end

    function update_left_panel_for_page!(page::Integer)
        is_single = page == 0
        set_gtk_property!(single_controls_box, :visible, is_single)
        set_gtk_property!(single_action_box, :visible, is_single)
        set_gtk_property!(comparison_controls_box, :visible, !is_single)
        set_gtk_property!(comparison_action_box, :visible, !is_single)
        mode_label = is_single ? "Contrôles - modèle unique" : "Contrôles - comparaison"
        set_gtk_property!(lbl_title, :label, mode_label)
        model_name = is_single ? active_model_name() : active_comparison_parameter_model()
        show_parameters!(is_single ? :single : :comparison, model_name)
    end

    if !isempty(available)
        set_gtk_property!(combo_models, :active, 0)
        set_gtk_property!(combo_comparison_params, :active, 0)
        show_parameters!(:single, active_model_name())
    end


    app = AppState()

    # ------------------------------------------------------------------
    # Callbacks
    # ------------------------------------------------------------------

    function update_training_period!(df::DataFrame)
        years = Int.(round.(collect(skipmissing(df.year))))
        isempty(years) && error("Aucune année valide dans les données")
        first_year, last_year = extrema(years)
        for spin in (spin_start_year, spin_end_year)
            adjustment = get_gtk_property(spin, :adjustment, GtkAdjustment)
            set_gtk_property!(adjustment, :lower, Float64(first_year))
            set_gtk_property!(adjustment, :upper, Float64(last_year))
            set_gtk_property!(spin, :sensitive, true)
        end
        set_gtk_property!(spin_start_year, :value, Float64(first_year))
        set_gtk_property!(spin_end_year, :value, Float64(last_year))
    end

    function selected_training_data()
        app.data === nothing && error("Chargez d'abord les données")
        start_year = Int(round(get_gtk_property(spin_start_year, :value, Float64)))
        end_year = Int(round(get_gtk_property(spin_end_year, :value, Float64)))
        start_year <= end_year || error("L'année de début doit être inférieure ou égale à l'année de fin")
        selected = filter(row -> !ismissing(row.year) && start_year <= row.year <= end_year, app.data)
        isempty(selected) && error("Aucune donnée disponible entre $start_year et $end_year")
        return selected, start_year, end_year
    end


    function load_data_callback(widget)
        file = open_dialog("Select a CSV file", win, ["*.csv"])
        if !isempty(file)
            try
                df = load_data(file)
                app.data = df
                update_training_period!(df)
                set_gtk_property!(lbl_data_status, :label, "$(nrow(df)) lignes chargées depuis $(basename(file))")
                set_gtk_property!(lbl_status, :label, "Statut : données chargées")
            catch e
                set_gtk_property!(lbl_status, :label, "Erreur : $e")
            end
        end
    end


    function run_single_callback(widget)
        if app.data === nothing
            set_gtk_property!(lbl_status, :label, "Erreur : chargez d'abord les données")
            return
        end
        model_name = active_model_name()
        if isempty(model_name)
            set_gtk_property!(lbl_status, :label, "Erreur : sélectionnez un modèle")
            return
        end
        horizon = Int(ceil(get_gtk_property(spin_horizon, :value, Float64)))
  
        save_current_parameters!()
        params = single_parameters[model_name]
        try
            nothing
        catch
            set_gtk_property!(lbl_status, :label, "Erreur : paramètres JSON invalides")
            return
        end

        set_gtk_property!(lbl_status, :label, "Exécution de $model_name...")
        try
            training_data, start_year, end_year = selected_training_data()
            result = ForecastService.run_forecast(model_name, training_data, params, horizon)
            last_input_year = Int(round(maximum(skipmissing(app.data.year))))
            align_forecast_years!(result, last_input_year)
            app.results["single"] = result
            metrics = get(result, "metrics", Dict{String,Any}())
            metrics_str = "Modèle : $model_name\nPériode d'entraînement : $start_year - $end_year ($(nrow(training_data)) lignes)\nHorizon : $horizon\n"
            for (k,v) in metrics
                if v isa Number && isfinite(float(v))
                    metrics_str *= "$k: $(round(float(v), digits=4))\n"
                end
            end
            set_text!(text_metrics, metrics_str)
            p = plot_forecast(result, app.data, model_name)
            app.current_plot = p
            img = render_plot(p)
            set_gtk_property!(img_plot, :pixbuf, img)
            set_gtk_property!(lbl_status, :label, "Statut : prévision terminée")
        catch e
            set_gtk_property!(lbl_status, :label, "Erreur : $(typeof(e)): $e")
            @error "Run single model failed" exception=(e, catch_backtrace())
        end
    end

   
    function run_compare_callback(widget)
        if app.data === nothing
            set_gtk_property!(lbl_status, :label, "Erreur : chargez d'abord les données")
            return
        end
        model_names = String[
            model for model in sort(collect(keys(comparison_checkboxes)))
            if get_gtk_property(comparison_checkboxes[model], :active, Bool)
        ]
        if isempty(model_names)
            set_gtk_property!(lbl_status, :label, "Erreur : aucun modèle valide")
            return
        end
  
        available = Registry.list_models()
        invalid = setdiff(model_names, available)
        if !isempty(invalid)
            set_gtk_property!(lbl_status, :label, "Modèles inconnus : $(join(invalid, ", "))")
            return
        end
        horizon = Int(ceil(get_gtk_property(spin_horizon, :value, Float64)))
        save_current_parameters!()
        try
            nothing
        catch
            set_gtk_property!(lbl_status, :label, "Erreur : paramètres JSON invalides")
            return
        end

        set_gtk_property!(lbl_status, :label, "Comparaison en cours...")
        try
            training_data, start_year, end_year = selected_training_data()
            last_input_year = Int(round(maximum(skipmissing(app.data.year))))
            results = Dict{String,Any}()
            for m in model_names
                params = get(comparison_parameters, m, Registry.get_default_params(m))
                res = ForecastService.run_forecast(m, training_data, params, horizon)
                align_forecast_years!(res, last_input_year)
                results[m] = res
            end
            app.results["comparison"] = results
            comp_str = "Comparaison (entraînement : $start_year - $end_year, horizon : $horizon)\n"
            comp_str *= "Modèle\tRMSE\tMAE\tR2\tMAPE\n"
            for (m, res) in results
                metrics = get(res, "metrics", Dict{String,Any}())
                rmse = get(metrics, "RMSE", NaN)
                mae = get(metrics, "MAE", NaN)
                r2 = get(metrics, "R2", NaN)
                mape = get(metrics, "MAPE", NaN)
                comp_str *= "$m\t$(round(float(rmse), digits=2))\t$(round(float(mae), digits=2))\t$(round(float(r2), digits=4))\t$(round(float(mape), digits=2))\n"
            end
            set_text!(text_comp_metrics, comp_str)
            p = plot_comparison(results, app.data, model_names)
            img = render_plot(p)
            set_gtk_property!(img_comp_plot, :pixbuf, img)
            set_gtk_property!(lbl_status, :label, "Statut : comparaison terminée")
        catch e
            set_gtk_property!(lbl_status, :label, "Erreur : $(typeof(e)): $e")
            @error "Run comparison failed" exception=(e, catch_backtrace())
        end
    end


    function export_results(format::String)
        if !haskey(app.results, "single")
            set_gtk_property!(lbl_status, :label, "Erreur : lancez d'abord une prévision simple")
            return
        end
        result = app.results["single"]
        if !haskey(result, "forecast")
            set_gtk_property!(lbl_status, :label, "Erreur : aucune donnée de prévision")
            return
        end
  
        ext = format == "csv" ? "csv" : (format == "excel" ? "xlsx" : "pdf")
        filter = format == "csv" ? "*.csv" : (format == "excel" ? "*.xlsx" : "*.pdf")
        file = save_dialog("Save as", win, [filter])
        if isempty(file)
            return
        end
        if !endswith(file, ".$ext")
            file *= ".$ext"
        end
        try
            forecast_df = DataFrame(result["forecast"])
            if format == "csv"
                CSV.write(file, forecast_df)
            elseif format == "excel"
                XLSX.writetable(file, forecast_df)
            elseif format == "pdf"
                # Save the current plot as PDF
                if app.current_plot !== nothing
                    savefig(app.current_plot, file)
                else
                    set_gtk_property!(lbl_status, :label, "Erreur : aucun graphique à enregistrer")
                    return
                end
            end
            set_gtk_property!(lbl_status, :label, "Exporté vers $file")
        catch e
            set_gtk_property!(lbl_status, :label, "Erreur d'export : $e")
        end
    end


    signal_connect(load_data_callback, btn_load, :clicked)
    signal_connect(run_single_callback, btn_run_single, :clicked)
    signal_connect(run_compare_callback, btn_run_compare, :clicked)
    signal_connect(combo_models, :changed) do widget
        model_name = active_model_name()
        !isempty(model_name) && show_parameters!(:single, model_name)
    end
    signal_connect(combo_comparison_params, :changed) do widget
        model_name = active_comparison_parameter_model()
        !isempty(model_name) && show_parameters!(:comparison, model_name)
    end
    signal_connect(notebook, "switch-page") do widget, args...
        page = try
            length(args) >= 2 ? Int(args[end]) : get_gtk_property(notebook, :page, Int)
        catch
            get_gtk_property(notebook, :page, Int)
        end
        update_left_panel_for_page!(page)
    end
    signal_connect(widget -> export_results("csv"), btn_export_csv, :clicked)
    signal_connect(widget -> export_results("excel"), btn_export_excel, :clicked)
    signal_connect(widget -> export_results("pdf"), btn_export_pdf, :clicked)


    try 
        file=joinpath(JULIA_ROOT, "data","sample.csv")
        df = load_data(file)
        app.data = df
        update_training_period!(df)
        set_gtk_property!(lbl_data_status, :label, "$(nrow(df)) lignes chargées depuis $(basename(file))")
        set_gtk_property!(lbl_status, :label, "Statut : données chargées")
    catch
    end

    # Show window
    Gtk.showall(win)
    update_left_panel_for_page!(get_gtk_property(notebook, :page, Int))
    return win
end

# ----------------------------------------------------------------------
# Run the GUI
# ----------------------------------------------------------------------

if abspath(PROGRAM_FILE) == @__FILE__
    win = build_gui()
    if !isinteractive()
        signal_connect(win, :destroy) do widget
            Gtk.gtk_quit()
        end
        Gtk.gtk_main()
    end
end
