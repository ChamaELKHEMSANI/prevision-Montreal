# AirTrafficForecaster - Julia

Module Julia de prevision du trafic aerien base sur les modeles econometriques Kenza. Ce dossier contient une implementation modulaire des variantes Kenza, une interface graphique GTK, des scripts de test, et des donnees de validation issues de l'ancien classeur Excel Kenza.

## Objectif

Le projet vise a porter et fiabiliser les algorithmes Kenza historiquement implementes dans Excel vers Julia, tout en conservant une architecture extensible:

- modeles Kenza classiques, simplifies et indexes (variante probabiliste prevue);
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
    sample.csv                  # Jeu de donnees exemple (delimiteur ;)
    final_dataset*.csv          # Jeux de travail, non utilises par les scripts
  models/
    abstract_model.jl           # Interface commune, metriques, continuite
    kenza_models.jl             # Implementations Kenza
    registry.jl                 # Registre des modeles
  services/
    data_service.jl             # Chargement/normalisation des donnees
    forecast_service.jl         # Execution des previsions
    export_service.jl           # Export des resultats (JSON, Excel, PDF)
  utils/
    validators.jl               # Controle des donnees d'entree
    formatters.jl               # Formatage des valeurs et des exports
  run/
    Project.toml                # Copie de l'environnement (non utilisee)
    test.jl                     # Test des modeles sur sample.csv
    regressions.jl              # Tests de non-regression (bugs corriges)
    validate.jl                 # Validation Julia vs Excel
    gui.jl                      # Interface graphique
  result/
    forecast_report*.xlsx       # Exports sauvegardes manuellement
  old/
    kenza_excel_validation_*.csv   # Donnees de validation extraites d'Excel
    kenza_validation_report.xlsx   # Sortie de report.py
    report.py                      # Rapport Excel avec graphiques natifs
```

## Prerequis

- Julia 1.10 ou plus recent recommande (teste sous 1.12)
- Python 3.10+ uniquement pour `old/report.py`, avec `pandas` et `openpyxl`
- Dependances Julia definies dans `Project.toml`

Installation des dependances Julia:

```bash
julia --project=julia -e "import Pkg; Pkg.instantiate()"
```

## Donnees d'entree

Les modeles attendent un CSV contenant les cinq colonnes suivantes:

```text
year, actual_passengers, population, gdp_per_capita, ticket_price
```

Les cinq sont obligatoires, `ticket_price` comprise. Les modeles indexes ne
l'utilisent pas dans leur formule, mais la projection macro commune
(`_future_macro`) la lit pour tous, et un fichier sans cette colonne echoue avec
`ArgumentError: column name :ticket_price not found`.

Le delimiteur peut etre `;` ou `,` : `DataService` le detecte a la lecture, et la
virgule decimale est acceptee.

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

La suite de non-regression couvre les bugs corriges (colonne de prevision unique,
`optimize_parameters`, metriques hors echantillon, validateur, reproductibilite):

```bash
julia --project=julia julia/run/regressions.jl
```

### Lire les metriques

Pour `kenza_indexed`, l'ajustement reconstruit l'indice de prix implicite en inversant
analytiquement la distribution a partir du trafic observe : le reappliquer redonne
exactement les donnees d'entree. Ses metriques dans l'echantillon valent donc
mecaniquement R2 = 1 et RMSE = 0 sans mesurer aucun pouvoir predictif. Le modele publie
pour cette raison des metriques de validation glissante hors echantillon (`R2`, `RMSE`,
... issues des cles `oos_*`), les valeurs in-sample restant accessibles sous
`in_sample_*` a titre de controle de calage.

### Colonnes de prevision

`predicted_passengers` porte toujours la prevision **finale**, correction de continuite
comprise : c'est la colonne que tracent l'interface et qu'exportent les rapports.
`predicted_passengers_raw` conserve la valeur d'avant correction, a des fins de
diagnostic uniquement. Passer `apply_continuity_adjustment => false` desactive la
correction de saut entre historique et prevision (ce que fait `run/validate.jl`, Excel
ne l'appliquant pas).

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

Les deux fichiers d'entree ne sont pas interchangeables et refletent deux bases de
population differentes:

- `kenza_excel_validation_full_input.csv` sert au modele `kenza` (population de
  l'origine du flux, ~32 millions);
- `kenza_excel_validation_input.csv` sert aux quatre autres (population de la
  destination, ~328 millions).

Note: le fichier `expected` fourni presente un decalage d'un an sur
`excel_indexed_forecast`. La comparaison le corrige par defaut. Le decalage se
pilote par la variable d'environnement `INDEXED_YEAR_SHIFT` (valeur par defaut
`1`); mettre `0` si le CSV de reference est corrige:

```bash
INDEXED_YEAR_SHIFT=0 julia --project=julia julia/run/validate.jl
```

Sous PowerShell:

```powershell
$env:INDEXED_YEAR_SHIFT=0; julia --project=julia julia/run/validate.jl
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
Pkg.activate("julia")   # et non ".", la racine du depot n'a pas de Project.toml

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
- `Indexed Kenza` -> `kenza_indexed` et `kenza_simplifie_indexe`

La validation numerique est centralisee dans `run/validate.jl`. Les fichiers dans `old/` servent de reference pour comparer les previsions Julia aux sorties Excel.

## Conseils de developpement

Pour ajouter un modele:

1. Ajouter le type et ses methodes `fit!` / `predict` dans `models/kenza_models.jl`.
2. L'enregistrer dans `models/registry.jl`.
3. Ajouter ses parametres dans `config/model_metadata.json`.
4. L'ajouter aux tests dans `run/test.jl`.
5. Si necessaire, l'ajouter a la validation dans `run/validate.jl`.
6. Couvrir son comportement dans `run/regressions.jl`.

Un modele non implemente ne doit pas etre enregistre dans `models/registry.jl`:
il apparaitrait dans l'interface graphique et dans le classement de `run/test.jl`
a cote de modeles valides contre Excel. C'est le cas de `kenza_probabilistic`,
present dans `models/kenza_models.jl` mais volontairement non enregistre.

## Licence

MIT licence.
