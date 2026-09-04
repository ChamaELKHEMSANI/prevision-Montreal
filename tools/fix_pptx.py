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
 17: {  # la colonne « Stabilité » ne correspondait a aucun calcul ; le modele
        # probabiliste n'est pas enregistre. Meme geometrie, contenu mesure.
   "Stabilité": "R² in-éch.",
   "R²": "R² hors éch.",
   "Kenza complet": "Kenza complet",
   "7 112": "13 835", "5 324": "11 165", "11,2 %": "12,8 %", "0,82": "-0,82", "97 %": "-0,14",
   # Ligne recalculee le 3 septembre 2026 : les valeurs par defaut C1 et C2 de
   # kenza_simplifie sont passees des amorces -0,5 / 0,5 aux coefficients calibres du
   # classeur Excel. Le modele ne diverge plus (R2 hors echantillon -55,6 -> -0,05).
   "8 168": "10 498", "6 150": "8 356", "13,5 %": "9,6 %", "0,78": "-0,05", "98 %": "+0,33",
   "5 017": "6 024",  "3 987": "4 671",  "8,7 %":  "5,3 %",  "0,87": "+0,66", "99 %": "1,00 *",
   "Kenza probabiliste": "Kenza simplifié combiné",
   "7 500*": "8 384", "5 800*": "6 574", "12,0 %*": "7,5 %", "0,80": "+0,33", "95 %": "+0,78",
   "* Moyenne sur les simulations bootstrap":
     "* R² in-échantillon = 1 par construction : Kenza indexé inverse la distribution à partir du trafic observé. Seule la colonne hors échantillon mesure un pouvoir prédictif.",
   "Kenza indexé affiche les meilleurs scores sur historique, mais est moins robuste pour des scénarios de prix extrêmes. Kenza complet offre le meilleur compromis performance / robustesse pour des projections long terme. Le choix final dépendra des données disponibles (prix ou non) et des besoins de scénarios.":
     "Calage 1990-2011, validation 2012-2019. Hors échantillon, les variantes indexées dominent nettement ; Kenza simplifié, sur les coefficients calibrés du classeur Excel, ne fait pas mieux que la moyenne (R² ≈ 0). Un score « sur historique » ne classe pas les modèles : Kenza indexé y affiche un R² de 1 sans qu'il mesure quoi que ce soit. Le choix final dépendra des données disponibles (prix ou non) et des besoins de scénarios.",
 },
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
# La substitution de texte de la phase 1 ne peut pas tout faire : il manquait une
# LIGNE de tableau (la diapo 8 annonce cinq variantes, la 17 n'en comparait que
# quatre) et une DIAPOSITIVE entiere (le backtest glissant, seule mesure hors
# echantillon robuste du projet). Les deux sont construites a partir de la
# geometrie existante de la diapo 17, jamais saisies a la main.
#
# Chiffres releves le 4 septembre 2026 sur julia/data/sample.csv. Pour les
# regenerer, voir tools/README.md.
# ---------------------------------------------------------------------------

SP_RE = re.compile(r"<p:sp>.*?</p:sp>", re.S)

FIRST_ROW_SP = 9        # index de la 1re forme de la 1re ligne du tableau
SP_PER_ROW = 7          # bandeau de fond + libelle + 5 valeurs
ROW_TOP = 1600200
# Les 4 lignes de 548640 sont redistribuees en 5 de 438912 : 5 x 438912 = 4 x 548640.
# Le bloc de tableau occupe donc exactement le meme rectangle qu'avant, et ni la note
# de bas de tableau ni le pave « Interpretation » n'ont a bouger.
ROW_PITCH = (4 * 548640) // 5
BAND_TINT = "E5EFF3"    # zebrage : lignes impaires teintees, paires blanches

# 5e ligne de la diapo 17 : meme protocole que les quatre autres (calage unique
# 1990-2011, validation 2012-2019). C'est la variante qui ne demande pas le prix
# du billet, l'argument de la diapo 10 ; l'omettre laissait la meilleure des deux
# variantes indexees hors du tableau.
SPLIT_ROW_5 = ("Kenza simplifié indexé", "8 540", "6 660", "7,6 %", "+0,31", "+0,88")

