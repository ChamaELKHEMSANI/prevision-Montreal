# -*- coding: utf-8 -*-
"""Corrige le texte de « Prévisions AdM.pptx » pour refléter le code audité.

Un .pptx est un zip de XML. Le texte d'un paragraphe est reparti sur plusieurs
<a:r><a:t>...</a:t></a:r> : on ecrit donc le texte neuf dans le PREMIER <a:t> du
paragraphe et on vide les suivants, ce qui preserve la mise en forme du premier run.
"""
import re, shutil, sys, zipfile
from html import escape, unescape

SRC, DST = sys.argv[1], sys.argv[2]

EDITS = {
 7: {  # « xxx » : un espace reserve jamais rempli, dans une diapositive de fond
   "Développée par Daniel Sallier (Aéroports de Paris, Airbus, etc.). .":
     "Développée par Daniel Sallier (Aéroports de Paris, Airbus).",
   "Prix absolu": "Prix relatif",          # pi(t) = prix / PIB par habitant
   "Prix absolu très bas -> saturation  ·  Prix absolu très élevé -> demande nulle":
     "Prix relatif très bas → saturation  ·  Prix relatif très élevé → demande nulle",
   "K1 : proportion de gens voyageant":
     "K₁ : constante agrégée, multiplicateur de la population (0,8193)",
   "K2: autre coefficient xxx":
     "K₂ : facteur d'échelle du prix normalisé (30)",
 },
 12: {  # la description ne correspondait pas a l'interface
   "Haut: chargement du fichier, aperçu des données, statistiques.":
     "Panneau gauche, de haut en bas : chargement du fichier, période d'entraînement, choix du modèle.",
   "Centre : paramètres du modèle (période, horizon, croissance, options avancées).":
     "Puis l'horizon de prévision et les paramètres du modèle, générés d'après ses métadonnées.",
   "Bas : bouton « Lancer la prévision », onglets résultats.":
     "En bas : « Lancer le modèle » et la barre de statut. Panneau droit : onglets « Modèle unique » et « Comparaison ».",
 },
 8: {  # variantes reellement enregistrees : 5, pas 3 ; et a vaut 1,1572 > 1
   "avec a ∈ [0;1], b > 0, c < 0, d > 0":
     "avec a > 0, b > 0, c < 0, d > 0 ; F* est bornée à [0;1] (a = 1,1572 en référence)",
   "▸  Kenza complet":          "▸  Kenza complet · Kenza simplifié",
   "▸  Kenza simplifié":        "▸  Kenza simplifié combiné · Kenza simplifié indexé",
   "▸  Kenza simplifié indexé": "▸  Kenza indexé      (probabiliste : non disponible)",
 },
 10: {
   "Prix moyen du billet (optionnel)":
     "Prix moyen du billet (requis, sauf variantes indexées)",
 },
 11: {
   "Rapports multi-formats : Excel, CSV, PDF, HTML":
     "Tableau de prévision en CSV ou Excel ; graphique en PDF",
   "Langage : Julia 1.6+ (haute performance scientifique)   ·":
     "Langage : Julia 1.10+ (haute performance scientifique)   ·",
   # « parite verifiee » etait une affirmation en bloc, fausse pour kenza_indexed :
   # run/validate.jl mesure 41,7 % de MAPE contre le classeur sur ce modele — celui-la
   # meme que les diapos 14 et 16 donnent en exemple. Chiffres releves le 4 septembre 2026.
   "État : 100 % fonctionnel, testé sur données synthétiques et réelles":
     "État : fonctionnel et audité — 253 tests de non-régression ; écart au classeur Excel de 3 à 11 % selon la variante, sauf Kenza indexé (41,7 %, non expliqué à ce jour)",
 },
 13: {  # noms de parametres : la loi (K1, K2) et la courbe (c, d) ne se confondent plus
   "full_penetration : Taux maximal de pénétration du transport aérien dans la population.":
     "kenza_k1 : constante agrégée K1 de la loi, multiplicateur de la population.",
   "full_price_scale : Facteur de mise à l'échelle du rapport prix du billet / PIB par habitant.":
     "kenza_k2 : seuil de revenu normalisé K2, échelle du rapport prix du billet / PIB par habitant.",
   "k1 : Coefficient de sensibilité de la demande au prix relatif.":
     "curve_c : coefficient c de la courbe logistique (niveau global).",
   "k2 (si présent) : Coefficient déterminant la forme et la pente de la courbe de pénétration.":
     "curve_d : exposant d du prix normalisé dans la courbe logistique.",
   # la capture, elle, ne peut pas etre refaite sans serveur graphique : elle montre
   # encore full_penetration, full_price_scale, k1 et k2. On le dit plutot que de
   # laisser la contradiction sur la meme diapositive.
   "Paramètres modifiables":
     "Paramètres modifiables — noms actuels ; la capture ci-contre montre les anciens",
 },
 14: {
   "Métrique de performance": "Métriques recalculées — la capture ci-contre date de la version antérieure",
   "RMSE : 8 168 passagers.": "RMSE : 6 024 (hors échantillon, 2012-2019).",
   "MAE : 6 150 passagers.":  "MAE : 4 671.",
   "MAPE : 13,5 %.":          "MAPE : 5,3 %.",
   "R² : 0,7804.":            "R² hors échantillon : 0,656.",
   "Graphique : historique (points réels) et prévision (courbe) avec intervalle de confiance.":
     "Graphique : historique (points) et prévision (courbe), encadrée d'une bande ±20 % — forfait indicatif, non statistique.",
 },
 15: {
   "Méthode de calcul des intervalles": "Nature de la bande affichée",
   "Exemple pour 2030 : prévision centrale 105 320 passagers, intervalle [84 256,126 384].":
     "Exemple 2030 : centrale 96 982, bande [77 585 ; 116 378] — soit exactement ±20 %, largeur fixée d'avance.",
   "Discussion : scénarios « bas » et":
     "La bande ne mesure pas l'incertitude : sa largeur ne dépend ni des données ni de la qualité de l'ajustement. Scénarios « bas » et",
 },
 16: {
   "Jeu de test : sample.csv  Modèle : Kenza simplifié":
     "Jeu d'exemple : sample.csv (série synthétique)   ·   Modèle : Kenza indexé",
   "8 168": "6 024", "6 150": "4 671", "13,5 %": "5,3 %", "0,78": "0,66",
   "R²": "R² hors échantillon",
   "• Calibration sur 70 % de l'historique (1990-2015) -> validation stable sur 2016-2023.":
     "• Calage 1990-2011, validation 2012-2019 : huit années jamais vues par le modèle.",
   "• Le modèle capture ~78 % de la variance historique.":
     "• 5,3 % d'erreur relative moyenne hors échantillon. Le R² dans l'échantillon vaut 1 par construction pour ce modèle : il ne mesure rien.",
   "• Prévision 2049 (scénario central) : ~136 000 000  passagers (+48 % vs 2019).":
     "• Projection 2049, hypothèses macro par défaut : +79 % vs 2019.",
   "• Point d'attention : sous-estimation des chocs (ex. COVID) -> importance des scénarios alternatifs.• Remarque : Les valeurs actuelles n’incluent pas les transferts (ex: avec Toronto).":
     "• Fenêtre choisie hors COVID. En incluant 2020-2023, le R² hors échantillon de toutes les variantes devient négatif : le choc n'est pas prévisible à partir de la population et du revenu.\n• Les valeurs n'incluent pas les transferts (ex. avec Toronto).",
 },
 # La diapositive 17 n'a plus d'entree ici : son tableau est entierement reconstruit
 # par la PHASE 2, qui change aussi sa geometrie (5 lignes, 7 colonnes). Trace des
 # arbitrages qui etaient portes a cet endroit, et que la phase 2 applique toujours :
 #   - colonne « Stabilite » -> « R2 in-ech. » : elle ne correspondait a aucun calcul ;
 #   - colonne « R2 » -> « R2 hors ech. » : le score publie etait in-echantillon ;
 #   - ligne « Kenza probabiliste » -> « Kenza simplifie combine » : le modele
 #     probabiliste n'est pas enregistre dans ModelRegistry ;
 #   - note « * Moyenne sur les simulations bootstrap » -> note sur le R2 = 1 par
 #     construction de Kenza indexe ;
 #   - tous les chiffres, recalcules sur julia/data/sample.csv.
}

