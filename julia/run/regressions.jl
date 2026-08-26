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
