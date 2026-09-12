#!/usr/bin/env bash
set -euo pipefail

# Channel selection. `stable` (default, and the historical contract) validates a
# tagged release and rewrites package-state.json. `preview` validates the rolling
# `preview` release and rewrites package-state-preview.json instead. Anything
# else fails closed.
channel=${VELNOR_PACKAGE_CHANNEL:-stable}
case "$channel" in
  stable) ;;
  preview) ;;
  *)
    printf 'package-update: unknown channel: %s\n' "$channel" >&2
    exit 1
    ;;
esac

# The preview suite sorts strictly before the corresponding release (dpkg `~`).
PREVIEW_VERSION_RE='^[0-9]+[.][0-9]+[.][0-9]+~preview[.][0-9]+\+[0-9a-f]{7}$'

verified=${VELNOR_VERIFIED_PACKAGE_DIR:?missing VELNOR_VERIFIED_PACKAGE_DIR}
manifest="$verified/release-manifest.json"
state=package-state.json
if [ "$channel" = preview ]; then
  # The rolling preview release ships no release-record/identity pair: its
  # release-manifest.json is the only source-owned coherence record, so the
  # identity cross-check below does not apply.
  state=package-state-preview.json
fi

identity="$verified/identity.json"

if [ "$channel" = stable ]; then
  jq -e '
    keys == ["manifest","source_digest","source_ref","source_repository"] and
    .source_repository == "tailrocks/velnor" and
    (.source_ref | test("^refs/tags/v[0-9]+[.][0-9]+[.][0-9]+$")) and
    (.source_digest | test("^[0-9a-f]{40}$"))
  ' "$identity" >/dev/null

  jq -e '
    keys == ["assets","schema","source_commit","source_ref","source_repository","version"] and
    .schema == "velnor.package-release.v1" and
    .source_repository == "tailrocks/velnor" and
    (.source_ref | test("^refs/tags/v[0-9]+[.][0-9]+[.][0-9]+$")) and
    (.source_commit | test("^[0-9a-f]{40}$")) and
    (.version | test("^[0-9]+[.][0-9]+[.][0-9]+$")) and
    ([.assets[] | select(.name | test("^velnor-runner-[0-9]+[.][0-9]+[.][0-9]+-(amd64|arm64)[.]deb$"))] | length) == 2
  ' "$manifest" >/dev/null

  test "$(jq -r .source_ref "$identity")" = "$(jq -r .source_ref "$manifest")"
  test "$(jq -r .source_digest "$identity")" = "$(jq -r .source_commit "$manifest")"
else
  jq -e --arg version_re "$PREVIEW_VERSION_RE" '
    keys == ["assets","schema","source_commit","source_ref","source_repository","version"] and
    .schema == "velnor.package-release.v1" and
    .source_repository == "tailrocks/velnor" and
    .source_ref == "refs/heads/main" and
    (.source_commit | test("^[0-9a-f]{40}$")) and
    (.version | test($version_re)) and
    (.assets | length) == 2 and
    all(.assets[]; (.sha256 | test("^[0-9a-f]{64}$"))) and
    .source_commit[0:7] ==
      (.version | capture("^[0-9]+[.][0-9]+[.][0-9]+~preview[.][0-9]+\\+(?<sha>[0-9a-f]{7})$").sha) and
    (.version as $v |
      ([.assets[].name] | sort) ==
      (["amd64","arm64"] | map("velnor-runner-preview-" + $v + "-" + . + ".deb") | sort))
  ' "$manifest" >/dev/null
fi

jq -S '{
  schema:"velnor.apt-package-state.v1",
  source_repository,
  source_ref,
  source_commit,
  version,
  packages:(
    [.assets[] | select(.name | test("[. ]deb$")) | {name,sha256}]
    | sort_by(.name)
  )
}' "$manifest" > "$state"

jq -e '
  keys == ["packages","schema","source_commit","source_ref","source_repository","version"] and
  .schema == "velnor.apt-package-state.v1" and
  (.packages | length) == 2 and
  [.packages[].name] == ([.packages[].name] | sort | unique)
' "$state" >/dev/null

if [ "$channel" = preview ]; then
  jq -e --arg version_re "$PREVIEW_VERSION_RE" '
    (.version | test($version_re)) and
    all(.packages[]; (.sha256 | test("^[0-9a-f]{64}$"))) and
    (.version as $v |
      ([.packages[].name] | sort) ==
      (["amd64","arm64"] | map("velnor-runner-preview-" + $v + "-" + . + ".deb") | sort))
  ' "$state" >/dev/null
fi