def para_text(block):
    return unescape("".join(re.findall(r"<a:t>(.*?)</a:t>", block, re.S))).strip()

shutil.copy(SRC, DST)
zin = zipfile.ZipFile(SRC)
items = {n: zin.read(n) for n in zin.namelist()}
applied, missed = 0, []

for slide, mapping in EDITS.items():
    key = f"ppt/slides/slide{slide}.xml"
    xml = items[key].decode("utf-8")
    seen = set()

    def repl(m):
        global applied
        block = m.group(0)
        txt = para_text(block)
        if txt not in mapping or txt in seen:
            return block
        seen.add(txt)
        new = escape(mapping[txt], quote=False)
        first = [True]
        def one(rm):
            if first[0]:
                first[0] = False
                return f"<a:t>{new}</a:t>"
            return "<a:t></a:t>"
        applied += 1
        return re.sub(r"<a:t>.*?</a:t>", one, block, flags=re.S)

    xml = re.sub(r"<a:p>.*?</a:p>", repl, xml, flags=re.S)
    items[key] = xml.encode("utf-8")
    for k in mapping:
        if k not in seen:
            missed.append((slide, k))


# ---------------------------------------------------------------------------
# PHASE 2 - modifications structurelles
#
# La substitution de texte de la phase 1 ne peut pas tout faire. Cette phase :
#   - rejoue la correction de chevauchement de la diapo 5, faite a la main en aval ;
#   - reconstruit entierement le tableau de la diapo 17, passe de 4 lignes et
#     6 colonnes a 5 lignes et 7 colonnes ;
#   - clone le resultat en une diapositive « backtest glissant », inseree en 18.
#
# Le tableau de la diapo 17 est donc DECRIT ICI, et non plus par EDITS[17] : deux
# mecanismes ecrivant les memes cellules, c'est precisement le mode de defaillance
# que tools/README.md met en garde. L'etat d'origine du tableau, remplace par la
# premiere version de ce script, reste consultable dans l'historique git.
#
# Chiffres releves le 4 septembre 2026 sur julia/data/sample.csv ; commandes de
# regeneration dans tools/README.md.
# ---------------------------------------------------------------------------

