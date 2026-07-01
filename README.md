# AirTrafficForecaster - Julia

Module Julia de prevision du trafic aerien base sur les modeles econometriques Kenza. Ce dossier contient une implementation modulaire des variantes Kenza, une interface graphique GTK, des scripts de test, et des donnees de validation issues de l'ancien classeur Excel Kenza.

## Objectif

Le projet vise a porter et fiabiliser les algorithmes Kenza historiquement implementes dans Excel vers Julia, tout en conservant une architecture extensible:

- modeles Kenza classiques, simplifies, indexes et probabilistes;
- comparaison numerique avec les sorties Excel;
- execution en ligne de commande;
- interface graphique locale;
- generation de rapports de validation.

## Structure

```text
julia/
  AirTrafficForecaster.jl       # Module principal
  Project.toml                  # Environnement Julia
  Manifest.toml                 # Versions resolues des dependances
  config/
    model_metadata.json         # Parametres et descriptions des modeles
  data/
    sample.csv                  # Jeu de donnees exemple
  models/
    abstract_model.jl           # Interface commune des modeles
    kenza_models.jl             # Implementations Kenza
    registry.jl                 # Registre des modeles
  services/
    data_service.jl             # Chargement/normalisation des donnees
    forecast_service.jl         # Execution des previsions
    export_service.jl           # Export des resultats
  run/
    test.jl                     # Test des modeles sur sample.csv
    validate.jl                 # Validation Julia vs Excel
    gui.jl                      # Interface graphique
  old/
    *.csv                       # Donnees de validation extraites d'Excel
    report.py                   # Rapport Excel avec graphiques natifs
    comparaison.latex           # Notes/comparaisons techniques
```

## Prerequis

- Julia 1.10 ou plus recent recommande
- Python 3.10+ uniquement pour `old/report.py`
- Dependances Julia definies dans `Project.toml`

Installation des dependances Julia:

```bash
julia --project=julia -e "import Pkg; Pkg.instantiate()"
```

## Donnees d'entree

Les modeles attendent un CSV contenant au minimum:

```text
year, actual_passengers, population, gdp_per_capita
```

Certains modeles utilisent aussi:

```text
ticket_price
```

Exemple disponible:

```text
julia/data/sample.csv
```

## Modeles disponibles

Les modeles sont enregistres dans `models/registry.jl`.

| Nom | Description courte |
|---|---|
| `kenza` | Modele Full Kenza logistique avec prix billet et PIB/habitant |
| `kenza_simplifie` | Modele lineaire simplifie |
| `kenza_simplifie_combine` | Modele simplifie combinant tendance et elasticite |
| `kenza_simplifie_indexe` | Modele lineaire indexe sans prix direct |
| `kenza_indexed` | Modele Indexed Kenza logistique sans prix direct |


Les parametres par defaut et les descriptions sont dans:

```text
julia/config/model_metadata.json
```

## Lancer les tests

Depuis la racine du depot:

```bash
julia --project=julia julia/run/test.jl
```

Ce script charge `data/sample.csv`, execute les modeles Kenza et affiche les metriques:

- RMSE
- MAE
- R2
- MAPE
- largeur moyenne des intervalles de prevision

## Validation contre Excel

Le script de validation compare les sorties Julia avec les resultats caches provenant de l'ancien classeur Excel.

```bash
julia --project=julia julia/run/validate.jl
```

Fichiers utilises par defaut:

```text
julia/old/kenza_excel_validation_input.csv
julia/old/kenza_excel_validation_full_input.csv
julia/old/kenza_excel_validation_expected.csv
julia/old/kenza_excel_validation_params.csv
```

Sortie generee:

```text
julia/old/kenza_excel_validation_report.csv
```

Options utiles:

```bash
julia --project=julia julia/run/validate.jl \
  --input path/to/input.csv \
  --full-input path/to/full_input.csv \
  --expected path/to/expected.csv \
  --params path/to/params.csv \
  --output path/to/report.csv
```

Note: certains exports Excel historiques peuvent avoir un decalage d'un an sur `excel_indexed_forecast`, utilisable ainsi:

```bash
julia --project=julia julia/run/validate.jl
```

Sous PowerShell:

```powershell
julia --project=julia julia/run/validate.jl
```

## Generer le rapport Excel de validation

Le script Python `old/report.py` lit le rapport CSV et cree un classeur Excel avec:

- les donnees de validation;
- un graphique Excel natif par modele;
- un graphique de l'erreur absolue `abs_error` par modele.

Commande:

```bash
cd julia/old
python report.py
```

Sortie:

```text
julia/old/kenza_validation_report.xlsx
```

Si le fichier `.xlsx` est deja ouvert dans Excel, fermez-le avant de relancer le script.

## Interface graphique

L'interface GTK permet de charger un CSV, choisir un modele, modifier ses parametres, lancer une prevision et exporter les resultats.

```bash
julia --project=julia julia/run/gui.jl
```

## Utilisation comme module Julia

Exemple minimal:

```julia
import Pkg
Pkg.activate(".")

include("julia/AirTrafficForecaster.jl")
using .AirTrafficForecaster
using CSV, DataFrames

data = CSV.read("julia/data/sample.csv", DataFrame)
params = Dict{String,Any}("optimize_parameters" => false)

result = AirTrafficForecaster.ForecastService.run_forecast(
    "kenza",
    data,
    params,
    20,
)

println(result["metrics"])
println(first(result["forecast"], 3))
```

## Etat de portage Excel

Le portage vise a reproduire les feuilles principales de l'ancien fichier Kenza:

- `Full Kenza` -> `kenza`
- `Simplified Kenza` -> `kenza_simplifie` et `kenza_simplifie_combine`
- `Indexed Kenza` -> `kenza_indexed`

La validation numerique est centralisee dans `run/validate.jl`. Les fichiers dans `old/` servent de reference pour comparer les previsions Julia aux sorties Excel.

## Conseils de developpement

Pour ajouter un modele:

1. Ajouter le type et ses methodes `fit!` / `predict` dans `models/kenza_models.jl`.
2. L'enregistrer dans `models/registry.jl`.
3. Ajouter ses parametres dans `config/model_metadata.json`.
4. L'ajouter aux tests dans `run/test.jl`.
5. Si necessaire, l'ajouter a la validation dans `run/validate.jl`.

## Licence

MIT licence.
