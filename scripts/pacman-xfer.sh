#!/usr/bin/env bash
# Download one package for pacman, trying every configured mirror.
#
# manjaro-tools points every chroot at a single mirror: mkchroot rewrites
# `Include = /etc/pacman.d/mirrorlist` to one `Server =` line built from
# build_mirror, and chroot-run overwrites the mirrorlist outright. So a
# mirrorlist with several servers in it does not survive, and pacman has
# nothing to fall back to when that one mirror stalls:
#
#   error: failed retrieving file 'linux618-6.18.49-1-x86_64.pkg.tar.zst'
#     from opencolo.mm.fcix.net : Operation too slow.
#     Less than 1 bytes/sec transferred the last 10 seconds
#   warning: too many errors from opencolo.mm.fcix.net, skipping for the
#     remainder of this transaction
#
# That killed four of fifteen editions in one run, each about twenty-five
# minutes in. XferCommand is the one hook that survives the rewrite, since
# it lives in [options] rather than in a repository section - so the
# failover goes here, swapping the host in the url pacman asks for.
#
# Usage, from pacman.conf: XferCommand = /path/pacman-xfer.sh %o %u
set -uo pipefail

readonly OUT="$1"
readonly URL="$2"

# Written by the action next to this script: one mirror base per line,
# the primary first. Absent or empty means there is nothing to fail over
# to, and the url is fetched as pacman asked for it.
MIRRORS_FILE="${PACMAN_XFER_MIRRORS:-$(dirname "${BASH_SOURCE[0]}")/build-mirrors}"

# --continue resumes a part-file from an earlier attempt; --speed-limit
# with --speed-time is what turns a stalled transfer into a failure this
# script can act on, rather than one that hangs until pacman gives up.
curl_opts=(
  --location --fail --silent --show-error
  --continue-at -
  --connect-timeout "${PACMAN_XFER_CONNECT_TIMEOUT:-15}"
  --speed-limit "${PACMAN_XFER_SPEED_LIMIT:-10000}"
  --speed-time "${PACMAN_XFER_SPEED_TIME:-20}"
)

fetch() {
  # a part-file left by a failed attempt may be truncated at a stall, and
  # --continue-at - on a different mirror would resume into it; only reuse
  # it for a retry against the same host
  curl "${curl_opts[@]}" -o "$OUT" "$1"
}

if [ ! -s "$MIRRORS_FILE" ]; then
  fetch "$URL"
  exit $?
fi

# pacman asks for <mirror-base>/<branch>/<repo>/<arch>/<file>; the part
# after the primary's base is what gets appended to each alternative
primary="$(head -n1 "$MIRRORS_FILE")"
suffix="${URL#"${primary%/}"}"

if [ "$suffix" = "$URL" ]; then
  # not a url this script knows how to redirect - a package from a custom
  # repo, say. Fetch what pacman asked for and let it judge the result.
  fetch "$URL"
  exit $?
fi

case "$URL" in
  *.sig)
    # pacman probes for a detached signature that our repositories do not
    # publish, and treats its absence as an answer. Asking every mirror
    # for it would spend four round trips to learn the same 404.
    fetch "$URL"
    exit $?
    ;;
esac

status=1
while read -r mirror; do
  [ -n "$mirror" ] || continue
  candidate="${mirror%/}${suffix}"

  fetch "$candidate"
  status=$?
  [ "$status" -eq 0 ] && exit 0

  # a stalled mirror leaves a partial file; the next mirror must not
  # resume into it
  rm -f "$OUT"
  echo "## xfer: ${mirror} failed with exit ${status}, trying the next mirror" >&2
done < "$MIRRORS_FILE"

echo "## xfer: no mirror served ${suffix#/}" >&2
exit "$status"