SP_RE = re.compile(r"<p:sp>.*?</p:sp>", re.S)

HEAD_SP = 3             # index de la 1re cellule d'en-tete
HEAD_Y, HEAD_CY = 1188720, 365760
ROW_TOP = 1600200
# Les 4 lignes de 548640 EMU sont redistribuees en 5 de 438912 : 5 x 438912 = 4 x 548640.
# Le bloc de tableau occupe donc le meme rectangle qu'avant, et ni la note de bas de
# tableau ni le pave « Interpretation » n'ont a bouger.
ROW_PITCH = (4 * 548640) // 5
# Sept colonnes au lieu de six : la colonne des libelles cede 365760 EMU, et les six
# colonnes de chiffres se partagent le reste a egalite. Total inchange, 11247120.
COL_X = [457200, 3017520, 4465320, 5913120, 7360920, 8808720, 10256520]
COL_W = [2560320, 1447800, 1447800, 1447800, 1447800, 1447800, 1447800]
NEW_COL = 5             # rang d'insertion : juste avant la colonne in-echantillon
BAND_TINT = "E5EFF3"    # zebrage : lignes impaires teintees, paires blanches

# Diapo 17 - calage unique 1990-2011, validation 2012-2019.
# « R2 hors ech. » projette la macro aux hypotheses par defaut du code (population
# +1 %, PIB +3 %, prix +2 % par an) ; « R2 macro reelle » rejoue la meme prevision
# avec la macro observee sur 2012-2019 (+0,73 %, +1,25 %, -0,69 %). Le classement
# s'inverse d'une colonne a l'autre : c'est le fait marquant de la diapositive.
SPLIT_HEADERS = ("Modèle", "RMSE", "MAE", "MAPE", "R² hors éch.", "R² macro réelle", "R² in-éch.")
SPLIT_ROWS = [
    ("Kenza complet",           "13 835", "11 165", "12,8 %", "-0,82", "-0,78", "-0,14"),
    ("Kenza simplifié",         "10 498",  "8 356",  "9,6 %", "-0,05", "+0,46", "+0,33"),
    ("Kenza indexé",             "6 024",  "4 671",  "5,3 %", "+0,66", "-0,32", "1,00 *"),
    ("Kenza simplifié combiné",  "8 384",  "6 574",  "7,5 %", "+0,33", "+0,56", "+0,78"),
    ("Kenza simplifié indexé",   "8 540",  "6 660",  "7,6 %", "+0,31", "-0,55", "+0,88"),
]
SPLIT_NOTE = ("* R² in-échantillon = 1 par construction : Kenza indexé inverse la distribution à partir "
              "du trafic observé. « R² hors éch. » projette la macro aux hypothèses par défaut du code "
              "(population +1 %, PIB +3 %, prix +2 % par an) ; « R² macro réelle » rejoue la même "
              "prévision avec la macro observée sur 2012-2019 (+0,73 %, +1,25 %, −0,69 %).")
