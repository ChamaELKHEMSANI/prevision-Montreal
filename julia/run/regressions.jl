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

using DataFrames
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

    @testset "L'export PDF translittere les accents" begin
        # Les caracteres non-ASCII etaient supprimes : "prevision" devenait "prvision".
        @test AF.ExportService._pdf_ascii("Prévision à Montréal") == "Prevision a Montreal"

        result = AF.ForecastService.run_forecast("kenza", data, Dict{String,Any}(), 5)
        pdf = AF.ExportService.to_pdf(result)
        @test length(pdf) > 1000
        @test String(pdf[1:8]) == "%PDF-1.4"
    end
end
