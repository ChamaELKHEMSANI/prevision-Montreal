# regressions.jl
#
# Tests de non-regression couvrant les bugs corriges dans la branche fix/audit-corrections.
# Chaque cas echoue sur le code d'avant correction.
#
#   julia --project=julia julia/run/regressions.jl

import Pkg
const JULIA_ROOT = normpath(joinpath(@__DIR__, ".."))
Pkg.activate(JULIA_ROOT)

include(joinpath(JULIA_ROOT, "AirTrafficForecaster.jl"))

using Dates
using DataFrames
using JSON3
using Test
using .AirTrafficForecaster

const AF = AirTrafficForecaster
const Models = AF.KenzaModels
const Abstract = AF.AbstractModel

const SAMPLE = joinpath(JULIA_ROOT, "data", "sample.csv")

function sample_data()
    df = AF.DataService._read_csv_bytes(read(SAMPLE))
    return AF.DataService.coerce_schema!(AF.DataService.normalize_column_names(df))
end

@testset "Corrections d'audit" begin
    data = sample_data()

    @testset "Schema : year est un entier apres chargement" begin
        # La conversion etait un effet de bord de Validators.validate, qui mutait le
        # DataFrame de l'appelant. Elle est desormais explicite.
        @test eltype(data.year) <: Integer
    end

    @testset "optimize_parameters agit reellement" begin
        # `haskey(parameters, "C1")` etant toujours vrai, la regression n'etait jamais
        # atteinte et le modele restait sur les valeurs de remplissage C1=-0.5 / C2=0.5.
        fixed = Models.KenzaSimplifieModel()
        Abstract.fit!(fixed, data; optimize_parameters=false)
        tuned = Models.KenzaSimplifieModel()
        Abstract.fit!(tuned, data; optimize_parameters=true)

        @test tuned.parameters["C1"] != fixed.parameters["C1"]
        @test tuned.metrics["R2"] > fixed.metrics["R2"]
    end

    @testset "Une seule colonne de prevision fait foi" begin
        # `predicted_passengers` et `predicted_passengers_adjusted` coexistaient avec ~30 %
        # d'ecart : la GUI tracait la premiere, l'export PDF imprimait la seconde.
        model = Models.KenzaModel()
        Abstract.fit!(model, data)
        forecast = Abstract.predict(model, 5)

        @test !("predicted_passengers_adjusted" in names(forecast))
        @test "predicted_passengers_raw" in names(forecast)
        # La continuite est appliquee dans la colonne principale : la premiere prevision
        # prolonge la derniere observation sans saut.
        @test forecast.predicted_passengers[1] ≈ data.actual_passengers[end]
        @test forecast.predicted_passengers_raw[1] != forecast.predicted_passengers[1]
    end

    @testset "kenza_indexed ne publie pas de metriques tautologiques" begin
        # fit! inverse analytiquement la distribution a partir du trafic observe : le
        # reappliquer redonne exactement les donnees d'entree (R2 = 1, RMSE = 0).
        model = Models.KenzaIndexedModel()
        Abstract.fit!(model, data)

        @test model.metrics["in_sample_R2"] ≈ 1.0
        @test model.metrics["R2"] != 1.0
        @test model.metrics["oos_folds"] > 0
        # L'horizon doit rester > 1. Avec la correction de continuite active, la premiere
        # annee projetee est ancree sur la derniere observation d'entrainement : un backtest
        # a un pas reproduit la prevision naive et donne le meme chiffre pour les cinq
        # modeles, sans rien mesurer de leur dynamique.
        @test model.metrics["oos_horizon"] > 1
        @test model.metrics["oos_points"] > model.metrics["oos_folds"]
    end

    @testset "Le backtest distingue reellement les modeles" begin
        # Garde-fou contre un retour a l'horizon 1 : a horizon 1 les cinq modeles rendent
        # exactement la derniere observation, donc des metriques identiques.
        scores = Dict(name => AF.AbstractModel.rolling_backtest_metrics(
                          AF.ModelRegistry.get_model(name), data; min_train=10, horizon=5)["oos_R2"]
                      for name in AF.ModelRegistry.list_models())
        @test length(unique(round.(values(scores), digits=6))) > 1

        # Les parametres doivent atteindre `predict` autant que `fit!` : sans cela
        # apply_continuity_adjustment restait a son defaut et chaque pli etait ancre.
        anchored = AF.AbstractModel.rolling_backtest_metrics(
            AF.ModelRegistry.get_model("kenza"), data; min_train=10, horizon=3)
        raw = AF.AbstractModel.rolling_backtest_metrics(
            AF.ModelRegistry.get_model("kenza"), data; min_train=10, horizon=3,
            params=Dict{String,Any}("apply_continuity_adjustment" => false))
        @test anchored["oos_R2"] != raw["oos_R2"]
    end

    @testset "Petits echantillons : pas de BoundsError" begin
        # `max(3, floor(0.2n))` depassait les bornes des que n < 3.
        for n in 1:3
            model = Models.KenzaModel()
            @test Abstract.fit!(model, data[1:n, :])
        end
    end

    @testset "growth_rate indefinie plutot qu'inventee" begin
        # Le denominateur etait soit nu (NaN/Inf implicite), soit plafonne a 1.0, ce qui
        # fabriquait un taux de croissance a partir d'une valeur inexistante.
        @test Abstract.growth_rate([100.0, 110.0])[2] ≈ 10.0
        @test isnan(Abstract.growth_rate([0.0, 5.0])[2])
        @test Abstract.growth_rate(Float64[]) == Float64[]
    end

    @testset "apply_continuity_adjustment est honore par tous les modeles" begin
        # Seul KenzaModel lisait ce kwarg ; les autres appliquaient la correction en dur.
        for name in ("kenza", "kenza_simplifie", "kenza_simplifie_combine",
                     "kenza_simplifie_indexe", "kenza_indexed")
            model = AF.ModelRegistry.get_model(name)()
            Abstract.fit!(model, data)
            with_adj = Abstract.predict(model, 4; apply_continuity_adjustment=true)
            without = Abstract.predict(model, 4; apply_continuity_adjustment=false)
            @test with_adj.predicted_passengers != without.predicted_passengers
            @test !("predicted_passengers_raw" in names(without))
        end
    end

    @testset "Un prix de reference invalide ne contamine pas la serie" begin
        # `_reference_ticket_price` existait mais n'etait appelee nulle part. Le prix de la
        # premiere ligne sert pourtant de diviseur dans _price_index et dans la
        # normalisation de KenzaSimplifieModel : un zero ou un NaN a cette seule ligne
        # donnait une prevision entierement nulle pour kenza_simplifie et NaN pour
        # kenza_simplifie_combine, sans le moindre message.
        for bad in (0.0, NaN)
            broken = copy(data)
            broken.ticket_price = Float64.(broken.ticket_price)
            broken.ticket_price[1] = bad
            for name in AF.ModelRegistry.list_models()
                model = AF.ModelRegistry.get_model(name)()
                Abstract.fit!(model, broken)
                predictions = Abstract.predict(model, 3).predicted_passengers
                @test all(isfinite, predictions)
                @test any(>(0), predictions)
            end
        end

        # Le repli est le premier prix valide de la serie, pas 1.0 : 1.0 n'a pas d'unite
        # commune avec un prix et sature le clamp de KenzaSimplifieModel, ce qui reproduirait
        # l'effondrement a zero que ce garde doit empecher.
        shifted = copy(data)
        shifted.ticket_price = Float64.(shifted.ticket_price)
        shifted.ticket_price[1] = 0.0
        @test Models._reference_ticket_price(shifted) == shifted.ticket_price[2]
        @test Models._reference_ticket_price(data) == data.ticket_price[1]

        # Aucun prix exploitable : 1.0 en dernier recours, sans exception.
        hopeless = copy(data)
        hopeless.ticket_price = zeros(nrow(hopeless))
        @test Models._reference_ticket_price(hopeless) == 1.0
    end

    @testset "Un prix invalide en fin de serie ne contamine pas la projection" begin
        # Les trois `predict` portaient chacun une copie de _future_macro, privee de ses
        # gardes : un dernier prix a NaN donnait une prevision NaN, un prix manquant une
        # MethodError, pour les seuls modeles qui n'appelaient pas _future_macro.
        for bad in (0.0, NaN)
            broken = copy(data)
            broken.ticket_price = Float64.(broken.ticket_price)
            broken.ticket_price[end] = bad
            for name in AF.ModelRegistry.list_models()
                model = AF.ModelRegistry.get_model(name)()
                Abstract.fit!(model, broken)
                @test all(isfinite, Abstract.predict(model, 3).predicted_passengers)
            end
        end

        # Prix manquant dans la serie historique : Validators n'exige la completude que de
        # `year` et `actual_passengers`, une telle donnee passe donc la validation avant
        # d'atteindre les modeles. Elle ne doit pas y lever de MethodError.
        gappy = copy(data)
        gappy.ticket_price = Vector{Union{Missing,Float64}}(Float64.(gappy.ticket_price))
        gappy.ticket_price[end] = missing
        gappy.ticket_price[3] = missing
        for name in AF.ModelRegistry.list_models()
            model = AF.ModelRegistry.get_model(name)()
            Abstract.fit!(model, gappy)
            @test all(isfinite, Abstract.predict(model, 3).predicted_passengers)
        end

        # La substitution retenue est le prix de reference, comme le faisait deja _price_index.
        @test Models._sanitize_prices([100.0, missing, 0.0, NaN, 250.0], 200.0) ==
              [100.0, 200.0, 200.0, 200.0, 250.0]
    end

    @testset "Les deux chemins de chargement xlsx concordent" begin
        # process_uploaded_file appelait XLSX.readdata(path, "Sheet1"), qui attend une
        # reference de cellule et non un nom de feuille : tout .xlsx echouait avec
        # `XLSXError: Sheet1 is not a valid SheetCellRef`.
        workbook = joinpath(JULIA_ROOT, "data", "forecast_report.xlsx")
        if isfile(workbook)
            from_path = AF.DataService.process_uploaded_file(workbook)
            from_bytes = AF.DataService.process_uploaded_bytes("forecast_report.xlsx", read(workbook))
            @test from_path["columns"] == from_bytes["columns"]
            @test from_path["records"] == from_bytes["records"]
            @test "year" in from_path["columns"]
        end
    end

    @testset "Le registre dit la verite sur les colonnes requises" begin
        # `_future_macro` lisait `ticket_price` sans condition, pour la seule colonne de
        # sortie du meme nom : les deux modeles indexes echouaient donc sur un fichier sans
        # prix, alors que le registre les declare — a juste titre — utilisables sans.
        priceless = DataFrame(year=collect(2000:2019),
                              actual_passengers=Float64.(1000 .+ 50 .* (1:20)),
                              population=Float64.(1e6 .+ 1e4 .* (1:20)),
                              gdp_per_capita=Float64.(3e4 .+ 500 .* (1:20)))
        for name in AF.ModelRegistry.list_models()
            announced = AF.ModelRegistry.validate_model_data_requirements(
                name, names(priceless))["is_compatible"]
            works = try
                model = AF.ModelRegistry.get_model(name)()
                Abstract.fit!(model, priceless)
                Abstract.predict(model, 3)
                true
            catch
                false
            end
            @test announced == works
        end
        # Sans prix en entree, la colonne de sortie est `missing` : aucune serie de prix
        # n'est fabriquee a partir d'une valeur de reference inventee.
        model = Models.KenzaIndexedModel()
        Abstract.fit!(model, priceless)
        @test all(ismissing, Abstract.predict(model, 3).ticket_price)
    end

    @testset "Le validateur signale les valeurs manquantes sans planter" begin
        # `count(col .< 0)` levait un TypeError des qu'une valeur etait `missing`.
        bad = DataFrame(year=[2000, 2001, 2002], actual_passengers=[100.0, missing, -5.0])
        report = AF.DataService.validate(bad)

        @test report["valid"] == false
        @test any(contains("missing values"), report["errors"])
        @test any(contains("Negative passenger"), report["errors"])
    end

    @testset "Le jeu de donnees complet est expose" begin
        # "data" est un apercu limite a 100 lignes ; la GUI en faisait son jeu
        # d'entrainement et tronquait donc silencieusement les series plus longues.
        response = AF.DataService.process_uploaded_file(SAMPLE)

        @test response["dataframe"] isa DataFrame
        @test nrow(response["dataframe"]) == response["records"]
    end

    @testset "Le modele probabiliste est reproductible" begin
        # KenzaProbabilisticModel n'est pas enregistre (modele non implemente, cf.
        # _register_defaults) : on l'instancie donc directement. Le test protege la
        # correction de reproductibilite tant que ce code reste dans le depot.
        # Sans graine, deux executions identiques renvoyaient des previsions differentes.
        first_model = Models.KenzaProbabilisticModel()
        Abstract.fit!(first_model, data)
        second_model = Models.KenzaProbabilisticModel()
        Abstract.fit!(second_model, data)

        @test Abstract.predict(first_model, 5).predicted_passengers ==
              Abstract.predict(second_model, 5).predicted_passengers
        # Sans optimisation, le bootstrap ne produit aucune dispersion de parametres.
        @test first_model.param_distribution["param_bootstrap"] == false
    end

    @testset "run_forecast n'invente pas de metriques" begin
        # Le repli renvoyait Dict("RMSE"=>10.5, "R2"=>0.95) pour tout modele hors contrat.
        # NB : c'est le seul cas de cette suite qui passait deja avant correction. Les six
        # modeles enregistres exposent tous un champ `metrics`, si bien que le repli etait
        # inatteignable en pratique. Ce test est donc un garde-fou, pas une reproduction.
        result = AF.ForecastService.run_forecast("kenza", data, Dict{String,Any}(), 5)
        @test result["metrics"]["R2"] != 0.95
        @test result["metrics"]["RMSE"] != 10.5
    end

    @testset "L'extracteur de paires de villes agrege correctement" begin
        # Test autonome : on fabrique un classeur minimal, sans dependre du Drive.
        include(joinpath(JULIA_ROOT, "run", "extract_city_pairs.jl"))
        dir = mktempdir()
        for (year, rows) in ((2018, [("YUL","JFK","Canada","United States",100.0),
                                     ("JFK","YUL","United States","Canada",40.0),
                                     ("YUL","YYZ","Canada","Canada",900.0),
                                     ("LAX","SFO","United States","United States",7.0)]),
                             (2019, [("YUL","JFK","Canada","United States",120.0),
                                     ("YUL","YYZ","Canada","Canada",950.0)]))
            XLSX.openxlsx(joinpath(dir, "CA - $year - pax.xlsx"), mode="w") do xf
                sheet = xf[1]
                XLSX.rename!(sheet, "Data")
                headers = ["True Orig Code", "True Dest Code", "Orig Country", "Dest Country",
                           string(year)]
                for (c, h) in enumerate(headers)
                    sheet[XLSX.CellRef(1, c)] = h
                end
                for (r, row) in enumerate(rows), (c, v) in enumerate(row)
                    sheet[XLSX.CellRef(r + 1, c)] = v
                end
            end
        end

        files = source_files(dir, nothing)
        @test first.(files) == [2018, 2019]

        # Les deux sens sont cumules sous la paire triee : 100 + 40.
        selector = build_selector(Dict("airports" => String[], "pairs" => [("YUL", "JFK")],
                                       "directional" => false))
        totals, countries, scanned = extract_year(files[1][2], 2018, selector, false)
        @test scanned == 4
        @test collect(keys(totals)) == [("JFK", "YUL")]
        @test totals[("JFK", "YUL")] == 140.0
        @test countries[("JFK", "YUL")] == ("Canada", "United States")

        # En mode directionnel, les deux sens restent distincts.
        directional_selector = build_selector(Dict("airports" => String[], "pairs" => [("YUL", "JFK")],
                                                   "directional" => true))
        directed, _, _ = extract_year(files[1][2], 2018, directional_selector, true)
        @test directed[("YUL", "JFK")] == 100.0
        @test directed[("JFK", "YUL")] == 40.0

        # --airport retient toute paire touchant l'aeroport, et rien d'autre.
        by_airport = build_selector(Dict("airports" => ["YUL"], "pairs" => Tuple{String,String}[],
                                         "directional" => false))
        airport_totals, _, _ = extract_year(files[1][2], 2018, by_airport, false)
        @test sort(collect(keys(airport_totals))) == [("JFK", "YUL"), ("YUL", "YYZ")]

        # La colonne de passagers porte l'annee pour titre : elle change d'un fichier a l'autre.
        next_year, _, _ = extract_year(files[2][2], 2019, by_airport, false)
        @test next_year[("JFK", "YUL")] == 120.0
        @test next_year[("YUL", "YYZ")] == 950.0
    end

    @testset "Les references naives suivent le meme protocole que les modeles" begin
        include(joinpath(JULIA_ROOT, "run", "evaluate_pair.jl"))
        # Serie strictement lineaire : le prolongement de tendance doit etre exact, le
        # report de la derniere valeur non. Sans cela, la comparaison modele/reference ne
        # voudrait rien dire.
        linear = Float64[100 + 10i for i in 0:14]
        naive = naive_metrics(linear, 8, 3)
        @test isapprox(naive["tendance"]["MAPE"], 0.0; atol = 1e-9)
        @test naive["report"]["MAPE"] > 1.0
        # Meme decoupe que rolling_backtest_metrics : memes points, donc comparables.
        @test naive["report"]["R2"] < naive["tendance"]["R2"]
    end

    @testset "La serie macro ecarte les previsions par defaut" begin
        include(joinpath(JULIA_ROOT, "run", "build_macro_series.jl"))
        src = joinpath(mktempdir(), "gdp.csv")
        CSV.write(src, DataFrame(
            country_code = ["CAN", "CAN", "CAN", "USA"],
            year = [2019, 2020, 2021, 2019],
            is_forecast = [false, false, true, false],
            GDP_Per_Capita_USD = [46352.9, 43537.9, 48000.0, 65000.0]))

        historical = macro_series(src, "CAN", nothing, false)
        # Melanger prevision et historique dans un jeu d'ajustement reviendrait a calibrer
        # un modele sur les projections d'un autre.
        @test historical.year == [2019, 2020]
        @test all(.!historical.is_forecast)

        @test macro_series(src, "CAN", nothing, true).year == [2019, 2020, 2021]
        @test macro_series(src, "CAN", 2020:2021, true).year == [2020, 2021]
        @test macro_series(src, "USA", nothing, false).gdp_per_capita == [65000.0]
        @test_throws ErrorException macro_series(src, "FRA", nothing, false)
    end

    @testset "Le regroupement par ville reunit les aeroports d'une meme RMR" begin
        include(joinpath(JULIA_ROOT, "run", "extract_city_pairs.jl"))
        popfile = joinpath(mktempdir(), "pop.csv")
        CSV.write(popfile, DataFrame(
            year = fill(2019, 4), airport = ["YUL", "YYZ", "YTZ", "YVR"],
            cma = ["Montréal (CMA), Quebec", "Toronto (CMA), Ontario",
                   "Toronto (CMA), Ontario", "Vancouver (CMA), British Columbia"],
            population = [4.3e6, 6.5e6, 6.5e6, 2.7e6]); delim = ';')

        groups = city_groups(popfile)
        # YYZ et YTZ desservent la meme RMR : ils partagent un representant unique.
        @test groups["YYZ"] == groups["YTZ"]
        @test groups["YUL"] != groups["YYZ"]
        @test groups["YVR"] == "YVR"
    end

    @testset "La jointure de population somme les deux extremites" begin
        include(joinpath(JULIA_ROOT, "run", "extract_city_pairs.jl"))
        pairs = DataFrame(year = [2019, 2019, 2019], origin = ["YUL", "YUL", "YUL"],
                          dest = ["YYZ", "YVR", "ZZZ"],
                          actual_passengers = [1.0e6, 4.0e5, 5.0e3])
        popfile = joinpath(mktempdir(), "pop.csv")
        CSV.write(popfile, DataFrame(year = [2019, 2019, 2019],
                                     airport = ["YUL", "YYZ", "YVR"],
                                     population = [4.0e6, 6.0e6, 2.7e6]); delim = ';')

        joined = join_population(pairs, popfile)
        # `population` est la somme des deux extremites : hypothese de modelisation, pas fait.
        @test joined.population == [4.0e6 + 6.0e6, 4.0e6 + 2.7e6]
        @test joined.population_origin == [4.0e6, 4.0e6]
        # Une extremite sans population fait ecarter la paire, jamais completer d'une valeur
        # arbitraire : c'est le travers que toute cette branche corrige ailleurs.
        @test nrow(joined) == 2
        @test !("ZZZ" in joined.dest)
    end

    @testset "K1 et K2 de la loi portent le meme nom partout" begin
        # `parameters["k1"]` / `["k2"]` designaient les coefficients de forme "c" et "d" de
        # la courbe, PAS les constantes K1 et K2 de la loi de Kenza, lesquelles vivaient
        # sous `full_penetration` / `full_price_scale` puis sous des champs `calibration_*`.
        # Trois conventions pour deux constantes : origine probable de l'erreur de
        # KenzaProbabilisticModel, qui applique la loi avec K1 = K2 = 1.
        full = Models.KenzaModel()
        @test haskey(full.parameters, "kenza_k1") && haskey(full.parameters, "kenza_k2")
        @test haskey(full.parameters, "curve_c") && haskey(full.parameters, "curve_d")
        @test !haskey(full.parameters, "k1") && !haskey(full.parameters, "k2")

        # Valeurs du classeur d'origine, feuille "Full Kenza" cellules B1/B2.
        @test full.parameters["kenza_k2"] == 30.0
        @test full.parameters["kenza_k1"] == 0.8193343775346827

        indexed = Models.KenzaIndexedModel()
        Abstract.fit!(indexed, data)
        @test hasproperty(indexed, :kenza_k1) && hasproperty(indexed, :kenza_k2)

        # Les anciens noms restent acceptes, et visent bien la meme constante qu'avant.
        aliased = Models.KenzaModel()
        Abstract.fit!(aliased, data; k1=-6.0, k2=0.5, full_penetration=0.9, full_price_scale=25.0)
        @test aliased.parameters["curve_c"] == -6.0
        @test aliased.parameters["curve_d"] == 0.5
        @test aliased.parameters["kenza_k1"] == 0.9
        @test aliased.parameters["kenza_k2"] == 25.0
    end

    @testset "La provenance des intervalles est declaree, pas supposee" begin
        # L'interface intitulait "IC 95 %" une bande qui, avec les parametres par defaut des
        # cinq modeles, vaut exactement pred*0.8 .. pred*1.2. La branche calculant un vrai
        # intervalle sur les residus n'est atteinte que si monte_carlo_simulations > 0, ce
        # qui n'est le defaut d'aucun modele.
        for name in AF.ModelRegistry.list_models()
            model = AF.ModelRegistry.get_model(name)()
            Abstract.fit!(model, data)
            forecast = Abstract.predict(model, 4)
            @test "interval_method" in names(forecast)
            @test Abstract.interval_method(forecast) == Abstract.INTERVAL_FORFAIT
            # Le forfait est bien un forfait : la largeur ne porte aucune information.
            @test forecast.predicted_passengers_lower ≈ forecast.predicted_passengers .* 0.8
            @test forecast.predicted_passengers_upper ≈ forecast.predicted_passengers .* 1.2
        end

        # Un vrai intervalle est declare comme tel.
        tuned = Models.KenzaModel()
        Abstract.fit!(tuned, data)
        residual_based = Abstract.predict(tuned, 4; monte_carlo_simulations=500)
        @test Abstract.interval_method(residual_based) == Abstract.INTERVAL_RESIDUALS
        @test !(residual_based.predicted_passengers_upper ≈ residual_based.predicted_passengers .* 1.2)

        probabilistic = Models.KenzaProbabilisticModel()
        Abstract.fit!(probabilistic, data)
        @test Abstract.interval_method(Abstract.predict(probabilistic, 4)) == Abstract.INTERVAL_BOOTSTRAP

        # Les intitules ne promettent un IC que lorsque c'en est un.
        @test !occursin("IC", Abstract.interval_label(Abstract.INTERVAL_FORFAIT))
        @test occursin("IC 95", Abstract.interval_label(Abstract.INTERVAL_RESIDUALS))
        # Une methode inconnue est nommee prudemment, jamais presentee comme un IC.
        @test !occursin("IC", Abstract.interval_label("inconnue"))
    end

    @testset "L'export JSON survit aux valeurs non finies" begin
        # JSON n'admet ni NaN ni Infinity : JSON3.write leve sur un tel nombre. Or le code en
        # produit legitimement (growth_rate sur une prevision nulle, R2 sur variance nulle).
        # prepare_json_for_export, dont c'est le role, retournait son argument inchange :
        # to_json echouait donc la ou CSV, Excel, PDF et HTML passaient sans probleme.
        collapsing = AF.ForecastService.run_forecast(
            "kenza_simplifie", data, Dict{String,Any}("ticket_price_inflation" => 0.35), 5)
        growth = [row["growth_rate"] for row in collapsing["forecast"]]
        # L'annee ou la prevision s'effondre depend des coefficients par defaut du modele :
        # elle s'est deplacee de l'indice 2 a l'indice 4 le jour ou C1 et C2 ont pris les
        # valeurs calibrees du classeur Excel. On localise donc le NaN au lieu de le supposer.
        nan_index = findfirst(isnan, growth)
        @test nan_index !== nothing

        json = AF.ExportService.to_json(collapsing)
        @test !occursin("NaN", json)
        @test !occursin("Infinity", json)
        reparsed = JSON3.read(json)                       # invalide -> leverait ici
        @test reparsed["forecast"][nan_index]["growth_rate"] === nothing

        # Les quatre autres exports acceptaient deja ces valeurs : ils ne doivent pas regresser.
        @test length(AF.ExportService.to_csv(collapsing)) > 0
        @test length(AF.ExportService.to_excel(collapsing)) > 0
        @test length(AF.ExportService.to_pdf(collapsing)) > 0
        @test length(AF.ExportService.to_html(collapsing)) > 0

        # missing devient null, et la conversion est recursive.
        prepared = AF.Formatters.prepare_json_for_export(
            Dict("a" => Inf, "b" => -Inf, "c" => NaN, "d" => 1.5,
                 "e" => [NaN, 2.0], "f" => Dict("g" => NaN)))
        @test prepared["a"] === nothing && prepared["b"] === nothing && prepared["c"] === nothing
        @test prepared["d"] == 1.5
        @test prepared["e"] == [nothing, 2.0]
        @test prepared["f"]["g"] === nothing
    end

    @testset "L'export PDF translittere les accents" begin
        # Les caracteres non-ASCII etaient supprimes : "prevision" devenait "prvision".
        @test AF.ExportService._pdf_ascii("Prévision à Montréal") == "Prevision a Montreal"

        result = AF.ForecastService.run_forecast("kenza", data, Dict{String,Any}(), 5)
        pdf = AF.ExportService.to_pdf(result)
        @test length(pdf) > 1000
        @test String(pdf[1:8]) == "%PDF-1.4"
    end

    @testset "Les formateurs comptent des caracteres, pas des octets" begin
        F = AF.Formatters

        # text[1:n] indexe des octets : la coupe tombait au milieu d'un « é ».
        @test F.truncate_text("aéroport de Montréal", 6) == "aér..."
        @test F.truncate_text("Montréal–Toronto : évolution", 10) == "Montréa..."

        # La longueur rendue est exactement celle demandee, accents compris.
        long = "Prévision de la demande aérienne pour la région métropolitaine"
        for n in 4:40
            @test length(F.truncate_text(long, n)) == n
        end

        # « ... » depassait la limite quand elle valait moins de trois caracteres.
        @test F.truncate_text("abcdef", 2) == "ab"
        @test F.truncate_text("abcdef", 0) == ""
        @test F.truncate_text("abc", 10) == "abc"
    end

    @testset "format_dataframe est appelable sous ses deux formes" begin
        F = AF.Formatters
        df = DataFrame(taux = [0.5, -0.05], montant = [1234.5, 2.0])

        # Sans formats : Dict() est un Dict{Any,Any}, qui ne descend pas de Dict{String,Dict}.
        @test F.format_dataframe(df) == df

        # Avec le litteral naturel, qui s'infere en Dict{String,Dict{String,String}}.
        out = F.format_dataframe(df, Dict("taux" => Dict("type" => "percentage")))
        @test out.taux == ["50.0%", "-5.0%"]

        # Le seuil de conversion etait asymetrique : -0,05 restait « -0.05% ».
        @test F.format_percentage(-0.05) == "-5.0%"
        @test F.format_percentage(0.05) == "5.0%"

        # Une colonne qui porte un `missing` ne fait plus echouer le tableau entier.
        creux = DataFrame(taux = [0.5, missing])
        @test F.format_dataframe(creux, Dict("taux" => Dict("type" => "percentage"))).taux ==
              ["50.0%", "missing"]

        # log(negatif) levait DomainError ; DateTime ignorait format_str.
        @test F.format_file_size(-5) == "-5 Bytes"
        @test F.format_date(DateTime(2020, 1, 2, 3)) == "02/01/2020"
    end

    @testset "Le verdict du validateur est propage a l'appelant" begin
        # `validate` produisait deja le diagnostic, mais process_uploaded_bytes posait
        # "success" => true sans le consulter et process_uploaded_file n'exposait aucune
        # cle "success". La GUI ne regarde que "success" : elle acceptait un fichier
        # declare invalide, puis le premier « Lancer le modele » remontait
        # `MethodError: no method matching Float64(::Missing)` dans la barre d'etat.
        clean = read(SAMPLE)
        ok = AF.DataService.process_uploaded_bytes("sample.csv", clean)
        @test ok["success"] === true
        @test ok["error"] === nothing
        # `String(::Vector{UInt8})` vide le tableau qu'on lui passe : _read_csv_bytes
        # detruisait les octets de son appelant, qui ne pouvait plus ni les relire ni
        # reessayer. L'appel ci-dessus doit les laisser intacts.
        @test length(clean) == filesize(SAMPLE)

        lines = split(String(copy(clean)), "\r\n")
        fields = split(lines[4], ';')
        fields[end] = ""                       # actual_passengers manquant
        lines[4] = join(fields, ';')
        holed = Vector{UInt8}(join(lines, "\r\n"))

        ko = AF.DataService.process_uploaded_bytes("trou.csv", holed)
        @test ko["success"] === false
        @test occursin("actual_passengers", ko["error"])
        # Le DataFrame reste expose : l'appelant doit pouvoir montrer ce qui cloche.
        @test ko["dataframe"] isa DataFrame
        # Et c'est bien l'entree qui aurait fait echouer le modele.
        @test_throws MethodError AF.ForecastService.run_forecast(
            "kenza", ko["dataframe"], Dict{String,Any}(), 3)
    end

    @testset "Une population invalide ne vide pas la prevision" begin
        # `max.(population, 1e-8)` ne protegeait de rien : une population nulle ne donne
        # plus une division par zero, elle donne un trafic par habitant de l'ordre de 1e15.
        # Cette valeur dominait la regression de kenza_simplifie_combine, dont la droite de
        # tendance plongeait, et le max.(0.0, .) suivant ecrasait toute la projection : la
        # prevision sortait ENTIEREMENT NULLE, sans message.
        for (label, idx) in ("premiere ligne" => 1, "derniere ligne" => nrow(data))
            broken = copy(data)
            broken.population = Float64.(broken.population)
            broken.population[idx] = 0.0
            for name in AF.ModelRegistry.list_models()
                model = AF.ModelRegistry.get_model(name)()
                Abstract.fit!(model, broken)
                predictions = Abstract.predict(model, 3).predicted_passengers
                @test all(isfinite, predictions)
                @test any(>(0), predictions)
            end
        end

        # Le repli est l'annee valide la plus proche, pas la premiere ni la mediane : une
        # population evolue de quelques pour cent par an.
        series = [100.0, 0.0, 300.0, 400.0]
        @test Models._sanitize_population(series) == [100.0, 100.0, 300.0, 400.0]
        @test Models._sanitize_population([100.0, missing, missing, 400.0]) ==
              [100.0, 100.0, 400.0, 400.0]
        @test Models._sanitize_population([1.0, 2.0]) == [1.0, 2.0]
        @test_throws ErrorException Models._sanitize_population([0.0, missing])
    end

    @testset "Les indicateurs ne sont ni doubles ni desordonnes" begin
        # calculate_metrics publie chaque indicateur sous deux casses pour des
        # consommateurs qui n'accordent pas leurs cles : l'interface en affichait dix la
        # ou il y en a cinq, dans l'ordre arbitraire d'un Dict.
        raw = Abstract.calculate_metrics([1.0, 2.0, 3.0], [1.1, 2.1, 2.9])
        shown = Abstract.displayable_metrics(raw)
        @test length(raw) == 10
        @test length(shown) == 5
        @test first.(shown) == ["MAE", "MAPE", "MSE", "R2", "RMSE"]

        # Les valeurs non finies sont ecartees, pas affichees en "NaN".
        @test isempty(Abstract.displayable_metrics(Dict("R2" => NaN, "MAE" => Inf)))
        # Les prefixes restent distincts : in_sample_R2 n'est pas un doublon de R2.
        prefixed = Abstract.displayable_metrics(Dict("R2" => 1.0, "r2" => 1.0,
                                                     "in_sample_R2" => 0.5, "oos_R2" => 0.2))
        @test first.(prefixed) == ["R2", "in_sample_R2", "oos_R2"]
    end

    @testset "Les colonnes de prevision sortent dans un ordre lisible" begin
        # Les points transitent par des Dict : DataFrame(result["forecast"]) en heritait
        # l'ordre de parcours, et `year` se retrouvait en onzieme colonne du CSV exporte,
        # derriere `continuity_adjustment_applied`.
        result = AF.ForecastService.run_forecast("kenza", data, Dict{String,Any}(), 5)
        cols = names(AF.ForecastService.forecast_frame(result))
        @test cols[1] == "year"
        @test cols[2] == "predicted_passengers"
        @test issorted(cols[findfirst(==("ticket_price"), cols) + 1:end])
        @test sort(cols) == sort(names(DataFrame(result["forecast"])))
    end
end