SPLIT_TEXT = ("Calage 1990-2011, validation 2012-2019. Les deux colonnes hors échantillon rejouent la "
              "même prévision sous des hypothèses macro différentes, et le classement s'inverse : Kenza "
              "indexé passe de +0,66 à −0,32, Kenza simplifié de −0,05 à +0,46. À huit ans d'horizon, "
              "l'écart entre un PIB supposé à +3 % par an et le +1,25 % observé pèse plus lourd que le "
              "choix du modèle. Aucune de ces colonnes ne classe donc les variantes — la diapositive "
              "suivante s'y emploie, à horizon plus court.")

# Diapo 18 - backtest glissant : calage initial de 10 ans, puis toutes les coupures
# jusqu'en 2019, horizon 5 ans. Meme grille, clonee de la 17.
ROLLING_HEADERS = ("Modèle", "RMSE", "MAE", "MAPE", "R² glissant", "R² macro réelle", "R² 1 coupure")
ROLLING_ROWS = [
    ("Kenza complet",           "6 932", "4 806", "6,3 %", "+0,60", "+0,54", "-0,82"),
    ("Kenza simplifié",         "5 994", "4 351", "5,7 %", "+0,70", "+0,62", "-0,05"),
    ("Kenza indexé",            "5 330", "4 115", "5,5 %", "+0,77", "+0,68", "+0,66"),
    ("Kenza simplifié combiné", "6 086", "4 742", "6,4 %", "+0,69", "+0,67", "+0,33"),
    ("Kenza simplifié indexé",  "5 555", "4 150", "5,5 %", "+0,75", "+0,66", "+0,31"),
]
ROLLING_TITLE = "Validation croisée : backtest glissant"
ROLLING_NOTE = ("Backtest glissant : calage initial de 10 ans, puis toutes les coupures jusqu'en 2019, "
                "horizon 5 ans — environ 19 fenêtres. « R² macro réelle » rejoue le même backtest avec "
                "la macro observée sur 1990-2019 (population +0,67 %, PIB +1,42 %, prix +0,85 % par an). "
                "La dernière colonne reprend la diapositive précédente.")
ROLLING_TEXT = ("En moyennant toutes les coupures possibles à horizon 5 ans, les cinq variantes expliquent "
                "60 à 77 % de la variance hors échantillon, pour 5,5 à 6,4 % d'erreur relative. Ce "
                "classement-ci résiste à l'hypothèse macro : il perd 0,06 à 0,09 point avec la macro "
                "observée, sans changer d'ordre, là où celui de la diapositive précédente s'inversait.\n"
                "Réserve : le trafic 2012-2019 croît de 5,0 % par an quand la population avance de 0,7 % "
                "et le PIB par habitant de 1,25 %. YUL surperforme donc les prévisions, et l'écart s'ouvre "
                "d'année en année. Le combler demande des variables explicatives supplémentaires — par "
                "exemple des transferts de demande entre aéroports — plutôt qu'un recalibrage.")
# La reserve et la phrase sur la robustesse ajoutent deux lignes : le pave et sa zone de
# texte s'allongent d'autant. Le bas du pave passe a 6252160 EMU, le numero de page etant
# a 6333134 : il n'y a pas de marge pour une ligne de plus.
ROLLING_BOX_GROWTH = 400000

# Index des formes une fois le tableau reconstruit : 0-1 titraille, 2 bandeau d'en-tete,
# 3-9 les sept cellules d'en-tete, 10-49 les cinq lignes (bandeau + sept cellules),
# 50 la note, 51-53 le pave d'interpretation, 54 le numero de page (un champ, qui se met
# a jour tout seul).
I_NOTE, I_BOX, I_TEXT = 50, 51, 53


def set_sp_text(sp, text):
    """Ecrit `text` dans le premier <a:t> de la forme et vide les suivants."""
    new = escape(text, quote=False)
    first = [True]
    def one(m):
        if first[0]:
            first[0] = False
            return f"<a:t>{new}</a:t>"
        return "<a:t></a:t>"
    return re.sub(r"<a:t>.*?</a:t>", one, sp, flags=re.S)


def geom(sp, x, y, cx, cy):
    sp = re.sub(r'<a:off x="-?\d+" y="-?\d+"/>', f'<a:off x="{x}" y="{y}"/>', sp, count=1)
    return re.sub(r'<a:ext cx="\d+" cy="\d+"/>', f'<a:ext cx="{cx}" cy="{cy}"/>', sp, count=1)


