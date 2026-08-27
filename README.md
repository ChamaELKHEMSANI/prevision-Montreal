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
docs/
  Guide_utilisateur.md          # Guide utilisateur : SOURCE de reference
  Guide_utilisateur.pdf         # Mise en page du precedent (bash docs/build_pdf.sh)
  build_pdf.sh                  # Regeneration du PDF via pandoc + xelatex
  images/                       # Captures d'ecran du guide
  Presentation_methode_Kenza.pptx  # Presentation de la methode et de l'outil
  Presentation_methode_Kenza.pdf   # Meme presentation, au format PDF
old/
  Guide_utilisateur.pdf         # Export Google Docs d'origine, remplace
  README.md                     # Ce qu'il decrit et pourquoi il ne fait plus foi
tools/
  pdf2md.py                     # Conversion du guide PDF vers Markdown
  fix_pptx.py                   # Corrections de fond de la presentation
  generalize_pptx.py            # Depersonnalisation de la presentation
  README.md                     # Mode d'emploi et enchainement des trois
```

Le guide utilisateur decrit l'installation, l'interface, le chargement des donnees,
le choix et le parametrage des modeles, la lecture des resultats et les exports.

- [docs/Guide_utilisateur.md](docs/Guide_utilisateur.md) — la reference. C'est le
  fichier a modifier ; son contenu suit le code : modeles reellement enregistres, noms
  actuels des parametres, nature des bandes d'incertitude, contenu reel des exports.
- [docs/Guide_utilisateur.pdf](docs/Guide_utilisateur.pdf) — la mise en page du
  precedent, a regenerer par `bash docs/build_pdf.sh` apres chaque modification.
- [old/Guide_utilisateur.pdf](old/Guide_utilisateur.pdf) — l'export Google Docs
  d'origine, conserve pour la trace. Il ne fait plus foi ; voir [old/README.md](old/README.md).

[docs/Presentation_methode_Kenza.pptx](docs/Presentation_methode_Kenza.pptx) presente la
methode Kenza, ses fondements, l'outil et ses resultats. Ses chiffres ont ete recalcules
sur le code actuel (calage 1990-2011, validation 2012-2019 sur `data/sample.csv`) et ses
noms de parametres suivent le renommage curve_c / curve_d / kenza_k1 / kenza_k2. Les
mentions de date, d'auditoire et les adresses de courriel en ont ete retirees : le depot
est public.

Les scripts qui ont produit ces deux documents sont dans [tools/](tools/), avec leur mode
d'emploi : ils portent la trace des decisions prises, et une correction de fond se fait
dans `tools/fix_pptx.py` puis se propage en rejouant la chaine.

Les captures d'ecran de la presentation datent de l'interface d'origine et n'ont pas ete
refaites : les diapositives 13 et 14 le signalent, leur capture montrant encore les
anciens noms de parametres et les anciens chiffres. Le PDF est produit par
`libreoffice --headless --convert-to pdf docs/Presentation_methode_Kenza.pptx`.

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

### Nom des parametres

La loi de Kenza s'ecrit `D = P x K1 x F*(K2 x pn)`, ou `pn` est le prix normalise, `K2` le
seuil de revenu normalise et `K1` une constante agregee. La courbe `F*` a par ailleurs
quatre coefficients de forme `a`, `b`, `c`, `d`.

Le code distingue explicitement les deux familles:

| Parametre | Role | Valeur Excel |
|---|---|---|
| `kenza_k1` | constante K1 de la loi | `Full Kenza` cellule B2 = 0.8193343775346827 |
| `kenza_k2` | seuil K2 de la loi | `Full Kenza` cellule B1 = 30 |
| `curve_c`, `curve_d` | coefficients de forme de `F*` | `k1_c` = -6.59917386, `k2_d` = 0.39546328 |
| `distribution_a`, `distribution_b` | coefficients de forme de `F*` | 1.1572, 4.3517429 |

Pour `kenza_indexed`, K1 et K2 ne sont pas des parametres mais sont calibres sur les
donnees; ils sont exposes par les champs `kenza_k1` et `kenza_k2` du modele ajuste.

Les anciens noms `k1`, `k2`, `full_penetration` et `full_price_scale` restent acceptes en
entree. `k1` et `k2` designaient les coefficients `c` et `d`, et non les constantes K1 et
K2 de la loi: cette homonymie est vraisemblablement a l'origine de l'erreur du modele
probabiliste, qui applique la loi en laissant K1 et K2 implicitement egaux a 1.

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

Ce backtest est **multi-pas** (`oos_horizon`, 5 ans par defaut), et doit le rester. La
correction de continuite ancre la premiere annee projetee sur la derniere observation
d'entrainement: un backtest a un pas reproduit donc exactement la prevision naive "report
de la derniere valeur" et rend le meme chiffre pour les cinq modeles, sans rien mesurer de
leur dynamique propre. `AbstractModel.rolling_backtest_metrics` est reutilisable pour
n'importe quel modele:

```julia
AirTrafficForecaster.AbstractModel.rolling_backtest_metrics(
    AirTrafficForecaster.ModelRegistry.get_model("kenza"), data; horizon=5)
