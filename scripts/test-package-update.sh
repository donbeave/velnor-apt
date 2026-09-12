#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp -R "$root/." "$tmp/repo"
verified="$tmp/verified"
mkdir "$verified"
version=1.2.3
commit=0123456789abcdef0123456789abcdef01234567
: > "$tmp/assets.jsonl"
for arch in amd64 arm64; do
  name="velnor-runner-${version}-${arch}.deb"
  printf 'fixture-%s\n' "$arch" > "$verified/$name"
  digest=$(shasum -a 256 "$verified/$name" | awk '{print $1}')
  jq -cn --arg name "$name" --arg sha256 "$digest" '{name:$name,sha256:$sha256}' >> "$tmp/assets.jsonl"
done
jq -Sn --arg source_repository tailrocks/velnor --arg source_ref refs/tags/v$version \
  --arg source_commit "$commit" --arg version "$version" --slurpfile assets "$tmp/assets.jsonl" \
  '{schema:"velnor.package-release.v1",source_repository:$source_repository,source_ref:$source_ref,source_commit:$source_commit,version:$version,assets:$assets}' > "$verified/release-manifest.json"
jq -Sn --arg source_repository tailrocks/velnor --arg source_ref refs/tags/v$version \
  --arg source_digest "$commit" --slurpfile manifest "$verified/release-manifest.json" \
  '{source_repository:$source_repository,source_ref:$source_ref,source_digest:$source_digest,manifest:$manifest[0]}' > "$verified/identity.json"

(
  cd "$tmp/repo"
  VELNOR_VERIFIED_PACKAGE_DIR="$verified" ./scripts/package-update.sh
  shasum -a 256 package-state.json > "$tmp/first.sha"
  VELNOR_VERIFIED_PACKAGE_DIR="$verified" ./scripts/package-update.sh
  shasum -a 256 -c "$tmp/first.sha"
  jq -e '.version=="1.2.3" and (.packages|length)==2' package-state.json
)

jq '.source_digest = "ffffffffffffffffffffffffffffffffffffffff"' "$verified/identity.json" > "$tmp/bad.json"
mv "$tmp/bad.json" "$verified/identity.json"
if (cd "$tmp/repo" && VELNOR_VERIFIED_PACKAGE_DIR="$verified" ./scripts/package-update.sh); then
  echo "source identity mismatch was accepted" >&2
  exit 1
fi

# ============================ preview channel ==================================
# The rolling `preview` release carries no release-record/identity pair: its
# release-manifest.json is the only source-owned record, the version follows
# X.Y.Z~preview.N+<7-hex> bound to the main commit, and the state lands in
# package-state-preview.json without ever touching package-state.json.
preview_version="1.2.3~preview.7+0123456"
pverified="$tmp/verified-preview"
mkdir "$pverified"
: > "$tmp/preview-assets.jsonl"
for arch in amd64 arm64; do
  name="velnor-runner-preview-${preview_version}-${arch}.deb"
  printf 'preview-fixture-%s\n' "$arch" > "$pverified/$name"
  digest=$(shasum -a 256 "$pverified/$name" | awk '{print $1}')
  jq -cn --arg name "$name" --arg sha256 "$digest" '{name:$name,sha256:$sha256}' >> "$tmp/preview-assets.jsonl"
done
preview_manifest='{
  schema:"velnor.package-release.v1",
  source_repository:$source_repository,
  source_ref:$source_ref,
  source_commit:$source_commit,
  version:$version,
  assets:$assets
}'
jq -Sn --arg source_repository tailrocks/velnor --arg source_ref refs/heads/main \
  --arg source_commit "$commit" --arg version "$preview_version" \
  --slurpfile assets "$tmp/preview-assets.jsonl" "$preview_manifest" \
  > "$pverified/release-manifest.json"

(
  cd "$tmp/repo"
  shasum -a 256 package-state.json > "$tmp/stable-state.sha"
  VELNOR_PACKAGE_CHANNEL=preview VELNOR_VERIFIED_PACKAGE_DIR="$pverified" ./scripts/package-update.sh
  jq -e '.version=="1.2.3~preview.7+0123456" and .source_ref=="refs/heads/main" and
         (.packages|length)==2 and .schema=="velnor.apt-package-state.v1"' \
    package-state-preview.json
  shasum -a 256 -c "$tmp/stable-state.sha"
)

# Every incoherent preview manifest must be rejected without writing state.
mkdir -p "$tmp/preview-bad"
for case in ref grammar sha asset-name single-asset; do
  case "$case" in
    ref)         mutation='.source_ref = "refs/tags/v1.2.3"' ;;
    grammar)     mutation='.version = "1.2.3"' ;;
    sha)         mutation='.source_commit = "fffffffffffffffffffffffffffffffffffffff0"' ;;
    asset-name)  mutation='(.assets[0].name) = "velnor-runner-preview-9.9.9~preview.1+0123456-amd64.deb"' ;;
    single-asset) mutation='.assets |= .[0:1]' ;;
  esac
  rm -f "$tmp/repo/package-state-preview.json"
  jq "$mutation" "$pverified/release-manifest.json" > "$tmp/preview-bad/release-manifest.json"
  if (cd "$tmp/repo" && VELNOR_PACKAGE_CHANNEL=preview \
        VELNOR_VERIFIED_PACKAGE_DIR="$tmp/preview-bad" ./scripts/package-update.sh); then
    echo "preview channel accepted: $case" >&2
    exit 1
  fi
  [ ! -e "$tmp/repo/package-state-preview.json" ] \
    || { echo "preview state written despite rejection: $case" >&2; exit 1; }
done

# An unlisted channel must fail closed, exactly like an incoherent manifest.
rm -f "$tmp/repo/package-state-preview.json"
if (cd "$tmp/repo" && VELNOR_PACKAGE_CHANNEL=beta \
      VELNOR_VERIFIED_PACKAGE_DIR="$pverified" ./scripts/package-update.sh); then
  echo "unknown channel was accepted" >&2
  exit 1
fi
[ ! -e "$tmp/repo/package-state-preview.json" ] \
  || { echo "state written for an unknown channel" >&2; exit 1; }

echo "package-update preview channel checks passed"
