# -*- coding: utf-8 -*-
"""Convertit Guide_utilisateur.pdf en Markdown structure.

Le PDF sort de Google Docs (Skia/PDF renderer). Sa mise en forme est portee par la
police et la taille, et ses tableaux par de vraies lignes de filet : les deux se
relisent, ce qui permet une conversion fidele plutot qu'un aplatissement du texte.
"""
import re, sys, unicodedata
from collections import defaultdict
from pdfminer.high_level import extract_pages
from pdfminer.layout import (LTChar, LTTextLine, LTTextContainer, LTLine, LTRect,
                             LTImage, LTContainer, LAParams)

PDF = sys.argv[1]
IMG_DIR = sys.argv[2] if len(sys.argv) > 2 else "images"

# ---------------------------------------------------------------- extraction
def collect(page):
    lines, rules, images = [], [], []
    def walk(o):
        for el in o:
            if isinstance(el, LTTextLine):
                txt = el.get_text()
                if txt.strip():
                    chars = [c for c in el if isinstance(c, LTChar)]
                    lines.append({"y": el.y1, "y0": el.y0, "x0": el.x0, "x1": el.x1,
                                  "text": txt, "chars": chars})
            elif isinstance(el, (LTLine, LTRect)):
                w, h = el.x1 - el.x0, el.y1 - el.y0
                if w > 560 and h > 800:       # cadre de page
                    continue
                if h <= 2.5 and w > 8:
                    rules.append(("h", el.x0, el.x1, (el.y0 + el.y1) / 2))
                elif w <= 2.5 and h > 8:
                    rules.append(("v", el.y0, el.y1, (el.x0 + el.x1) / 2))
            elif isinstance(el, LTImage):
                images.append({"y": el.y1, "bbox": el.bbox})
            elif isinstance(el, LTContainer):
                walk(el)
    walk(page)
    return lines, rules, images

def dominant(chars):
    if not chars:
        return ("", 0.0)
    tally = defaultdict(int)
    for c in chars:
        if c.get_text().strip():
            tally[(c.fontname.split("+")[-1], round(c.size, 1))] += 1
    if not tally:
        return ("", 0.0)
    return max(tally.items(), key=lambda kv: kv[1])[0]


def mono_ratio(chars):
    ink = [c for c in chars if c.get_text().strip()]
    if not ink:
        return 0.0
    return sum("Consolas" in c.fontname for c in ink) / len(ink)


def rich_text(line):
    """Texte d'une ligne, espaces retablis d'apres les ecarts, code en `backticks`.

    Google Docs n'emet pas toujours de glyphe espace : la separation des mots tient a
    l'ecart horizontal. Et le code au fil du texte n'est signale que par la police
    Consolas — le perdre reviendrait a rendre `sudo apt install libgtk-3-dev` en prose.
    """
    out, prev, mono = [], None, False
    for c in line["chars"]:
        t = c.get_text()
        is_mono = "Consolas" in c.fontname
        if t.strip() and prev is not None and c.x0 - prev > 0.28 * c.size:
            out.append(" ")
        if t.strip() and is_mono != mono:
            out.append("`")
            mono = is_mono
        out.append(t)
        if t.strip():
            prev = c.x1
    if mono:
        out.append("`")
    text = clean("".join(out)).replace("``", "")
    # Le blanc qui suit un fragment monospace appartient encore a la police : sans cela
    # on obtient `Gtk.jl ` au lieu de `Gtk.jl`.
    return re.sub(r"`(\s*)([^`]*?)(\s*)`", lambda m: m.group(1) + "`" + m.group(2) + "`" + m.group(3), text)

# ---------------------------------------------------------------- tableaux
def tables_on(rules):
    """Regroupe les filets en tableaux : bandes horizontales x colonnes verticales."""
    hs = [r for r in rules if r[0] == "h"]
    vs = [r for r in rules if r[0] == "v"]
    if len(hs) < 2 or len(vs) < 2:
        return []
    # Un tableau = un groupe de verticales partageant la meme plage y.
    groups = []
    for _, y0, y1, x in sorted(vs, key=lambda r: r[3]):
        for g in groups:
            if not (y1 < g["y0"] - 3 or y0 > g["y1"] + 3):
                g["xs"].append(x); g["y0"] = min(g["y0"], y0); g["y1"] = max(g["y1"], y1)
                break
        else:
            groups.append({"xs": [x], "y0": y0, "y1": y1})
    out = []
    for g in groups:
        xs = sorted(set(round(x, 1) for x in g["xs"]))
        ys = sorted({round(y, 1) for _, x0, x1, y in hs
                     if g["y0"] - 3 <= y <= g["y1"] + 3
                     and x1 >= xs[0] - 3 and x0 <= xs[-1] + 3}, reverse=True)
        if len(xs) >= 2 and len(ys) >= 2:
            out.append({"xs": xs, "ys": ys, "y0": ys[-1], "y1": ys[0]})
    return out