```

### Intervalles de prevision

`predicted_passengers_lower` et `_upper` n'ont pas la meme signification selon les
modeles et les parametres. La colonne `interval_method` de chaque prevision porte leur
provenance:

| Valeur | Signification | Quand |
|---|---|---|
| `forfait_20pct` | `pred x 0.8` a `pred x 1.2` — forfait indicatif, sans contenu statistique | defaut de tous les modeles |
| `residus_z95` | IC 95 % construit sur l'ecart-type des residus historiques (z = 1.96) | `kenza` avec `monte_carlo_simulations > 0` |
| `quantiles_bootstrap` | quantiles empiriques 5 % / 95 % des tirages | modele probabiliste |

L'interface et `run/test.jl` intitulent la bande d'apres cette colonne. Avec les
parametres par defaut, la bande affichee est un forfait: la largeur moyenne rapportee par
`run/test.jl` vaut alors exactement `0.4 x` la moyenne des previsions et ne mesure aucune
incertitude.

### Colonnes de prevision

`predicted_passengers` porte toujours la prevision **finale**, correction de continuite
comprise : c'est la colonne que tracent l'interface et qu'exportent les rapports.
`predicted_passengers_raw` conserve la valeur d'avant correction, a des fins de
diagnostic uniquement. Passer `apply_continuity_adjustment => false` desactive la
correction de saut entre historique et prevision (ce que fait `run/validate.jl`, Excel
ne l'appliquant pas).

## Extraire des series par paire de villes

`run/extract_city_pairs.jl` construit des series annuelles par paire origine-destination a
partir des fichiers annuels de trafic vrai O&D (`CA - <annee> - pax.xlsx`).

```bash
julia --project=julia julia/run/extract_city_pairs.jl \
  --source "/chemin/Data DS" --airport YUL --output julia/data/yul_pairs.csv
```

Options: `--airport CODE` (toutes les paires touchant cet aeroport), `--pair A-B`,
`--years 2005-2019`, `--directional`, `--macro FILE.csv` pour joindre population et
PIB/habitant sur `year`, `--output`. `--airport` et `--pair` sont repetables et le filtrage
se fait pendant la lecture: extraire cent paires coute le meme passage qu'une seule.

Compter environ trois minutes par fichier annuel (~690 000 lignes).

### Population des villes

`run/fetch_statcan_population.jl` recupere la population annuelle des regions
metropolitaines de recensement aupres de Statistique Canada (tableau 17-10-0135-01,
Licence du gouvernement ouvert) et la restitue par code d'aeroport, de 2001 a 2022.

```bash
julia --project=julia julia/run/fetch_statcan_population.jl \
  --years 2005-2020 --output julia/data/population_rmr.csv

julia --project=julia julia/run/extract_city_pairs.jl \
  --source "/chemin/Data DS" --airport YUL \
  --population julia/data/population_rmr.csv --output julia/data/yul_pairs.csv
