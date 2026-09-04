# Outils de conversion documentaire

Trois scripts Python, ecrits pour des transformations ponctuelles mais conserves
parce qu'ils encodent des decisions qu'on voudra peut-etre rejouer ou verifier.

Ils sont hors de la chaine Julia : rien dans `julia/` n'en depend, et le projet
fonctionne sans eux. Ils ne demandent aucune dependance au-dela de la
bibliotheque standard, sauf `pdf2md.py` qui utilise `pdfminer.six`.

---

## `pdf2md.py` — PDF Google Docs vers Markdown

Convertit `old/Guide_utilisateur.pdf` en `docs/Guide_utilisateur.md`.

```bash
python3 tools/pdf2md.py old/Guide_utilisateur.pdf images > docs/Guide_utilisateur.md
pdfimages -png -p old/Guide_utilisateur.pdf docs/images/capture   # puis renommer
```

Le PDF n'ayant ni niveau de titre ni style nomme, la structure est deduite de la
GEOMETRIE plutot que du texte aplati : les titres de la taille des caracteres
(17 pt, 14 pt, 11,5 pt, 11 pt), les tableaux des filets reellement traces, le code
de la police Consolas — au fil du texte comme en bloc, etiquette de langage
comprise.

Trois pieges propres a cet export sont traites :

- **Les cellules etroites coupent les identifiants** — « kenza_simpli » + « fie ».
  Le recollage ne s'applique que si le fragment de gauche atteint le bord utile de
  la cellule, marge interne deduite. Sans ce test geometrique, « Le plus bas » +
  « possible » devenait « baspossible ».
- **Google Docs n'emet pas toujours de glyphe espace** : la separation des mots
  tient a l'ecart horizontal. Les cellules sortaient en « Nomaffiche ».
- **Le texte s'ecoule autour des captures** : inserer l'image des qu'on la
  rencontre coupait la phrase en deux.

Le Markdown est desormais la source de reference du guide. Ce script n'a donc plus
vocation a servir, sauf pour reconstruire une autre version du PDF d'origine.

### Faut-il en faire un outil generique ? Non.

La question s'est posee : l'approche — deduire la structure de la geometrie plutot
que du texte aplati — se generalise a tout export Google Docs ou Word. La reponse
est venue d'une mesure, faite le 27 aout 2026 sur `old/Guide_utilisateur.pdf`
contre `pymupdf4llm` 1.28.2.

| | `pdf2md.py` | `pymupdf4llm` |
|---|---|---|
| couverture des mots | **99,9 %** | 99,8 % |
| tableaux detectes | 15 | **17** |
| titres | 185 | 305 |
| blocs de code | 13 | **16** |
| legendes de figures | 7/7 | 7/7 |
| **identifiants coupes recolles** | **5 sur 5** | **0 sur 3** |
| images extraites | 7 | 0 (option requise) |
| lignes a maintenir | 438 | **0** |

`pymupdf4llm` egale ou depasse ce script partout, sauf sur un point : il conserve
la coupure de cellule en `<br>` au lieu de recoller les identifiants.

    pymupdf4llm :  |Kenza Simplifie Combine|`kenza_simpli`<br>`fie_combine`|…
    pdf2md.py   :  | Kenza Simplifie Combine | kenza_simplifie_combine | …

A noter : la reconstruction des espaces, qu'on pouvait croire distinctive, n'en est
pas une — `pymupdf4llm` les restitue correctement. L'avantage se reduit donc au
recollage des identifiants, soit une trentaine de lignes de post-traitement sur sa
sortie. Pas de quoi maintenir 438 lignes.

**Ce qui justifie tout de meme de garder ce script**, ce n'est pas sa qualite
d'extraction : c'est sa licence. `pdfminer.six` est en MIT, comme ce depot ;
`pymupdf4llm` et `PyMuPDF` sont en AGPL 3.0, ou licence commerciale. Pour une
conversion ponctuelle en interne, l'AGPL ne pose pas de probleme ; pour un outil
distribue ou integre a un service, c'est le critere qui tranche.

