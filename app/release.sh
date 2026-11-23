#!/bin/sh
# Publie sur GitHub la version la plus récente de CHANGELOG.md : ./app/release.sh
# Avant : écrire en haut de CHANGELOG.md « ## vX.Y.Z (date) » avec ses nouveautés, améliorations et bugs corrigés,
# puis commiter. Le script construit l'app, crée le tag vX.Y.Z et la Release avec Nabla-X.Y.Z.dmg.
set -e
cd "$(dirname "$0")/.."
V=$(sed -n 's/^## v\([0-9][0-9.]*\).*/\1/p' CHANGELOG.md | head -1)
TAG="v$V"
fail() { echo "$1" >&2; exit 1; }

[ -n "$V" ] || fail "Aucune version « ## vX.Y.Z » dans CHANGELOG.md."
[ "$(git branch --show-current)" = main ] || fail "Publier depuis la branche main."
[ -z "$(git status --porcelain --untracked-files=no)" ] || fail "Des changements ne sont pas commités."
git fetch -q origin
[ -z "$(git rev-list HEAD..origin/main)" ] || fail "main est en retard sur origin/main : git pull d'abord."
! gh release view "$TAG" >/dev/null 2>&1 || fail "$TAG est déjà publiée : ajouter une nouvelle version en haut de CHANGELOG.md."
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  [ "$(git rev-parse "$TAG^{commit}")" = "$(git rev-parse HEAD)" ] || fail "Le tag $TAG existe déjà sur un autre commit."
fi

REPO=$(gh repo view --json url -q .url)
TMP=$(mktemp -d)
# notes de version : la première section « ## v… » du CHANGELOG, c'est-à-dire celle de cette version
awk '/^## v/ { n++; next } n == 1' CHANGELOG.md > "$TMP/notes.md"
cat >> "$TMP/notes.md" <<EOF

### Installer

Télécharger \`Nabla-$V.dmg\` ci-dessous, l'ouvrir et glisser **Nabla** sur **Applications**.
Premier lancement et prérequis (MacTeX) : voir le [README]($REPO/blob/$TAG/README.md#installer).
EOF

./app/build.sh
cp app/Nabla.dmg "$TMP/Nabla-$V.dmg"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag -a "$TAG" -m "Nabla $V"
git push -q origin main "$TAG"
gh release create "$TAG" "$TMP/Nabla-$V.dmg" --verify-tag --title "Nabla $V" --notes-file "$TMP/notes.md"
rm -rf "$TMP"
