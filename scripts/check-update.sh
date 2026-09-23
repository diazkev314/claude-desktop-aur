#!/usr/bin/env bash
#
# Usage: check-update.sh [--apply [--reviewed]]
#
# Checks Anthropic's apt index for a newer claude-desktop release. With
# --apply, a release that needs no review is also written to the
# PKGBUILD and .SRCINFO. Adding --reviewed applies a release flagged
# for review too, once a human has reviewed it.
#
# Environment:
#   REPORT_FILE  if set, a release flagged for review also writes its
#                report there, without the progress lines of stderr
#   INDEX_DIR    if set, reads saved indexes instead of downloading

set -Eeuo pipefail

# set -e alone exits with the failing command's own code (awk uses 2),
# which could be mistaken for one of the script's status codes. Turn
# every unexpected failure into exit 1 instead.
trap 'exit 1' ERR

readonly REPO_URL="https://downloads.claude.ai/claude-desktop/apt/stable"

# Find the repo from the script's own location, not the current
# directory, so the script works no matter where it's run from.
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

# Exit codes:
#   0  update available (or flagged but --reviewed); prints the new version
#      on stdout
#   1  error (network failure, missing file, bad index)
#   2  reserved by bash for syntax errors
#   3  no update (up to date, upstream is older, or arm64 does not
#      have the new version yet)
#   4  update available but its dependencies changed in either
#      architecture, or could not be compared, and no --reviewed; prints
#      the new version on stdout and the report on stderr
readonly NO_UPDATE_STATUS=3
readonly NEEDS_REVIEW_STATUS=4
readonly USAGE="usage: check-update.sh [--apply [--reviewed]]"
# The Debian fields compared between releases.
readonly DEPENDENCY_FIELDS=(Pre-Depends Depends Recommends Suggests)

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

# Prints the apt Packages index for ARCHITECTURE (amd64 or arm64).
# Fails on network errors and HTTP errors such as 404 (curl -f).
# If INDEX_DIR is set, reads $INDEX_DIR/ARCHITECTURE instead, so tests
# can use saved indexes. ${INDEX_DIR:-} expands to "" when INDEX_DIR is
# unset, which set -u allows.
fetch_index() {
  local architecture="$1"

  if [[ -n "${INDEX_DIR:-}" ]]; then
    cat -- "$INDEX_DIR/$architecture"
  else
    curl -fsSL "${REPO_URL}/dists/stable/main/binary-${architecture}/Packages"
  fi
}

# sort -V compares version numbers as numbers: a plain sort would put
# 2.10.0 before 2.9.0 and pick the wrong latest version.
latest_version() {
  awk '/^Version:/ { print $2 }' | sort -V | tail -n 1
}

# Prints pkgver from the repo's .SRCINFO, or nothing if it has none.
current_version() {
  awk '$1 == "pkgver" { print $3; exit }' "$REPO_ROOT/.SRCINFO"
}

# Succeeds if version CANDIDATE is newer than version CURRENT.
version_gt() {
  local candidate="$1"
  local current="$2"
  local highest

  if [[ "$candidate" == "$current" ]]; then
    return 1
  fi

  highest="$(printf '%s\n' "$candidate" "$current" | sort -V | tail -n 1)"
  [[ "$highest" == "$candidate" ]]
}

# Succeeds if the apt Packages INDEX contains VERSION.
has_version() {
  local version="$1"
  local index="$2"
  grep -qxF "Version: $version" <<< "$index"
}

# Reads an apt Packages index on stdin and prints the value of FIELD
# (e.g. Depends) for VERSION. A version without FIELD prints nothing
# and exits 0. Exits 1 with a reason on stderr if VERSION is not in the
# index, or if FIELD wraps onto a continuation line, which this parser
# does not support.
package_field() {
  local version="$1"
  local field="$2"

  awk -v RS= -v FS='\n' -v version="$version" -v field="$field" '
    {
      is_target = 0
      for (i = 1; i <= NF; i++) {
        if ($i == "Version: " version) {
          is_target = 1
          break
        }
      }
      if (!is_target) {
        next
      }

      found = 1
      for (i = 1; i <= NF; i++) {
        if (index($i, field ": ") != 1) {
          continue
        }
        if ($(i + 1) ~ /^[ \t]/) {
          printf "%s of %s wraps onto a continuation line\n", field, version > "/dev/stderr"
          wrapped = 1
        } else {
          print substr($i, length(field) + 3)
        }
      }
    }
    END {
      if (!found) {
        printf "Version %s is not in the index\n", version > "/dev/stderr"
      }
      exit !found || wrapped
    }
  '
}

# Prints the items of a Debian dependency field VALUE, one per line,
# sorted. Items are separated by ", ", so alternatives such as
# "gnome-keyring | plasma-workspace" stay one item. Prints nothing for an
# empty VALUE.
dependency_items() {
  local value="$1"

  if [[ -n "$value" ]]; then
    awk -F', ' '{ for (i = 1; i <= NF; i++) print $i }' <<< "$value" \
      | LC_ALL=C sort
  fi
}