Reproduire la comparaison :

```bash
python3 -m venv /tmp/venv-pdf && /tmp/venv-pdf/bin/pip install pymupdf4llm
/tmp/venv-pdf/bin/python -c "
import pymupdf4llm, pathlib
pathlib.Path('/tmp/pymupdf4llm.md').write_text(
    pymupdf4llm.to_markdown('old/Guide_utilisateur.pdf'), encoding='utf-8')"
grep -c 'kenza_simplifie_combine' /tmp/pymupdf4llm.md   # le test decisif
```

---

## `fix_pptx.py` — corrections de fond de la presentation

```bash
python3 tools/fix_pptx.py "Previsions AdM.pptx" "Previsions AdM - corrige.pptx"
```

Met la presentation en accord avec le code audite : chiffres recalcules, noms de
parametres actuels, nature reelle des bandes d'incertitude, contenu reel des
exports, variantes reellement enregistrees.

Le script travaille en deux temps.

**Phase 1 — substitution de texte.** Le dictionnaire `EDITS` porte, diapositive par
diapositive, chaque texte d'origine et son remplacement, avec un commentaire
expliquant pourquoi. **C'est la trace des decisions editoriales** : quel chiffre
remplace quel chiffre, pourquoi la ligne « Kenza probabiliste » devient « Kenza
simplifie combine », pourquoi la colonne « Stabilite » disparait.

**Phase 2 — modifications structurelles.** Deux choses qu'aucune substitution de
texte ne peut faire :

- **le tableau de la diapo 17, reconstruit en 5 lignes et 7 colonnes.** Il en comptait
  4 et 6. La 5e ligne est `kenza_simplifie_indexe` : la diapo 8 annonce cinq variantes,
  la 17 n'en comparait que quatre, et la manquante est celle qui ne demande pas le prix
  du billet. La 7e colonne est « R2 macro reelle » (voir plus bas). Les 4 lignes de
  548640 EMU sont redistribuees en 5 de 438912 (`5 x 438912 = 4 x 548640`) et la colonne
  des libelles cede 365760 EMU aux six colonnes de chiffres : le bloc occupe exactement
  le meme rectangle, donc ni la note ni le pave « Interpretation » ne bougent.
  La mise en avant de « Kenza indexe » — gras, alignement a gauche, teinte propre —
  disparait : le modele n'est plus le meilleur des cinq des qu'on change d'hypothese macro.
- **une diapositive neuve, « Validation croisee : backtest glissant », inseree en 18.**
  Meme grille, construite depuis la MEME base a 6 colonnes que la 17 — jamais depuis la 17
  remaniee, `build_table` attendant la grille d'origine. Sa derniere colonne rappelle le R2
  a coupure unique, pour que l'ecart entre les deux protocoles se lise sur la meme ligne.

> **Pourquoi une colonne « R2 macro reelle ».** Les previsions ne lisent jamais la macro
> observee : `_future_macro` la projette aux taux supposes, et `rolling_backtest_metrics`
> fait de meme. Les defauts du code sont population +1 %, PIB +3 %, prix +2 % par an, quand
> l'observe sur 2012-2019 vaut +0,73 %, +1,25 % et -0,69 %. A huit ans d'horizon l'ecart
> compose : le classement de la diapo 17 **s'inverse** (Kenza indexe passe de +0,66 a -0,32,
> Kenza simplifie de -0,05 a +0,46). Le backtest glissant, lui, ne perd que 0,06 a 0,09 point
> et garde son ordre. Publier la seule colonne par defaut donnait un classement que
> l'hypothese de scenario suffisait a retourner.

