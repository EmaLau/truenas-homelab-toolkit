#!/bin/sh
# Builds the documentation pages of the toolkit (English and Italian) from the Markdown files in docs/, with pandoc.
# Usage: docs/web/build.sh <output folder>   (creates docs-en.html and docs-it.html, standalone)
# Runs in CI; locally it needs pandoc (or: docker run --rm -v "$PWD":/data -w /data pandoc/core ... ).
set -eu
# pandoc reads the arguments (titles with — and →) according to the locale: UTF-8 is needed
export LANG=C.UTF-8 LC_ALL=C.UTF-8
HERE=$(cd "$(dirname "$0")" && pwd)
DOCS=$(dirname "$HERE")
OUT=${1:?output folder}
mkdir -p "$OUT"
GH=https://github.com/EmaLau/truenas-homelab-toolkit/blob/main

# drops the title, the language links and the contents list written for GitHub (the page has its own),
# and points the relative links to GitHub or to the other page
prep() {
  awk 'f || /^# (Overview|Panoramica)$/ {f=1} f' "$1" | sed \
    -e "s#](\.\./#]($GH/#g" \
    -e "s#](storage-status\.schema\.json#]($GH/docs/storage-status.schema.json#g" \
    -e "s#](documentation\.md#](docs-en.html#g" \
    -e "s#](documentazione\.md#](docs-it.html#g"
}

page() {  # md lang pagetitle crumb subtitle cta tocname top otherlang otherlabel
  prep "$DOCS/$1" | pandoc --from markdown --standalone --section-divs --toc --toc-depth=2 \
    --template "$HERE/template.html" -H "$HERE/style.html" \
    -M lang="$2" -M pagetitle="$3" -M crumb="$4" -M subtitle="$5" -M cta="$6" -M tocname="$7" -M top="$8" \
    -M otherlang="$9" -M otherlabel="${10}" -o "$OUT/docs-$2.html"
  echo "$OUT/docs-$2.html"
}

page documentation.md en "TrueNAS homelab toolkit — Documentation" "Documentation" \
  "Installation, every setting, how the scripts work, restoring a backup, security and development." \
  "GitHub →" "Contents" "back to top ↑" it "Italiano"
page documentazione.md it "TrueNAS homelab toolkit — Documentazione" "Documentazione" \
  "Installazione, tutte le impostazioni, come funzionano gli script, ripristino di un backup, sicurezza e sviluppo." \
  "GitHub →" "Indice" "torna su ↑" en "English"
