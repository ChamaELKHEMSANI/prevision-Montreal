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
   "État : 100 % fonctionnel, testé sur données synthétiques et réelles":
     "État : fonctionnel et audité — 253 tests de non-régression, parité vérifiée avec le classeur Excel de référence",
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
   "8 168": "77 264", "6 150": "65 000", "13,5 %": "75,8 %", "0,78": "-55,6", "98 %": "-49,0",
   "5 017": "6 024",  "3 987": "4 671",  "8,7 %":  "5,3 %",  "0,87": "+0,66", "99 %": "1,00 *",
   "Kenza probabiliste": "Kenza simplifié combiné",
   "7 500*": "8 384", "5 800*": "6 574", "12,0 %*": "7,5 %", "0,80": "+0,33", "95 %": "+0,78",
   "* Moyenne sur les simulations bootstrap":
     "* R² in-échantillon = 1 par construction : Kenza indexé inverse la distribution à partir du trafic observé. Seule la colonne hors échantillon mesure un pouvoir prédictif.",
   "Kenza indexé affiche les meilleurs scores sur historique, mais est moins robuste pour des scénarios de prix extrêmes. Kenza complet offre le meilleur compromis performance / robustesse pour des projections long terme. Le choix final dépendra des données disponibles (prix ou non) et des besoins de scénarios.":
     "Calage 1990-2011, validation 2012-2019. Hors échantillon, les variantes indexées dominent nettement et Kenza simplifié diverge. Un score « sur historique » ne classe pas les modèles : Kenza indexé y affiche un R² de 1 sans qu'il mesure quoi que ce soit. Le choix final dépendra des données disponibles (prix ou non) et des besoins de scénarios.",
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

with zipfile.ZipFile(DST, "w", zipfile.ZIP_DEFLATED) as zout:
    for n in zin.namelist():
        zout.writestr(zin.getinfo(n), items[n])

print(f"{applied} paragraphes remplaces")
if missed:
    print("NON TROUVES :")
    for s, k in missed:
        print(f"  diapo {s} : {k[:80]!r}")