> **Piege a ne pas rejouer.** Une diapositive ajoutee a besoin d'un `rId` libre dans
> `ppt/_rels/presentation.xml.rels`. Les identifiants n'y suivent pas les diapositives :
> apres `rId26` (la 21e et derniere) viennent seize polices embarquees, jusqu'a `rId43`.
> Prendre `rId27` produit un XML valide, une relation dupliquee, et **une diapositive
> blanche** — la relation resout vers la police. Le script calcule donc le premier
> identifiant libre, et fait de meme pour le `p:sldId`.

Le dictionnaire `EDITS` ne porte plus d'entree pour la diapo 17 : son tableau, sa note
et son interpretation sont entierement poses par la phase 2. Deux mecanismes ecrivant
les memes cellules, c'est le mode de defaillance decrit en fin de ce fichier.

Les chiffres du tableau a coupure unique proviennent d'un calage 1990-2011 et d'une
validation 2012-2019 sur `julia/data/sample.csv`. Les regenerer :

```bash
julia --project=julia -e '
include("julia/AirTrafficForecaster.jl"); using .AirTrafficForecaster, DataFrames
AF=AirTrafficForecaster; A=AF.AbstractModel; R=AF.ModelRegistry
d = AF.DataService.coerce_schema!(AF.DataService.normalize_column_names(
      AF.DataService._read_csv_bytes(read("julia/data/sample.csv"))))
tr = filter(r -> r.year <= 2011, d); te = filter(r -> 2011 < r.year <= 2019, d)
for n in R.list_models()
    m = R.get_model(n)(); A.fit!(m, tr)
    f = A.predict(m, nrow(te))
    println(n, "  ", A.calculate_metrics(Float64.(te.actual_passengers),
                                          Float64.(f.predicted_passengers)))
end'
```

Ceux du backtest glissant viennent de `rolling_backtest_metrics`, sur la meme serie
tronquee a 2019 :

```bash
julia --project=julia -e '
include("julia/AirTrafficForecaster.jl"); using .AirTrafficForecaster, DataFrames
AF=AirTrafficForecaster; A=AF.AbstractModel; R=AF.ModelRegistry
d = AF.DataService.coerce_schema!(AF.DataService.normalize_column_names(
      AF.DataService._read_csv_bytes(read("julia/data/sample.csv"))))
d19 = filter(r -> r.year <= 2019, d)
for n in R.list_models()
    println(n, "  ", A.rolling_backtest_metrics(R.get_model(n), d19;
                                                min_train=10, horizon=5))
end'
```

**Un .pptx est un zip de XML**, et le texte d'un paragraphe est reparti sur
plusieurs `<a:r><a:t>`. Le script ecrit donc le texte neuf dans le PREMIER `<a:t>`
du paragraphe et vide les suivants, ce qui preserve la mise en forme du premier run
et la geometrie des tableaux.

---

## `generalize_pptx.py` — depersonnalisation

```bash
python3 tools/generalize_pptx.py "Previsions AdM - corrige.pptx" \
                                 docs/Presentation_methode_Kenza.pptx
```

Retire ce qui lie la presentation a une seance precise : date, lieu, comite,
formules d'adresse a l'auditoire, adresses de courriel. Les noms et affiliations
sont conserves — c'est de la paternite, pas de l'auditoire.

**Le texte visible ne suffit pas.** Une adresse survivait dans un lien `mailto:`,
porte par une Relationship du fichier `.rels` et invisible a la lecture des
diapositives. Le script supprime aussi ces liens. Le depot etant public, c'est le
point a ne pas manquer si l'on rejoue la transformation.

---

## Enchainement complet

```
Previsions AdM.pptx                 (Drive, original intact)
        |  fix_pptx.py
        v
Previsions AdM - corrige.pptx       (Drive, version a presenter)
        |  generalize_pptx.py
        v
docs/Presentation_methode_Kenza.pptx (depot, version publiable)
        |  libreoffice --headless --convert-to pdf
        v
docs/Presentation_methode_Kenza.pdf
```

Une correction de fond se fait dans `fix_pptx.py`, puis se propage aux deux
versions en rejouant la chaine. Ne pas editer les .pptx a la main : le prochain
passage du script ecraserait la modification.
