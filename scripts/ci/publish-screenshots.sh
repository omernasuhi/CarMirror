#!/bin/bash
# CarPlay denemesinin ekran görüntülerini ayrı bir dala koyar; dal yalnızca
# son çalıştırmanın dosyalarını tutar. GitHub'da (telefondan da) görülebilir.
# Kullanım: scripts/ci/publish-screenshots.sh <klasör> <dal>   (GH_TOKEN gerekir)
set -euo pipefail

SOURCE="$1"
BRANCH="$2"
[ -d "$SOURCE" ] || { echo "Klasör yok: $SOURCE"; exit 0; }

STAGING=$(mktemp -d)
cp -R "$SOURCE"/. "$STAGING"/
cd "$STAGING"
cat > README.md <<EOF
# CarPlay simülatörü ekran görüntüleri

Bu dal CI tarafından her çalıştırmada yeniden yazılır.

- Çalıştırma: ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}
- Commit: ${GITHUB_SHA}
EOF

git init -q -b "$BRANCH"
git add -A
git -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit -q -m "CarPlay ekran görüntüleri (${GITHUB_SHA:0:7})"
git push -q -f "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "HEAD:refs/heads/$BRANCH"
echo "Ekran görüntüleri: ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/tree/${BRANCH}"
