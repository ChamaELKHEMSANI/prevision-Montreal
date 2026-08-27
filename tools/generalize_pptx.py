# -*- coding: utf-8 -*-
"""Retire de la presentation ce qui la lie a une seance precise.

Date, auditoire et adresses de courriel. Le depot est PUBLIC : les trois adresses
de la derniere diapositive y seraient indexees, dont deux appartiennent a des
personnes qui n'ont pas ete consultees. Les noms et affiliations sont conserves —
c'est de la paternite, pas de l'auditoire.
"""
import re, sys, zipfile
from html import escape, unescape

SRC, DST = sys.argv[1], sys.argv[2]

EDITS = {
 1: {
   "COMITÉ AÉROPORT": "MÉTHODE KENZA",
   # la ligne portait le lieu et la date de la seance ; elle n'a pas d'equivalent neutre
   "Aéroports de Montréal · 05 août 2026": "",
 },
 2: {
   "Déroulement de la réunion": "Plan de la présentation",
   "Avantages pour Montréal":   "Avantages de la méthode",
 },
 3: {
   "Objectifs de la réunion": "Objectifs de la présentation",
   "A valider avec vous":     "À valider avec l'exploitant",
 },
 4: {
   "AdM doit planifier ses infrastructures (terminal, pistes, parkings), ses financements et ses stratégies commerciales à un horizon de 20 à 30 ans.":
     "Un exploitant aéroportuaire doit planifier ses infrastructures (terminal, pistes, parkings), ses financements et ses stratégies commerciales à un horizon de 20 à 30 ans.",
 },
 9:  {"Pourquoi Kenza pour AdM": "Pourquoi la méthode Kenza"},
 18: {"Données demandées à Montréal": "Données à réunir"},
 19: {
   "Intrants nécessaires à AdM": "Intrants nécessaires",
   "Nous sollicitons l'approbation et les orientations suivantes :":
     "Approbations et orientations à obtenir :",
   "Validation du périmètre : le modèle Kenza est adapté aux besoins de l'aéroport.":
     "Validation du périmètre : le modèle Kenza est adapté aux besoins de l'exploitant.",
 },
 20: {
   "Prévision du trafic aérien à long terme — Aéroports de Montréal":
     "Prévision du trafic aérien à long terme",
 },
 21: {
   "Merci pour votre attention": "Merci de votre attention",
   "Contacts :": "Auteurs :",
   "chama.el-khemsani@alumni.enac.fr": "Chama EL KHEMSANI — ENAC",
   "bastin@iro.umontreal.ca":          "Fabian BASTIN — Université de Montréal",
   "sallier.daniel@gmail.com":         "Daniel SALLIER — expertise Kenza",
 },
}

def para_text(block):
    return unescape("".join(re.findall(r"<a:t>(.*?)</a:t>", block, re.S))).strip()

zin = zipfile.ZipFile(SRC)
items = {n: zin.read(n) for n in zin.namelist()}
applied, missed = 0, []

for slide, mapping in EDITS.items():
    key = f"ppt/slides/slide{slide}.xml"
    xml = items[key].decode("utf-8")
    seen = set()

    def repl(m):
        global applied
        block, txt = m.group(0), para_text(m.group(0))
        if txt not in mapping or txt in seen:
            return block
        seen.add(txt)
        new, first = escape(mapping[txt], quote=False), [True]
        def one(rm):
            if first[0]:
                first[0] = False
                return f"<a:t>{new}</a:t>"
            return "<a:t></a:t>"
        applied += 1
        return re.sub(r"<a:t>.*?</a:t>", one, block, flags=re.S)

    items[key] = re.sub(r"<a:p>.*?</a:p>", repl, xml, flags=re.S).encode("utf-8")
    missed += [(slide, k) for k in mapping if k not in seen]

# Le texte visible ne suffit pas : l'adresse survivait dans un lien mailto, porte par
# une Relationship du .rels et referencee par <a:hlinkClick> dans la diapositive.
links = 0
for n in list(items):
    if n.endswith(".rels"):
        s2 = items[n].decode("utf-8")
        s3 = re.sub(r'<Relationship [^>]*Target="mailto:[^"]*"[^>]*/>', "", s2)
        if s3 != s2:
            items[n] = s3.encode("utf-8"); links += 1
    elif re.fullmatch(r"ppt/slides/slide\d+\.xml", n):
        s2 = items[n].decode("utf-8")
        s3 = re.sub(r"<a:hlinkClick[^>]*/>", "", s2)
        s3 = re.sub(r"<a:hlinkClick[^>]*>.*?</a:hlinkClick>", "", s3, flags=re.S)
        if s3 != s2:
            items[n] = s3.encode("utf-8")
print(f"{links} lien(s) mailto retire(s)")

with zipfile.ZipFile(DST, "w", zipfile.ZIP_DEFLATED) as zout:
    for n in zin.namelist():
        zout.writestr(zin.getinfo(n), items[n])

print(f"{applied} paragraphes generalises")
for s, k in missed:
    print(f"  NON TROUVE  diapo {s} : {k[:70]!r}")