def render_table(tbl, lines):
    xs, ys = tbl["xs"], tbl["ys"]
    ncol, nrow = len(xs) - 1, len(ys) - 1
    cells = [[[] for _ in range(ncol)] for _ in range(nrow)]
    header = [[False] * ncol for _ in range(nrow)]
    for ln in lines:
        for ch in ln["chars"]:
            if not ch.get_text().strip():
                continue
            cx, cy = (ch.x0 + ch.x1) / 2, (ch.y0 + ch.y1) / 2
            if not (ys[-1] - 2 <= cy <= ys[0] + 2):
                continue
            col = next((i for i in range(ncol) if xs[i] - 2 <= cx <= xs[i + 1] + 2), None)
            row = next((j for j in range(nrow) if ys[j + 1] - 2 <= cy <= ys[j] + 2), None)
            if col is None or row is None:
                continue
            cells[row][col].append((round(ch.y0, 1), ch.x0, ch.width, ch.get_text()))
            if "Bold" in ch.fontname:
                header[row][col] = True
    grid = []
    for row in cells:
        rendered = []
        for ci, cell in enumerate(row):
            by_line = defaultdict(list)
            for y, x, w, t in cell:
                key = next((k for k in by_line if abs(k - y) < 3), y)
                by_line[key].append((x, w, t))
            parts, flush_right = [], []
            for _, v in sorted(by_line.items(), key=lambda kv: -kv[0]):
                buf, prev = [], None
                for x, w, t in sorted(v):
                    if t.strip() and prev is not None and x - prev > 0.28 * w:
                        buf.append(" ")
                    buf.append(t)
                    if t.strip():
                        prev = x + w
                parts.append(clean("".join(buf)))
                flush_right.append(max(x + w for x, w, _ in v))
            # Une cellule a une marge interne : le bord utile est le bord de colonne
            # diminue de cette marge, mesuree a gauche. Une ligne qui l'atteint a ete
            # coupee au milieu d'un mot, pas sur une espace.
            pad = min((x for _, v in by_line.items() for x, _, _ in v), default=0) - xs[ci]
            edge = xs[ci + 1] - max(pad, 0)
            merged = ""
            for k, part in enumerate(parts):
                if not merged:
                    merged = part
                elif (edge - flush_right[k - 1] < 6.0
                      and "_" in (merged.split() or [""])[-1]
                      and re.fullmatch(r"[a-z_][a-z_0-9]*", (merged.split() or [""])[-1])
                      and re.fullmatch(r"[a-z_0-9]+", part)):
                    # Une cellule etroite coupe « kenza_simplifie » en « kenza_simpli » +
                    # « fie ». Exiger un souligne dans le fragment de gauche evite de
                    # souder deux mots francais : « bas » + « possible ».
                    merged += part
                else:
                    merged += " " + part
            rendered.append(merged.strip())
        grid.append(rendered)
    grid = [r for r in grid if any(c for c in r)]
    if not grid:
        return []
    is_head = all(header[0][c] or not grid[0][c] for c in range(ncol)) and len(grid) > 1
    esc = lambda s: s.replace("|", "\\|")
    out = []
    if is_head:
        out.append("| " + " | ".join(esc(c) for c in grid[0]) + " |")
        out.append("|" + "|".join(" --- " for _ in range(ncol)) + "|")
        body = grid[1:]
    else:
        out.append("|" + "|".join("   " for _ in range(ncol)) + "|")
        out.append("|" + "|".join(" --- " for _ in range(ncol)) + "|")
        body = grid
    for r in body:
        out.append("| " + " | ".join(esc(c) for c in r) + " |")
    return out

# ---------------------------------------------------------------- nettoyage
def clean(s):
    s = s.replace("​", "").replace("­", "")
    s = s.replace("‑", "-").replace("–", "–")
    s = unicodedata.normalize("NFC", s)
    return re.sub(r"[ \t]+", " ", s).strip()

HEADING = {17.0: 2, 14.0: 3, 11.5: 4, 11.0: 5}