def grow_cy(sp, delta):
    return re.sub(r'(<a:ext cx="\d+" cy=")(\d+)(")',
                  lambda m: m.group(1) + str(int(m.group(2)) + delta) + m.group(3), sp, count=1)


def build_table(xml, headers, rows):
    """Reconstruit le tableau : 7 colonnes, 5 lignes, geometrie et textes poses."""
    blocks = SP_RE.findall(xml)
    head = blocks[HEAD_SP:HEAD_SP + 6]
    src = [blocks[HEAD_SP + 6 + i * 7: HEAD_SP + 6 + (i + 1) * 7] for i in range(4)]
    if len(head) != 6 or any(len(r) != 7 for r in src):
        raise SystemExit("geometrie de tableau inattendue sur la diapo 17")

    counter = [max(int(v) for v in re.findall(r'<p:cNvPr id="(\d+)"', xml)) + 1]
    def clone(sp):
        out = re.sub(r'<p:cNvPr id="\d+"', f'<p:cNvPr id="{counter[0]}"', sp, count=1)
        counter[0] += 1
        return out

    # 5e ligne : clonee de la 4e, bandeau blanc et libelle sans emphase. Le zebrage
    # reprend a la teinte.
    src.append([clone(sp) for sp in src[3]])
    src[4][0] = src[4][0].replace('<a:srgbClr val="FFFFFF"/>', f'<a:srgbClr val="{BAND_TINT}"/>', 1)

    # 7e colonne, inseree avant la colonne in-echantillon.
    head = head[:NEW_COL] + [clone(head[NEW_COL - 1])] + head[NEW_COL:]
    src = [[r[0]] + r[1:1 + NEW_COL] + [clone(r[NEW_COL])] + r[1 + NEW_COL:] for r in src]

    # La 3e ligne mettait « Kenza indexé » en avant — gras, alignement a gauche, teinte
    # propre. Le modele n'est plus le meilleur des cinq des qu'on change d'hypothese
    # macro : la ligne redevient une ligne comme les autres.
    src[2][0] = src[2][0].replace('<a:srgbClr val="EDF4F7"/>', f'<a:srgbClr val="{BAND_TINT}"/>', 1)
    src[2][1] = src[2][1].replace('<a:rPr b="1"', '<a:rPr b="0"', 1).replace('algn="l"', 'algn="ctr"', 1)

    out = [geom(set_sp_text(sp, t), COL_X[k], HEAD_Y, COL_W[k], HEAD_CY)
           for k, (sp, t) in enumerate(zip(head, headers))]
    for i, (row, values) in enumerate(zip(src, rows)):
        y = ROW_TOP + i * ROW_PITCH
        out.append(geom(row[0], COL_X[0], y, sum(COL_W), ROW_PITCH))
        out += [geom(set_sp_text(sp, v), COL_X[k], y, COL_W[k], ROW_PITCH)
                for k, (sp, v) in enumerate(zip(row[1:], values))]

    old = "".join(blocks[HEAD_SP:HEAD_SP + 6 + 4 * 7])
    if xml.count(old) != 1:
        raise SystemExit("les formes du tableau ne sont pas contigues : geometrie inattendue")
    return xml.replace(old, "".join(out))


def set_by_index(xml, edits, grown=()):
    """Retexture et/ou agrandit des formes reperees par leur rang. Une passe par forme."""
    blocks = SP_RE.findall(xml)
    for i in sorted(set(edits) | set(grown)):
        sp = blocks[i]
        new_sp = set_sp_text(sp, edits[i]) if i in edits else sp
        if i in grown:
            new_sp = grow_cy(new_sp, ROLLING_BOX_GROWTH)
        xml = xml.replace(sp, new_sp, 1)
    return xml


# Correction de chevauchement reprise du commit cb4dc2a (« Fix a minor overlap issue »),
# faite directement dans le .pptx publie : l'etiquette « Envie de voyager » de la diapo 5
# debordait de sa zone. Elle est elargie de 2076600 a 2267536 EMU et recalee a gauche pour
# rester centree. Rejouee ici parce que le passage suivant du script l'aurait effacee —
# c'est exactement le piege que signale tools/README.md.
OVERLAP_FIXES = {5: {"Envie de voyager": (1165007, 2842025, 2267536, 300300)}}