# Prints the changes from dependency field value OLD to NEW: "- item"
# for each removed item, then "+ item" for each added one.
dependency_changes() {
  local old_items
  local new_items

  # Captured first: a failure inside <(...) is invisible to set -e.
  old_items="$(dependency_items "$1")"
  new_items="$(dependency_items "$2")"

  # comm needs both lists sorted the same way it compares them, so it
  # runs in the C locale too.
  LC_ALL=C comm -23 <(lines "$old_items") <(lines "$new_items") \
    | sed 's/^/- /'
  LC_ALL=C comm -13 <(lines "$old_items") <(lines "$new_items") \
    | sed 's/^/+ /'
}

# Prints TEXT followed by a newline, or nothing if TEXT is empty. Plain
# printf would turn an empty TEXT into one empty line, which comm would
# then count as an item.
lines() {
  local text="$1"

  if [[ -n "$text" ]]; then
    printf '%s\n' "$text"
  fi
}

# Prints the review report for LATEST compared with CURRENT, from the
# amd64 and arm64 apt Packages INDEXes: the reasons a field couldn't be
# compared, then the changed items of each field. A field with the same
# changes on both architectures is listed once. Prints nothing if LATEST
# can be published without review.
dependency_report() {
  local current="$1"
  local latest="$2"
  local -A indexes=([amd64]="$3" [arm64]="$4")
  local -A comparable=([amd64]=1 [arm64]=1)
  local -A changes
  local -a blocks=()
  local reasons=""
  local i
  local architecture
  local field
  local old
  local new

  for architecture in amd64 arm64; do
    if ! has_version "$current" "${indexes[$architecture]}"; then
      comparable[$architecture]=0
    fi
  done
  if (( !comparable[amd64] && !comparable[arm64] )); then
    reasons+="$current is no longer in Anthropic's index, so the dependencies couldn't be compared."$'\n'
  else
    for architecture in amd64 arm64; do
      if (( !comparable[$architecture] )); then
        reasons+="$current is no longer in Anthropic's $architecture index, so its $architecture dependencies couldn't be compared."$'\n'
      fi
    done
  fi

  # The indexes are passed as arguments, not on stdin: stdin can only be
  # read once, and each package_field call needs a whole index. On
  # failure, package_field prints nothing on stdout, so 2>&1 captures
  # just its reason.
  for field in "${DEPENDENCY_FIELDS[@]}"; do
    for architecture in amd64 arm64; do
      changes[$architecture]=""
      if (( !comparable[$architecture] )); then
        continue
      fi
      if ! old="$(package_field "$current" "$field" <<< "${indexes[$architecture]}" 2>&1)"; then
        reasons+="$old, so it couldn't be compared."$'\n'
        continue
      fi
      if ! new="$(package_field "$latest" "$field" <<< "${indexes[$architecture]}" 2>&1)"; then
        reasons+="$new, so it couldn't be compared."$'\n'
        continue
      fi
      changes[$architecture]="$(dependency_changes "$old" "$new")"
    done

    if [[ -n "${changes[amd64]}" && "${changes[amd64]}" == "${changes[arm64]}" ]]; then
      blocks+=("$field (amd64, arm64):"$'\n'"${changes[amd64]}")
      continue
    fi
    for architecture in amd64 arm64; do
      if [[ -n "${changes[$architecture]}" ]]; then
        blocks+=("$field ($architecture):"$'\n'"${changes[$architecture]}")
      fi
    done
  done

  # A field that wraps on both architectures gives the same reason
  # twice. Print each reason once, then the blocks, one blank line apart.
  if [[ -n "$reasons" ]]; then
    blocks=("$(awk '!seen[$0]++' <<< "${reasons%$'\n'}")" "${blocks[@]}")
  fi
  for i in "${!blocks[@]}"; do
    if (( i > 0 )); then
      printf '\n'
    fi
    printf '%s\n' "${blocks[i]}"
  done
}

# Maps a Debian architecture name to its Arch Linux name.
arch_linux_name() {
  local architecture="$1"

  case "$architecture" in
    amd64) printf 'x86_64\n' ;;
    arm64) printf 'aarch64\n' ;;
    *) die "Unknown architecture: $architecture" ;;
  esac
}

# Prints the PKGBUILD line holding the checksum of VERSION's .deb for
# ARCHITECTURE, e.g. sha256sums_x86_64=('...'), taken from the apt
# Packages INDEX. Fails if the index has no valid SHA256 for it.
checksum_assignment() {
  local architecture="$1"
  local version="$2"
  local index="$3"
  local sum

  sum="$(package_field "$version" SHA256 <<< "$index")"
  [[ "$sum" =~ ^[0-9a-f]{64}$ ]] \
    || die "Invalid SHA256 for ${version} in the ${architecture} index: ${sum}"
  printf "sha256sums_%s=('%s')\n" "$(arch_linux_name "$architecture")" "$sum"
}