def classify(ln):
    font, size = dominant(ln["chars"])
    plain = clean(ln["text"])
    if not plain:
        return None
    if ln["y"] > 800 or re.fullmatch(r"Page \d+", plain) or plain == "Guide utilisateur":
        return None
    ratio = mono_ratio(ln["chars"])
    if "Consolas-Italic" in font and ratio > 0.8 and len(plain.split()) == 1:
        return ("codetag", plain, size)
    if ratio > 0.8:                       # bloc de code : la ligne est monospace en entier
        return ("code", ln["text"].replace("\u200b", "").rstrip(), ln["x0"])
    text = rich_text(ln)
    if "Bold" in font and size in HEADING:
        return ("h", clean(re.sub(r"`", "", text)), HEADING[size])
    if "Bold" in font and size >= 10.0:
        return ("lead", text, ln["x0"])   # amorce en gras : « Element - ... »
    # Les legendes de figure sont le seul contenu en italique 9 pt ; la suite d'une
    # legende longue ne commence donc pas forcement par « Figure ».
    if "Italic" in font and "Consolas" not in font and size <= 9.5:
        return ("caption", text, size)
    stripped = text.lstrip()
    if stripped.startswith(("•", "○", "▪")):
        return ("bullet", re.sub(r"^[•○▪]\s*", "", stripped), ln["x0"])
    if re.match(r"^[–-]\s+\S", stripped):
        return ("bullet", stripped[1:].strip(), max(ln["x0"], 90.0))
    return ("text", text, ln["x0"])


# ---------------------------------------------------------------- assemblage
BODY_X = 68.0          # marge gauche du corps ; au-dela, on est dans une liste


def is_label(text):
    """Vrai pour les intitules isoles du type « Description », « Avantages », « Limites ».

    Le PDF ne les distingue ni par la graisse ni par la taille — ils ne different du
    corps que par leur isolement. Sans ce test ils se soudent au paragraphe suivant :
    « Description Il s'agit d'une version lineaire... ».
    """
    bare = re.sub(r"[`*]", "", text).strip()
    return (0 < len(bare.split()) <= 5
            and not bare.endswith((".", ",", ";", ":", "!", "?", "»", ")"))
            and not bare[0].isdigit())

def emit(blocks):
    """Rend la liste de blocs en Markdown, en recollant les paragraphes coupes."""
    out, para, code, lang, bullets, held = [], [], [], None, [], []

    def flush_para():
        nonlocal para, held
        if para:
            out.append(" ".join(para)); out.append(""); para = []
        # Le texte s'ecoule AUTOUR des captures dans le PDF : inserer l'image des
        # qu'on la rencontre couperait la phrase en deux. On la pose apres.
        if held:
            for img in held:
                out.append(img); out.append("")
            held = []

    def flush_bullets():
        nonlocal bullets
        if bullets:
            for level, txt in bullets:
                if txt:
                    out.append("  " * level + "- " + txt)
            out.append(""); bullets = []

    def flush_code():
        nonlocal code, lang
        if code:
            pad = min((len(l) - len(l.lstrip()) for l in code if l.strip()), default=0)
            out.append("```" + (lang or ""))
            out.extend(l[pad:].rstrip() for l in code)
            out.append("```"); out.append("")
        code, lang = [], None

    def flush_all():
        flush_bullets(); flush_code(); flush_para()

    for kind, payload, extra in blocks:
        if kind == "table":
            flush_all(); out.extend(payload); out.append("")
        elif kind == "image":
            flush_bullets(); flush_code(); held.append(payload)
            if not para:
                flush_para()
        elif kind == "h":
            flush_all(); out.append("#" * extra + " " + payload); out.append("")
        elif kind == "caption":
            # Une legende longue est coupee sur plusieurs lignes dans le PDF.
            if out and len(out) > 1 and out[-1] == "" and out[-2].startswith("*") and out[-2].endswith("*"):
                out[-2] = out[-2][:-1] + " " + payload + "*"
            else:
                flush_all(); out.append("*" + payload + "*"); out.append("")
        elif kind == "lead":
            flush_all(); out.append("**" + payload.strip("*") + "**"); out.append("")
        elif kind == "codetag":
            # Google Docs place l'etiquette de langage au-dessus du bloc, dans la meme
            # police italique que peut prendre son contenu. Une etiquette deja en attente
            # signifie donc que cette ligne-ci est du code, pas une seconde etiquette.
            if lang is None and not code:
                flush_para(); flush_bullets()
                lang = payload if payload in ("bash", "julia", "csv", "json", "text") else None
                if lang is None:
                    para.append(payload)
            else:
                flush_para(); flush_bullets(); code.append(payload)
        elif kind == "code":
            flush_para(); flush_bullets(); code.append(payload)
        elif kind == "bullet":
            flush_para(); flush_code()
            bullets.append((0 if extra < 86 else 1, payload))
        else:
            flush_code()
            # Une ligne indentee au-dela de la marge, dans une liste en cours, est la
            # suite de la puce precedente : la traiter en paragraphe couperait la phrase.
            if bullets and extra > BODY_X:
                level, txt = bullets[-1]
                bullets[-1] = (level, (txt + " " + payload).strip())
            else:
                flush_bullets()
                # Le corps du texte commence toujours a la meme marge : une ligne
                # indentee est un element distinct — « Valeur par defaut : 0,03 » sous
                # son parametre — que joindre au paragraphe rendrait illisible.
                closed = not para or para[-1].rstrip().endswith((".", ":", ";", "»", "!", "?"))
                if extra <= BODY_X and closed and is_label(payload):
                    flush_para()
                    out.append("**" + payload.strip("*") + "**"); out.append("")
                    continue
                if extra > BODY_X and para:
                    flush_para()
                para.append(payload)
                if extra > BODY_X:
                    flush_para()
    flush_all()
    return out