```

`--population` ajoute `population_origin`, `population_dest` et leur somme dans
`population`. **Sommer les deux extremites est une hypothese de modelisation**, pas un
fait: elle suppose que les deux villes engendrent la demande a parts proportionnelles a
leur taille. Une paire dont une extremite n'a pas de population connue est ecartee, jamais
completee d'une valeur arbitraire.

La correspondance aeroport -> RMR est une table explicite dans le script, volontairement
lisible plutot qu'un appariement automatique par coordonnees: une erreur d'affectation s'y
verrait. `--list-geo` affiche les intitules disponibles.

Une RMR n'est pas une zone de chalandise: pour Montreal en 2019, 4 334 308 contre
4 649 265 dans le fichier de chalandise `2019-2045 - CA.xlsx` du Drive, soit 7 % d'ecart.
Ce dernier ne couvre par ailleurs que 2019-2045 et ne peut donc pas servir a l'ajustement
sur l'historique.

### PIB par habitant

`run/build_macro_series.jl` extrait la serie annuelle de PIB par habitant d'un pays depuis
la chaine GDP du projet (FMI, Perspectives de l'economie mondiale, 2000-2030).

```bash
julia --project=julia julia/run/build_macro_series.jl \
  --source "/chemin/GDP/data/processed/gdp_unified_2000_2030.csv" \
  --country CAN --years 2005-2020 --output julia/data/macro_canada.csv
```

Les annees de prevision sont ecartees par defaut (`--with-forecast` pour les conserver):
les melanger a l'historique dans un jeu d'ajustement reviendrait a calibrer un modele sur
les projections d'un autre.

Ce PIB est **national**. Toutes les paires d'un meme pays partagent donc exactement le meme
prix normalise `pn`, ce qui suffit pour une premiere preuve de concept — le classeur Kenza
d'origine raisonnait deja au niveau national — mais ignore l'ecart de revenu entre
metropoles. Statistique Canada publie un PIB par division de recensement (tableau
36-10-0468-01) pour descendre au niveau metropolitain.

Deux limites a connaitre:

- **Ces fichiers ne portent pas de tarif.** Les series produites conviennent a
  `kenza_indexed` et `kenza_simplifie_indexe`, qui reconstruisent un indice de prix
  implicite, et non a `kenza` ni `kenza_simplifie`, qui exigent `ticket_price`.
- **La base BTS DB1B porte des tarifs mais est exclusivement domestique americaine.**
  Verifie: origines et destinations y sont a 100 % "US", et ni YUL ni YYZ n'y figurent.
  Elle ne peut pas servir pour un flux canadien.

### Regrouper les aeroports d'une meme ville

`--group-by-city` reunit, avant agregation, les aeroports desservant la meme RMR, d'apres
la colonne `cma` du fichier `--population`.

Ce n'est pas cosmetique. Sur Montreal-Toronto, de 2007 a 2019:

| serie | evolution |
|---|---|
| YYZ seul | -34.8 % |
| YTZ seul | +143 % |
| marche reuni | -13.6 % |

L'ouverture de Porter a Billy Bishop en 2007 fait passer YTZ de 17 a 255 673 passagers.
Scinder le marche produit deux series dominees par cette substitution, qu'aucun modele
pilote par la population et le revenu ne peut representer.

### Evaluer une paire

`run/evaluate_pair.jl` ajuste les modeles sur une paire et rapporte leur performance hors
echantillon, comparee a deux references naives evaluees sur exactement le meme protocole.

```bash
julia --project=julia julia/run/evaluate_pair.jl \
  --series julia/data/yul_series.csv --pair YUL-YYZ --horizon 3
```

`--list` enumere les paires disponibles. Seuls les modeles indexes sont evalues: les series
extraites ne portent pas de tarif.

Les references naives ne sont pas decoratives. Un R2 dans l'echantillon ne dit rien du
pouvoir predictif — pour `kenza_indexed` il vaut 1 par construction — et un R2 hors
echantillon negatif signifie « moins bon que la moyenne de la serie ». Un modele qui ne bat
pas le report de la derniere valeur observee n'apporte rien qu'une regle d'une ligne ne
donnerait deja.

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

MIT. Voir le fichier [LICENSE](LICENSE).