for slide, boxes in OVERLAP_FIXES.items():
    key = f"ppt/slides/slide{slide}.xml"
    xml = items[key].decode("utf-8")
    for label, (x, y, cx, cy) in boxes.items():
        found = [sp for sp in SP_RE.findall(xml) if para_text(sp) == label]
        if len(found) != 1:
            raise SystemExit(f"diapo {slide} : {label!r} attendu une fois, trouve {len(found)}")
        xml = xml.replace(found[0], geom(found[0], x, y, cx, cy), 1)
    items[key] = xml.encode("utf-8")

SLIDE17 = "ppt/slides/slide17.xml"
base17 = items[SLIDE17].decode("utf-8")          # grille d'origine : 4 lignes, 6 colonnes

xml17 = set_by_index(build_table(base17, SPLIT_HEADERS, SPLIT_ROWS),
                     {I_NOTE: SPLIT_NOTE, I_TEXT: SPLIT_TEXT})
items[SLIDE17] = xml17.encode("utf-8")

# La diapositive du backtest repart de la MEME base, jamais de la 17 remaniee : build_table
# attend la grille d'origine, et l'enchainer sur sa propre sortie decalait tous les index.
rolling = set_by_index(build_table(base17, ROLLING_HEADERS, ROLLING_ROWS),
                       {1: ROLLING_TITLE, I_NOTE: ROLLING_NOTE, I_TEXT: ROLLING_TEXT},
                       grown=(I_BOX, I_TEXT))

NEW_SLIDE = "ppt/slides/slide22.xml"        # numero de PARTIE libre : l'ordre d'affichage
                                            # est donne par sldIdLst, pas par le nom de fichier
items[NEW_SLIDE] = rolling.encode("utf-8")

# Les rId ne s'arretent pas aux diapositives : rId27 a rId42 portent les polices
# embarquees. Reutiliser un identifiant deja pris ne casse rien a la lecture du XML,
# mais la relation resolvait vers une police et la diapositive sortait BLANCHE. On
# prend donc le premier libre, des deux cotes.
_rels_src = items["ppt/_rels/presentation.xml.rels"].decode("utf-8")
NEW_RID = "rId%d" % (max(int(v) for v in re.findall(r'Id="rId(\d+)"', _rels_src)) + 1)
_pres_src = items["ppt/presentation.xml"].decode("utf-8")
NEW_SLD_ID = max(int(v) for v in re.findall(r'<p:sldId id="(\d+)"', _pres_src)) + 1

# Pas de notesSlide : la diapositive neuve n'a pas de commentaire d'orateur.
items["ppt/slides/_rels/slide22.xml.rels"] = re.sub(
    r'<Relationship Id="rId2"[^>]*notesSlide[^>]*/>', "",
    items["ppt/slides/_rels/slide17.xml.rels"].decode("utf-8")).encode("utf-8")

ct = items["[Content_Types].xml"].decode("utf-8")
items["[Content_Types].xml"] = ct.replace(
    "</Types>",
    '<Override ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"'
    ' PartName="/ppt/slides/slide22.xml"/></Types>').encode("utf-8")

items["ppt/_rels/presentation.xml.rels"] = _rels_src.replace(
    "</Relationships>",
    f'<Relationship Id="{NEW_RID}" Type="http://schemas.openxmlformats.org/officeDocument/2006/'
    f'relationships/slide" Target="slides/slide22.xml"/></Relationships>').encode("utf-8")

after17 = '<p:sldId id="272" r:id="rId22"/>'              # la diapo 17 dans l'ordre d'affichage
if after17 not in _pres_src:
    raise SystemExit("diapo 17 introuvable dans sldIdLst : la presentation a change")
items["ppt/presentation.xml"] = _pres_src.replace(
    after17, after17 + f'<p:sldId id="{NEW_SLD_ID}" r:id="{NEW_RID}"/>').encode("utf-8")

print("diapo 17 : tableau reconstruit en 5 lignes x 7 colonnes ; « backtest glissant » inseree en 18")

with zipfile.ZipFile(DST, "w", zipfile.ZIP_DEFLATED) as zout:
    for n in zin.namelist():
        zout.writestr(zin.getinfo(n), items[n])
    for n in items.keys() - set(zin.namelist()):          # parties ajoutees par la phase 2
        zout.writestr(n, items[n])

print(f"{applied} paragraphes remplaces")
if missed:
    print("NON TROUVES :")
    for s, k in missed:
        print(f"  diapo {s} : {k[:80]!r}")
