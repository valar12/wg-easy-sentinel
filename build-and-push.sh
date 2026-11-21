#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash build-and-push.sh VERSION

Build and test the current clean commit, then ask before publishing a release.
VERSION must be an explicit X.Y.Z or vX.Y.Z (or set NEW_TAG).
Required: GITHUB_USER_OR_ORG, GITHUB_USER, GITHUB_PAT.
Requires Git, Docker, ShellCheck, jq, and the runtime test dependencies.
EOF
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  usage
  exit 0
fi
if (( $# > 1 )); then
  usage >&2
  exit 1
fi

release_tag=${1:-${NEW_TAG:-}}
if [[ ! $release_tag =~ ^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  printf 'An explicit semantic version is required.\n' >&2
  usage >&2
  exit 1
fi
: "${GITHUB_USER_OR_ORG:?Set GITHUB_USER_OR_ORG to your registry namespace}"
: "${GITHUB_USER:?Set GITHUB_USER to your registry login}"
: "${GITHUB_PAT:?Set GITHUB_PAT to your registry access token}"

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
for tool in git docker shellcheck jq; do
  command -v "$tool" >/dev/null || { printf 'Missing required tool: %s\n' "$tool" >&2; exit 1; }
done
if [[ -n $(git status --porcelain) ]]; then
  printf 'Commit or stash all working tree changes before releasing.\n' >&2
  exit 1
fi
if git show-ref --verify --quiet "refs/tags/$release_tag"; then
  printf 'Local tag already exists: %s\n' "$release_tag" >&2
  exit 1
fi
if git ls-remote --exit-code --tags origin "refs/tags/$release_tag" >/dev/null; then
  printf 'Remote tag already exists: %s\n' "$release_tag" >&2
  exit 1
else
  remote_status=$?
  if (( remote_status != 2 )); then
    printf 'Could not check remote tags; refusing to publish.\n' >&2
    exit 1
  fi
fi

revision=$(git rev-parse HEAD)
image_base="ghcr.io/${GITHUB_USER_OR_ORG,,}/wg-easy-sentinel"
image_version="$image_base:${release_tag#v}"
build_context=$(mktemp -d)
trap 'rm -rf -- "$build_context"' EXIT
# Archive the exact commit so ignored files and local credentials cannot enter a build.
git archive "$revision" | tar -x -C "$build_context"
(
  cd -- "$build_context"
  shellcheck wg-easy-sentinel.sh entrypoint.sh build-and-push.sh tests/run.sh
  bash tests/run.sh
)
docker build --pull --label "org.opencontainers.image.revision=$revision" \
  --tag "$image_version" "$build_context"
docker run --rm "$image_version" /app/wg-easy-sentinel.sh --help

printf 'Verified commit: %s\nImages: %s and %s:latest\nGit tag: %s\n' \
  "$revision" "$image_version" "$image_base" "$release_tag"
read -r -p 'Publish these images and push the Git tag? [y/N] ' confirm
if [[ $confirm != y && $confirm != Y ]]; then
  printf 'Build verified; publication cancelled.\n'
  exit 0
fi

printf '%s' "$GITHUB_PAT" | docker login ghcr.io --username "$GITHUB_USER" --password-stdin
docker push "$image_version"
docker tag "$image_version" "$image_base:latest"
docker push "$image_base:latest"
git tag -a "$release_tag" "$revision" -m "Release $release_tag"
git push origin "refs/tags/$release_tag"
printf 'Published %s from %s.\n' "$image_version" "$revision"
