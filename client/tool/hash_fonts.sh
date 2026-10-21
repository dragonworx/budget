#!/bin/sh
# Content-hash the bundled font files of a Flutter web build and point
# FontManifest.json at the new names, e.g.
#   assets/fonts/MaterialIcons-Regular.otf -> MaterialIcons-Regular.3f9c0a12be.otf
# Flutter's asset names are not hashed and the icon font is tree-shaken per
# build, so a browser still holding an older build's subset (iOS Safari did)
# draws any newly used icon as nothing. A new subset now has a new URL.
# Usage: tool/hash_fonts.sh build/web
set -eu
WEB="${1:-build/web}"
MANIFEST="$WEB/assets/FontManifest.json"
[ -f "$MANIFEST" ] || { echo "hash_fonts: no $MANIFEST" >&2; exit 1; }
find "$WEB/assets" -type f \( -name '*.otf' -o -name '*.ttf' \) | while read -r f; do
  rel="${f#"$WEB/assets/"}"
  # Only fonts the manifest loads; skip already-hashed names.
  grep -q "\"$rel\"" "$MANIFEST" || continue
  case "$rel" in *.[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].*) continue ;; esac
  h=$(sha256sum "$f" | cut -c1-10)
  new="${rel%.*}.$h.${rel##*.}"
  mv "$f" "$WEB/assets/$new"
  sed -i "s#\"$rel\"#\"$new\"#g" "$MANIFEST"
  echo "hash_fonts: $rel -> $new"
done
