#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: ./scripts/release-openclaw.sh [--push] [version]

Without a version argument, the script resolves the latest published npm version
for the openclaw package, updates Dockerfile, creates a commit, and creates an
annotated git tag named v<version>.

Options:
  --push    Push the release commit and tag to origin after creating them.
  -h        Show this help.
EOF
}

push_release=0
target_version=""

while [ "$#" -gt 0 ]; do
  case "$1" in
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

current_version=$(perl -ne 'print "$1\n" if /^ARG OPENCLAW_VERSION=(.+)$/' Dockerfile | head -n 1)

if [ -z "$current_version" ]; then
  echo "error: could not determine current OPENCLAW_VERSION from Dockerfile" >&2
  exit 1
fi

if [ -z "$target_version" ]; then
  target_version=$(npm view openclaw version)
fi

if [ -z "$target_version" ]; then
  echo "error: failed to resolve target openclaw version" >&2
  exit 1
fi

if [ "$target_version" = "$current_version" ]; then
  echo "OpenClaw is already at version $target_version"
  exit 0
fi

tag_name="v$target_version"

if git rev-parse -q --verify "refs/tags/$tag_name" >/dev/null 2>&1; then
  echo "error: git tag $tag_name already exists" >&2
  exit 1
fi

perl -0pi -e "s/^ARG OPENCLAW_VERSION=\Q$current_version\E\$/ARG OPENCLAW_VERSION=$target_version/m" Dockerfile

git add Dockerfile
git commit -m "Bump OpenClaw to $target_version"
git tag -a "$tag_name" -m "Release OpenClaw $target_version"

if [ "$push_release" -eq 1 ]; then
  current_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)

  if [ -z "$current_branch" ]; then
    echo "error: cannot push release from a detached HEAD" >&2
    exit 1
  fi

  git push origin "HEAD:$current_branch"
  git push origin "$tag_name"
fi

echo "Released OpenClaw $target_version"
echo "Commit: $(git rev-parse --short HEAD)"
echo "Tag: $tag_name"