# Diapositive neuve : backtest glissant, calage initial de 10 ans puis toutes les
# coupures jusqu'en 2019, horizon 5 ans. La derniere colonne rappelle la coupure
# unique de la diapo 17 pour que l'ecart entre les deux protocoles soit lisible sur
# la meme ligne, au lieu d'obliger l'auditoire a tourner la page.
ROLLING_HEADERS = ("Modèle", "RMSE", "MAE", "MAPE", "R² glissant", "R² 1 coupure")
ROLLING_ROWS = [
    ("Kenza complet",           "6 932", "4 806", "6,3 %", "+0,60", "-0,82"),
    ("Kenza simplifié",         "5 994", "4 351", "5,7 %", "+0,70", "-0,05"),
    ("Kenza indexé",            "5 330", "4 115", "5,5 %", "+0,77", "+0,66"),
    ("Kenza simplifié combiné", "6 086", "4 742", "6,4 %", "+0,69", "+0,33"),
    ("Kenza simplifié indexé",  "5 555", "4 150", "5,5 %", "+0,75", "+0,31"),
]
ROLLING_TITLE = "Validation croisée : backtest glissant"
ROLLING_NOTE = ("Backtest glissant : calage initial de 10 ans, puis toutes les coupures jusqu'en 2019, "
                "horizon 5 ans — environ 19 fenêtres. RMSE, MAE et MAPE sont ceux du glissant ; la dernière "
                "colonne reprend la diapositive précédente (calage unique 1990-2011, horizon jusqu'à 8 ans).")
ROLLING_TEXT = ("Le classement de la diapositive précédente tient à une seule coupure : un calage 1990-2011, "
                "puis huit années prédites d'affilée. En moyennant toutes les coupures possibles à horizon "
                "5 ans, les cinq variantes expliquent 60 à 77 % de la variance hors échantillon, pour 5,5 à "
                "6,4 % d'erreur relative moyenne. La seconde mesure est plus robuste, mais porte sur un "
                "horizon plus court.\n"
                "Réserve : sur ce jeu synthétique, le trafic 2012-2019 croît de 5,0 % par an quand la "
                "population avance de 0,7 % et le PIB par habitant de 1,25 %. Aucun modèle fondé sur ces "
                "moteurs ne peut suivre — ces R² mesurent donc d'abord l'écart entre une trajectoire "
                "fabriquée et ses propres régresseurs.")

# La reserve ajoute deux lignes : le pave et sa zone de texte s'allongent d'autant. Le
# bas du pave passe a 6252160 EMU, le numero de page etant a 6333134 : ca tient, mais il
# n'y a pas de marge pour une troisieme ligne.
ROLLING_BOX_GROWTH = 400000


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


def place(sp, y, cy):
    """Repositionne verticalement une forme et fixe sa hauteur."""
    sp = re.sub(r'(<a:off x="-?\d+" y=")-?\d+(")', lambda m: m.group(1) + str(y) + m.group(2),
                sp, count=1)
    return re.sub(r'(<a:ext cx="\d+" cy=")\d+(")', lambda m: m.group(1) + str(cy) + m.group(2),
                  sp, count=1)