def convert(pdf):
    blocks = []
    for pno, page in enumerate(extract_pages(pdf, laparams=LAParams(line_margin=0.35)), 1):
        lines, rules, images = collect(page)
        tbls = tables_on(rules)
        items = []
        for t in tbls:
            rendered = render_table(t, lines)
            if rendered:
                items.append((t["y1"], ("table", rendered, None)))
        for im in images:
            items.append((im["y"], ("image", None, pno)))
        for ln in lines:
            if any(t["y0"] - 2 <= ln["y0"] and ln["y"] <= t["y1"] + 2 for t in tbls):
                continue
            c = classify(ln)
            if c:
                items.append((ln["y"], c))
        items.sort(key=lambda kv: -kv[0])
        blocks.extend(b for _, b in items)
    return blocks

ANCHOR_STRIP = re.compile(r"[^\w\s-]", re.UNICODE)


def anchor(title):
    a = ANCHOR_STRIP.sub("", title.lower())
    return "#" + a.replace(" ", "-")


def level_up(text):
    """Comble les sauts de niveau de titre.

    La taille des caracteres n'est pas appliquee uniformement dans le document — un
    « Etape 1 » et un « 6.3.1 » sortent tous deux en 11 pt sous un titre de niveau 3 —
    et un saut de ### a ##### casse la hierarchie de la table des matieres.
    """
    out, prev, fence = [], 1, False
    for line in text.splitlines():
        if line.startswith("```"):
            fence = not fence
        m = None if fence else re.match(r"^(#{2,6}) (.*)$", line)
        if m:
            depth = min(len(m.group(1)), prev + 1)
            prev = depth
            out.append("#" * depth + " " + m.group(2))
        else:
            out.append(line)
    return "\n".join(out)


def finalize(text):
    """Remplace la page de garde et le sommaire imprime par un titre et une table
    de matieres a ancres. Les numeros de page du PDF n'ont plus de sens ici."""
    body = level_up(text[text.index("\n## 1. Introduction"):].lstrip("\n"))
    toc, seen = [], set()
    for line in body.splitlines():
        m = re.match(r"^(#{2,3}) (\d[\d.]*\.?\s+.*)$", line)
        if not m:
            continue
        depth, title = len(m.group(1)) - 2, m.group(2).strip()
        a = anchor(title)
        if a in seen:
            continue
        seen.add(a)
        toc.append("  " * depth + f"- [{title}]({a})")
    head = ["# AirTrafficForecaster — Guide utilisateur", "",
            "Application de prévision du trafic aérien développée en Julia.", "",
            "> Transcription Markdown de `Guide_utilisateur.pdf`, exporté de Google Docs.",
            "> Le PDF ne porte ni niveau de titre ni style nommé : les niveaux sont déduits",
            "> de la taille des caractères, les tableaux des filets tracés, et les intitulés",
            "> isolés (« Description », « Limites »…) sont mis en gras faute d'autre marque",
            "> dans la source. Les numéros de page du sommaire imprimé sont remplacés par",
            "> des ancres.", "",
            "## Sommaire", ""]
    return "\n".join(head + toc + ["", body])


if __name__ == "__main__":
    blocks = convert(PDF)
    n, final = 0, []
    for kind, payload, extra in blocks:
        if kind == "image":
            final.append(("image", f"IMG::{n:02d}", None))
            n += 1
        else:
            final.append((kind, payload, extra))
    text = "\n".join(emit(final))
    text = re.sub(r"\n{3,}", "\n\n", text).strip() + "\n"

    # Alt text : la legende « Figure N - ... » qui suit chaque capture.
    def name_image(m):
        idx, caption = m.group(1), m.group(2)
        label = re.match(r"(Figure \d+)", caption)
        alt = label.group(1) if label else "Capture d'écran"
        return f"![{alt}]({IMG_DIR}/capture-{idx}.png)\n\n*{caption.strip('*')}*"
    text = re.sub(r"IMG::(\d\d)\n\n\*(Figure [^\n]*)\*", name_image, text)
    text = re.sub(r"IMG::(\d\d)",
                  lambda m: f"![Capture d'ecran]({IMG_DIR}/capture-{m.group(1)}.png)", text)
    sys.stdout.write(finalize(text))
