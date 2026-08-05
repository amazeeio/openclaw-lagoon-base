#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: ./scripts/release-openclaw.sh [--push] [--base-revision N] [openclaw-version]

Without a version argument, the script resolves the latest published npm version
for the openclaw package. The Dockerfile tracks both the packaged OpenClaw version
(ARG OPENCLAW_VERSION) and the published image release version (ARG RELEASE_VERSION).

When --base-revision is provided, the packaged OpenClaw version stays at the
specified or current version and the image release version becomes
<openclaw-version>_<N>.

Options:
  --base-revision N  Create a base-image-only release suffix such as
                     2026.4.2_2 without changing the packaged OpenClaw
                     version unless a version argument is also provided.
  --push             Push the release commit and tag to origin after creating them.
  -h                 Show this help.
EOF
}

push_release=0
base_revision=""
target_version=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base-revision)
      shift
      if [ "$#" -eq 0 ]; then
        echo "error: --base-revision requires a numeric argument" >&2
        usage >&2
        exit 1
      fi
      base_revision="$1"
      ;;
    --push)
      push_release=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [ -n "$target_version" ]; then
        echo "error: only one version argument is supported" >&2
        usage >&2
        exit 1
      fi
      target_version="$1"
      ;;
  esac
  shift
done

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

if ! command -v git >/dev/null 2>&1; then
  echo "error: git is required" >&2
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "error: npm is required to resolve the latest openclaw version" >&2
  exit 1
fi

if [ ! -f Dockerfile ]; then
  echo "error: Dockerfile not found in $repo_root" >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree is not clean; commit or stash existing changes first" >&2
  exit 1
fi

if [ -n "$base_revision" ] && ! printf '%s' "$base_revision" | grep -Eq '^[1-9][0-9]*$'; then
  echo "error: --base-revision must be a positive integer" >&2
  exit 1
fi

current_version=$(sed -n 's/^ARG OPENCLAW_VERSION=//p' Dockerfile | head -n 1)

if [ -z "$current_version" ]; then
  echo "error: could not determine current OPENCLAW_VERSION from Dockerfile" >&2
  exit 1
fi

if ! printf '%s' "$current_version" | grep -Eq '^[0-9]+(\.[0-9]+){2}([.-][0-9A-Za-z]+)*$'; then
  echo "error: malformed OPENCLAW_VERSION '$current_version' in Dockerfile" >&2
  exit 1
fi

current_release_version=$(sed -n 's/^ARG RELEASE_VERSION=//p' Dockerfile | head -n 1)
if [ -z "$current_release_version" ]; then
  current_release_version="$current_version"
fi

if [ -z "$current_release_version" ]; then
  echo "error: could not determine current release version" >&2
  exit 1
fi

explicit_version="$target_version"
if [ -z "$target_version" ]; then
  if [ -n "$base_revision" ]; then
    target_version="$current_version"
  else
    target_version=$(npm view openclaw version)
  fi
fi

if [ -z "$target_version" ]; then
  echo "error: failed to resolve target openclaw version" >&2
  exit 1
fi

if ! printf '%s' "$target_version" | grep -Eq '^[0-9]+(\.[0-9]+){2}([.-][0-9A-Za-z]+)*$'; then
  echo "error: malformed target openclaw version '$target_version'" >&2
  exit 1
fi

