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

---

## `fix_pptx.py` — corrections de fond de la presentation

```bash
python3 tools/fix_pptx.py "Previsions AdM.pptx" "Previsions AdM - corrige.pptx"
```

Remplace 66 paragraphes sur 10 diapositives pour mettre la presentation en accord
avec le code audite : chiffres recalcules, noms de parametres actuels, nature reelle
des bandes d'incertitude, contenu reel des exports, variantes reellement
enregistrees.

Le dictionnaire `EDITS` porte, diapositive par diapositive, chaque texte d'origine
et son remplacement, avec un commentaire expliquant pourquoi. **C'est la trace des
decisions editoriales** : quel chiffre remplace quel chiffre, pourquoi la ligne
« Kenza probabiliste » devient « Kenza simplifie combine », pourquoi la colonne
« Stabilite » disparait.

Les chiffres proviennent d'un calage 1990-2011 et d'une validation 2012-2019 sur
`julia/data/sample.csv`. Les regenerer :

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
