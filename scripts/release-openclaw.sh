#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: ./scripts/release-openclaw.sh [--push] [--base-revision N] [openclaw-version]

Without a version argument, the script resolves the latest published npm version
for the openclaw package. The Dockerfile tracks the packaged OpenClaw version,
while RELEASE_VERSION tracks the published image release version.

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

release_version_file="RELEASE_VERSION"

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

if [ -f "$release_version_file" ]; then
  current_release_version=$(tr -d '\n' < "$release_version_file")
else
  current_release_version="$current_version"
fi

if [ -z "$current_release_version" ]; then
  echo "error: could not determine current release version" >&2
  exit 1
fi

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

if git rev-parse -q --verify "refs/tags/$tag_name" >/dev/null 2>&1; then
  echo "error: git tag $tag_name already exists" >&2
  exit 1
fi

if [ "$target_version" != "$current_version" ]; then
  perl -0pi -e "s/^ARG OPENCLAW_VERSION=\Q$current_version\E\$/ARG OPENCLAW_VERSION=$target_version/m" Dockerfile
fi

printf '%s\n' "$target_release_version" > "$release_version_file"

git add Dockerfile "$release_version_file"

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