# Reads a PKGBUILD on stdin and prints it with its NAME=... line replaced
# by ASSIGNMENT (NAME=VALUE). Exits 1 if there is no such line: sed would
# silently change nothing and leave the old value in place.
replace_assignment() {
  local assignment="$1"
  local name="${assignment%%=*}"

  awk -v prefix="${name}=" -v assignment="$assignment" '
    index($0, prefix) == 1 {
      $0 = assignment
      found = 1
    }
    { print }
    END { exit !found }
  '
}

# Writes VERSION to the PKGBUILD, with pkgrel reset to 1 and the .deb
# checksums from the amd64 and arm64 INDEXes, then regenerates .SRCINFO.
apply_update() {
  local version="$1"
  local amd64_index="$2"
  local arm64_index="$3"
  local x86_64_checksum
  local aarch64_checksum
  local pkgbuild
  local srcinfo
  local assignment

  # Assigned first, not inside the for list below: a failure in a for
  # list's $(...) is ignored by set -e and the ERR trap.
  x86_64_checksum="$(checksum_assignment amd64 "$version" "$amd64_index")"
  aarch64_checksum="$(checksum_assignment arm64 "$version" "$arm64_index")"

  # Edit a copy in memory and write the file once, so a missing line
  # never leaves a half-updated PKGBUILD behind.
  pkgbuild="$(< "$REPO_ROOT/PKGBUILD")"
  for assignment in "pkgver=${version}" "pkgrel=1" \
    "$x86_64_checksum" "$aarch64_checksum"; do
    pkgbuild="$(replace_assignment "$assignment" <<< "$pkgbuild")" \
      || die "No ${assignment%%=*}= line in PKGBUILD"
  done
  printf '%s\n' "$pkgbuild" > "$REPO_ROOT/PKGBUILD"

  # Captured before writing: "makepkg > .SRCINFO" would empty .SRCINFO
  # first, and leave it empty if makepkg failed.
  srcinfo="$(cd "$REPO_ROOT" && makepkg --printsrcinfo)"
  printf '%s\n' "$srcinfo" > "$REPO_ROOT/.SRCINFO"

  printf 'Applied %s to PKGBUILD and .SRCINFO\n' "$version" >&2
}

main() {
  local apply=0
  local reviewed=0
  local arg
  local amd64_index
  local arm64_index
  local current
  local latest
  local report

  for arg in "$@"; do
    case "$arg" in
      --apply) apply=1 ;;
      --reviewed) reviewed=1 ;;
      *) die "Unknown option: $arg ($USAGE)" ;;
    esac
  done
  if (( reviewed && !apply )); then
    die "--reviewed only works with --apply ($USAGE)"
  fi

  current="$(current_version)"
  [[ -n "$current" ]] || die "No pkgver found in .SRCINFO"

  # The latest version comes from amd64, the architecture that gets run
  # and tested.
  amd64_index="$(fetch_index amd64)"
  latest="$(latest_version <<< "$amd64_index")"
  [[ -n "$latest" ]] || die "No Version found in the amd64 index"

  if [[ "$latest" == "$current" ]]; then
    printf 'Up to date\n' >&2
    exit "$NO_UPDATE_STATUS"
  fi

  if ! version_gt "$latest" "$current"; then
    printf 'Upstream is older: %s < %s\n' "$latest" "$current" >&2
    exit "$NO_UPDATE_STATUS"
  fi

  # Anthropic sometimes publishes one architecture first. Wait for the
  # next run instead of publishing a package that cannot build on arm64.
  arm64_index="$(fetch_index arm64)"
  if ! has_version "$latest" "$arm64_index"; then
    printf 'Update %s found, but arm64 not published yet\n' "$latest" >&2
    exit "$NO_UPDATE_STATUS"
  fi

  printf 'Update available: %s -> %s\n' "$current" "$latest" >&2
  printf '%s\n' "$latest"

  # Publish automatically only if the dependencies are unchanged.
  report="$(dependency_report "$current" "$latest" "$amd64_index" "$arm64_index")"

  # --reviewed never turns a 3 into a 0: those cases exited above.
  if [[ -n "$report" ]]; then
    printf '%s\n' "$report" >&2
    if [[ -n "${REPORT_FILE:-}" ]]; then
      printf '%s\n' "$report" > "$REPORT_FILE"
    fi
    (( reviewed )) || exit "$NEEDS_REVIEW_STATUS"
    printf 'Flagged for review, applying because of --reviewed\n' >&2
  fi

  if (( apply )); then
    apply_update "$latest" "$amd64_index" "$arm64_index"
  fi
}

main "$@"