# Never auto-downgrade: npm's `latest` dist-tag can point BELOW the version we
# ship (we run 2026.7.2 betas while latest is a 2026.7.1-N hotfix republish).
# Compare numeric cores; a prerelease -> stable move of the same core is the one
# same-core case that counts as an upgrade. Only guards the AUTOMATED npm-latest
# path — an explicit version argument (e.g. beta.4 -> beta.7) is deliberate.
if [ -z "$explicit_version" ] && [ "$target_version" != "$current_version" ]; then
  target_core=$(printf '%s' "$target_version" | sed 's/[-+].*//')
  current_core=$(printf '%s' "$current_version" | sed 's/[-+].*//')
  allow_bump=0
  if [ "$target_core" = "$current_core" ]; then
    case "$current_version" in
      *-*) case "$target_version" in *-*) allow_bump=0;; *) allow_bump=1;; esac;;
      *) allow_bump=0;;
    esac
  elif [ "$(printf '%s\n%s\n' "$target_core" "$current_core" | sort -V | head -n1)" = "$current_core" ]; then
    allow_bump=1
  fi
  if [ "$allow_bump" -eq 0 ]; then
    echo "npm latest is $target_version but Dockerfile ships $current_version; not an upgrade, nothing to do."
    exit 0
  fi
fi

# The Dockerfile builds FROM ghcr.io/openclaw/openclaw:<version>-browser. npm can
# publish a version (e.g. an "-N" hotfix republish like 2026.7.1-2) with no
# matching browser image; bumping to it makes main unbuildable and every publish
# fails. Only bump when the browser image actually exists.
if [ "$target_version" != "$current_version" ]; then
  browser_tag="${target_version}-browser"
  ghcr_token=$(curl -fsSL "https://ghcr.io/token?scope=repository:openclaw/openclaw:pull" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  manifest_status=$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $ghcr_token" \
    -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json" \
    "https://ghcr.io/v2/openclaw/openclaw/manifests/$browser_tag")
  if [ "$manifest_status" != "200" ]; then
    echo "OpenClaw $target_version has no ghcr.io/openclaw/openclaw:$browser_tag image (status $manifest_status); skipping bump to keep main buildable."
    exit 0
  fi
fi

if [ -n "$base_revision" ]; then
  target_release_version="${target_version}_${base_revision}"
else
  target_release_version="$target_version"
fi

if [ "$target_version" = "$current_version" ] && [ "$target_release_version" = "$current_release_version" ]; then
  echo "OpenClaw image is already at release $target_release_version"
  exit 0
fi

tag_name="v$target_release_version"

# Idempotent no-op, not an error: the scheduled workflow re-runs every 6h and
# must go green when the release already exists.
if git rev-parse -q --verify "refs/tags/$tag_name" >/dev/null 2>&1; then
  echo "git tag $tag_name already exists; nothing to do."
  exit 0
fi

if [ "$target_version" != "$current_version" ]; then
  perl -0pi -e "s/^ARG OPENCLAW_VERSION=\Q$current_version\E\$/ARG OPENCLAW_VERSION=$target_version/m" Dockerfile
fi

if grep -Eq '^ARG RELEASE_VERSION=' Dockerfile; then
  perl -0pi -e "s/^ARG RELEASE_VERSION=\Q$current_release_version\E\$/ARG RELEASE_VERSION=$target_release_version/m" Dockerfile
else
  # If ARG RELEASE_VERSION doesn't exist, insert it right after ARG OPENCLAW_VERSION
  perl -0pi -e "s/^(ARG OPENCLAW_VERSION=\Q$target_version\E)\$/\$1\nARG RELEASE_VERSION=$target_release_version/m" Dockerfile
fi

git add Dockerfile

if [ "$target_version" = "$current_version" ]; then
  commit_message="Release base image $target_release_version"
else
  commit_message="Bump OpenClaw to $target_version"
fi

git commit -m "$commit_message"
git tag -a "$tag_name" -m "Release OpenClaw image $target_release_version (OpenClaw $target_version)"

if [ "$push_release" -eq 1 ]; then
  current_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)

  if [ -z "$current_branch" ]; then
    echo "error: cannot push release from a detached HEAD" >&2
    exit 1
  fi

  git push origin "HEAD:$current_branch"
  git push origin "$tag_name"
fi

echo "Released OpenClaw image $target_release_version"
echo "Packaged OpenClaw: $target_version"
echo "Commit: $(git rev-parse --short HEAD)"
echo "Tag: $tag_name"