def rebuild_table(xml, extra_row=None, values=None):
    """Redistribue les lignes du tableau, en ajoutant eventuellement `extra_row`.

    `values`, s'il est fourni, reecrit le contenu des lignes une a une : c'est ce qui
    permet de fabriquer la diapositive du backtest a partir de la geometrie de la 17.
    """
    blocks = SP_RE.findall(xml)
    rows = [blocks[FIRST_ROW_SP + i * SP_PER_ROW: FIRST_ROW_SP + (i + 1) * SP_PER_ROW]
            for i in range(len(blocks[FIRST_ROW_SP:]) // SP_PER_ROW)]
    rows = [r for r in rows if len(r) == SP_PER_ROW and '<a:off x="457200"' in r[0]]
    rows = rows[:4] if extra_row else rows[:5]

    if extra_row:
        next_id = max(int(v) for v in re.findall(r'<p:cNvPr id="(\d+)"', xml)) + 1
        clone = []
        for j, sp in enumerate(rows[-1]):                  # 4e ligne : bandeau blanc, style neutre
            sp = re.sub(r'<p:cNvPr id="\d+"', f'<p:cNvPr id="{next_id}"', sp, count=1)
            next_id += 1
            if j == 0:                                     # le zebrage reprend a la teinte
                sp = sp.replace('<a:srgbClr val="FFFFFF"/>', f'<a:srgbClr val="{BAND_TINT}"/>', 1)
            else:
                sp = set_sp_text(sp, extra_row[j - 1])
            clone.append(sp)
        rows.append(clone)

    if values:
        rows = [[r[0]] + [set_sp_text(sp, v) for sp, v in zip(r[1:], vals)]
                for r, vals in zip(rows, values)]

    old = "".join(sp for r in ([blocks[FIRST_ROW_SP + i * SP_PER_ROW: FIRST_ROW_SP + (i + 1) * SP_PER_ROW]
                                for i in range(4 if extra_row else 5)]) for sp in r)
    new = "".join(place(sp, ROW_TOP + k * ROW_PITCH, ROW_PITCH)
                  for k, r in enumerate(rows) for sp in r)
    if xml.count(old) != 1:
        raise SystemExit("les formes du tableau ne sont pas contigues : geometrie inattendue")
    return xml.replace(old, new)


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
        moved = re.sub(r'<a:off x="-?\d+" y="-?\d+"/>', f'<a:off x="{x}" y="{y}"/>',
                       found[0], count=1)
        moved = re.sub(r'<a:ext cx="\d+" cy="\d+"/>', f'<a:ext cx="{cx}" cy="{cy}"/>',
                       moved, count=1)
        xml = xml.replace(found[0], moved, 1)
    items[key] = xml.encode("utf-8")

SLIDE17 = "ppt/slides/slide17.xml"
xml17 = rebuild_table(items[SLIDE17].decode("utf-8"), extra_row=SPLIT_ROW_5)
items[SLIDE17] = xml17.encode("utf-8")

# La diapositive du backtest reprend la 17 remaniee : meme grille, meme zebrage, meme
# pave d'interpretation. Seuls le titre, deux en-tetes, les valeurs et les deux textes
# changent. Les index sont ceux de la 17 a cinq lignes : 0-1 titraille, 2-8 en-tete,
# 9-43 les cinq lignes, 44 la note, 45-47 le pave, 48 le numero de page (un champ, qui
# se met a jour tout seul).
rolling = rebuild_table(xml17, values=[list(r) for r in ROLLING_ROWS])
blocks = SP_RE.findall(rolling)
edits = {1: ROLLING_TITLE, 7: ROLLING_HEADERS[4], 8: ROLLING_HEADERS[5],
         44: ROLLING_NOTE, 47: ROLLING_TEXT}
GROWN = (45, 47)                                     # le pave arrondi, puis sa zone de texte

def grow(sp):
    return re.sub(r'(<a:ext cx="\d+" cy=")(\d+)(")',
                  lambda m: m.group(1) + str(int(m.group(2)) + ROLLING_BOX_GROWTH) + m.group(3),
                  sp, count=1)

# Une seule passe par forme : la forme 47 est a la fois retexturee et agrandie, et la
# remplacer deux fois de suite echouerait au second passage, sa chaine ayant change.
for i in sorted(set(edits) | set(GROWN)):
    sp = blocks[i]
    new_sp = set_sp_text(sp, edits[i]) if i in edits else sp
    if i in GROWN:
        new_sp = grow(new_sp)
    rolling = rolling.replace(sp, new_sp, 1)

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

rels = items["ppt/_rels/presentation.xml.rels"].decode("utf-8")
items["ppt/_rels/presentation.xml.rels"] = rels.replace(
    "</Relationships>",
    f'<Relationship Id="{NEW_RID}" Type="http://schemas.openxmlformats.org/officeDocument/2006/'
    f'relationships/slide" Target="slides/slide22.xml"/></Relationships>').encode("utf-8")

pres = items["ppt/presentation.xml"].decode("utf-8")
after17 = '<p:sldId id="272" r:id="rId22"/>'              # la diapo 17 dans l'ordre d'affichage
if after17 not in pres:
    raise SystemExit("diapo 17 introuvable dans sldIdLst : la presentation a change")
items["ppt/presentation.xml"] = pres.replace(
    after17, after17 + f'<p:sldId id="{NEW_SLD_ID}" r:id="{NEW_RID}"/>').encode("utf-8")

print("diapo 17 : 5e variante ajoutee ; diapositive « backtest glissant » inseree en 18")

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
