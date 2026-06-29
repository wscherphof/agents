#!/usr/bin/env bash
# srclink.sh — print a Markdown link to a project source file that resolves on
# the project repo's web host (GitHub / Azure DevOps), instead of a path
# relative to the agents workspace root (which 404s in Claude Code Web, because
# src/ is gitignored in the agents repo — see the "Linking to project source
# files" section of the agents repo's CLAUDE.md).
#
# It is fully self-contained: it derives the host, account, repo and branch from
# the project repo's own git checkout, so just run it from inside the project
# working tree and pass the same path you'd `cat`/`ls`.
#
# Usage:
#   srclink <path>[:<line>[-<endline>]] [link-text]
#
# Examples (run from the project working dir):
#   srclink app.ts
#   srclink src/app/foo.ts:42
#   srclink src/app/foo.ts:42-50
#   srclink docker/ng/CODE-REVIEW.md "the findings doc"
#
# The session-start hook symlinks this onto PATH as `srclink`; you can also call
# it directly as "$AGENTS_TOOLS_DIR/srclink.sh" from setup scripts.

set -euo pipefail

die() { echo "srclink: $*" >&2; exit 1; }

case "${1:-}" in
  '' | -h | --help)
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

arg=$1
text=${2:-}

# Split off a trailing :line or :line-endline (digits only after the colon, so a
# Windows-style drive letter or a colon in the name doesn't get eaten).
path=$arg
line=""
endline=""
if [[ $arg =~ ^(.+):([0-9]+)(-([0-9]+))?$ ]]; then
  path=${BASH_REMATCH[1]}
  line=${BASH_REMATCH[2]}
  endline=${BASH_REMATCH[4]}
fi

# Resolve to an absolute path against the current directory (no existence check,
# so a just-created/not-yet-pushed file still links).
abs=$(realpath -m -- "$path")

# Find the git repo that contains it, and confirm it's the cloned project repo
# (under <agents-root>/src/), not the agents workspace itself.
repo_root=$(git -C "$(dirname -- "$abs")" rev-parse --show-toplevel 2>/dev/null) \
  || die "‘$path’ is not inside a git repo"
case "$repo_root" in
  */src/*) : ;;
  *) die "‘$path’ is not under src/ (the cloned project repo); for an agents-repo file use a normal workspace-relative Markdown link" ;;
esac

rel=$(realpath -m --relative-to="$repo_root" -- "$abs")
case "$rel" in
  ../* | /*) die "‘$path’ resolves outside the project repo ($repo_root)" ;;
esac

branch=$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)

# Host/account/repo from the project repo's origin remote, with any embedded PAT
# (https://PAT@host/…) stripped so it never lands in the rendered URL.
remote=$(git -C "$repo_root" remote get-url origin 2>/dev/null) \
  || die "no origin remote in $repo_root"
remote=${remote#*://} # drop scheme
remote=${remote#*@}   # drop "PAT@" / "user:pass@" if present

# Percent-encode everything but the unreserved set and the path separator.
encode() {
  local s=$1 out='' i c
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      [a-zA-Z0-9._/~-]) out+=$c ;;
      *) printf -v c '%%%02X' "'$c"; out+=$c ;;
    esac
  done
  printf '%s' "$out"
}
enc_path=$(encode "$rel")

case $remote in
  dev.azure.com/*)
    rest=${remote#dev.azure.com/}    # <account>/_git/<repo>
    account=${rest%%/_git/*}
    repo=${rest#*/_git/}
    repo=${repo%.git}
    url="https://dev.azure.com/$account/_git/$repo?path=/$enc_path&version=GB$branch"
    if [ -n "$line" ]; then
      end=${endline:-$line}
      url+="&line=$line&lineEnd=$end&lineStartColumn=1&lineEndColumn=1"
    fi
    ;;
  github.com/*)
    rest=${remote#github.com/}       # <account>/<repo>[.git]
    account=${rest%%/*}
    repo=${rest#*/}
    repo=${repo%/}
    repo=${repo%.git}
    url="https://github.com/$account/$repo/blob/$branch/$enc_path"
    if [ -n "$line" ]; then
      url+="#L$line"
      [ -n "$endline" ] && url+="-L$endline"
    fi
    ;;
  *)
    die "unsupported host in origin remote: $remote" ;;
esac

# Default the link text to the repo-relative path (+ line anchor).
if [ -z "$text" ]; then
  text=$rel
  if [ -n "$line" ]; then
    text+=":$line"
    [ -n "$endline" ] && text+="-$endline"
  fi
fi

printf '[%s](%s)\n' "$text" "$url"
