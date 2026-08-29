#!/usr/bin/env bash
# Retrieve the image on the clipboard and save it as a real image file.
#
# Usage: grab-clipboard-image.sh [output-directory]
#
# The clipboard bridge socket is $CLIPBOARD_SOCKET when set, otherwise
# $HOME/.clipboard.sock. The home-directory default is what makes several
# users on one machine safe: each login's bridge (or forwarded socket) lives
# in its own home, so paths cannot collide, nobody can squat another user's
# name, and nobody can read another user's clipboard. An ssh remote forward
# reaches the same place as `RemoteForward /home/%r/.clipboard.sock <local>`.
#
# Prints two lines on success:
#   path: /abs/path/to/clipboard-<timestamp>.<ext>
#   type: PNG image data, 670 x 586, 8-bit/color RGBA, non-interlaced
#
# Exit codes are distinct so the caller can tell the failure modes apart:
#   3  unreachable      — no socket file, or nothing listening on it
#   4  no data          — connected fine, but the clipboard sent nothing
#   5  not an image     — clipboard holds something else
#   6  timed out        — connected, then the bridge never finished sending
# Other nonzero exits are environment errors (e.g. the default output
# directory exists but is owned by another user).

set -euo pipefail

SOCKET="${CLIPBOARD_SOCKET:-$HOME/.clipboard.sock}"

if [ ! -S "$SOCKET" ]; then
  echo "error: no clipboard socket at $SOCKET (the clipboard bridge is not running)" >&2
  exit 3
fi

if [ -n "${1:-}" ]; then
  OUTDIR="$1"
  mkdir -p "$OUTDIR"
else
  # The default must be per-user: a shared /tmp directory is owned by whoever
  # ran first, and everyone else's mktemp fails against its 0755.
  OUTDIR="${XDG_RUNTIME_DIR:-/tmp}/clipboard-grabs-$(id -u)"
  mkdir -p -m 0700 "$OUTDIR"
  if [ "$(stat -c %u "$OUTDIR" 2>/dev/null || stat -f %u "$OUTDIR")" != "$(id -u)" ]; then
    echo "error: $OUTDIR exists but belongs to another user; pass an output directory explicitly" >&2
    exit 1
  fi
fi

nc_err="$(mktemp)"
cleanup_err() { rm -f "$nc_err"; }
trap cleanup_err EXIT

raw="$(mktemp "$OUTDIR/.clipgrab-XXXXXX")"
trap 'rm -f "$raw" "$nc_err"' EXIT

# Redirecting stdin from /dev/null stops nc from holding the connection open
# waiting on input it will never get; the server sends the bytes and hangs up.
# The timeout is a backstop for a wedged bridge.
rc=0
timeout 10 nc -U "$SOCKET" </dev/null >"$raw" 2>"$nc_err" || rc=$?

if [ ! -s "$raw" ]; then
  # A socket file left behind by a dead bridge still passes the -S test above,
  # so "nothing came back" has to be split apart: a refused connection means the
  # bridge is gone and no amount of re-copying will help, whereas a clean
  # connection that sent nothing really does mean an empty clipboard. Reporting
  # the first as the second sends people hunting in the wrong place.
  if grep -qi "refused\|no such file\|connect" "$nc_err"; then
    echo "error: nothing is listening on $SOCKET — the socket file is stale and the clipboard bridge has stopped" >&2
    exit 3
  fi
  if [ "$rc" -eq 124 ]; then
    echo "error: timed out waiting for $SOCKET — the clipboard bridge is wedged" >&2
    exit 6
  fi
  echo "error: clipboard socket returned no data (clipboard is probably empty)" >&2
  exit 4
fi

mime="$(file -b --mime-type "$raw")"
case "$mime" in
  image/png)  ext=png  ;;
  image/jpeg) ext=jpg  ;;
  image/gif)  ext=gif  ;;
  image/webp) ext=webp ;;
  image/tiff) ext=tiff ;;
  image/bmp | image/x-ms-bmp) ext=bmp ;;
  *)
    echo "error: clipboard holds $mime, not an image" >&2
    exit 5
    ;;
esac

out="$OUTDIR/clipboard-$(date +%Y%m%d-%H%M%S-%N).$ext"
mv "$raw" "$out"
cleanup_err
trap - EXIT

echo "path: $out"
echo "type: $(file -b "$out")"
