#!/usr/bin/env bash
# Genere docs/Guide_utilisateur.pdf a partir de docs/Guide_utilisateur.md.
#
# Le Markdown est la source de reference : ce script ne fait que le mettre en page.
# Toute correction doit donc etre faite dans le .md, jamais dans le PDF.
#
# Prerequis : pandoc et une distribution LaTeX fournissant xelatex, avec les polices
# TeX Gyre Pagella / TeX Gyre Heros / DejaVu Sans Mono.
#
#   sudo apt install pandoc texlive-xetex texlive-fonts-extra fonts-dejavu
#
# Usage : bash docs/build_pdf.sh
set -euo pipefail

DOCS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
cp -r "$DOCS/images" "$BUILD/"

python3 - "$DOCS/Guide_utilisateur.md" "$BUILD/guide.md" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()

# Le PDF porte sa propre table des matieres, paginee : le sommaire a ancres du Markdown
# ferait double emploi. Le titre passe en metadonnee.
head = text[:text.index("## Sommaire")].rstrip()
head = head.replace("# AirTrafficForecaster — Guide utilisateur\n", "").lstrip()
body = text[text.index("\n## 1. Introduction"):].lstrip("\n")

# Typographie francaise : l'espace qui precede ; : ! ? et suit « doit etre insecable,
# sinon la ponctuation double se retrouve seule en debut de ligne. On ne touche pas au
# contenu des blocs de code.
def fix(block):
    block = re.sub(r" ([;:!?»])", " \\1", block)
    return re.sub(r"« ", "« ", block)

out, fence = [], False
for line in (head + "\n\n\\newpage\n\n" + body).split("\n"):
    if line.lstrip().startswith("```"):
        fence = not fence
    out.append(line if fence or line.lstrip().startswith("```") else fix(line))
open(dst, "w", encoding="utf-8").write("\n".join(out))
PY

cat > "$BUILD/entete.tex" <<'TEX'
\usepackage{etoolbox}
\usepackage{booktabs}
\usepackage{fancyhdr}

% Les tableaux les plus larges tiennent mal dans une page A4 : un corps plus petit evite
% les debordements sans reduire tout le document.
\AtBeginEnvironment{longtable}{\footnotesize}
\AtBeginEnvironment{quote}{\small}

% Un identifiant comme kenza_simplifie_combine ne se coupe nulle part et debordait sur la
% colonne voisine. On autorise la coupure apres chaque souligne, sans trait d'union.
\renewcommand{\_}{\textunderscore\allowbreak}
\setlength{\emergencystretch}{3em}

% Le document n'a pas de \chapter : sans cela \leftmark reste fige sur « Table des matieres ».
\renewcommand{\sectionmark}[1]{\markboth{#1}{}}
\pagestyle{fancy}
\fancyhf{}
\fancyhead[L]{\small\nouppercase{\leftmark}}
\fancyhead[R]{\small AirTrafficForecaster}
\fancyfoot[C]{\thepage}
\renewcommand{\headrulewidth}{0.4pt}
\fancypagestyle{plain}{\fancyhf{}\fancyfoot[C]{\thepage}\renewcommand{\headrulewidth}{0pt}}
TEX

cd "$BUILD"
pandoc guide.md -o "$DOCS/Guide_utilisateur.pdf" \
  --pdf-engine=xelatex --toc --toc-depth=3 --resource-path=.:images \
  -V documentclass=report -V papersize=a4 -V fontsize=11pt \
  -V geometry:margin=2.2cm -V lang=fr -V linkcolor=blue -V toccolor=black \
  -V mainfont="TeX Gyre Pagella" -V sansfont="TeX Gyre Heros" \
  -V monofont="DejaVu Sans Mono" -V monofontoptions="Scale=0.82" \
  -V title="AirTrafficForecaster — Guide utilisateur" \
  -V subtitle="Application de prévision du trafic aérien développée en Julia" \
  -V date="$(LC_ALL=fr_FR.UTF-8 date '+%B %Y' 2>/dev/null || date '+%Y-%m')" \
  -H entete.tex

echo "Ecrit : $DOCS/Guide_utilisateur.pdf"
