#!/usr/bin/env bash
# Bind an intentional custom watcher check to its current bytes.
# Usage: fm-check-register.sh <id> [--interval <seconds>]
# --interval records state/<id>.check-interval so the watcher runs this check
# on its own cadence instead of the shared FM_CHECK_INTERVAL sweep (a positive
# whole number; the watcher floors it at FM_POLL). Without it, an interval file
# already present is left as it is.
# Retire with fm-check-unregister.sh <id>; do not hand-compose an rm.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

ID=${1-}
INTERVAL_SECONDS=
case "$#" in
  1) ;;
  3)
    [ "$2" = --interval ] && INTERVAL_SECONDS=$3
    case "$INTERVAL_SECONDS" in
      ''|*[!0-9]*) INTERVAL_SECONDS=bad ;;
      *) [ "${#INTERVAL_SECONDS}" -le 9 ] && [ "$((10#$INTERVAL_SECONDS))" -gt 0 ] || INTERVAL_SECONDS=bad ;;
    esac
    ;;
  *) INTERVAL_SECONDS=bad ;;
esac
if [ "$INTERVAL_SECONDS" = bad ] || ! fm_pr_task_id_valid "$ID"; then
  echo "error: invalid custom check registration" >&2
  exit 2
fi
CHECK="$STATE/$ID.check.sh"
TRUST="$STATE/$ID.check-trust"
INTERVAL_FILE="$STATE/$ID.check-interval"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: state directory is unavailable" >&2; exit 1; }
[ -f "$CHECK" ] && [ ! -L "$CHECK" ] || { echo "error: custom check is unavailable" >&2; exit 1; }
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
fm_pr_private_file_valid "$CHECK" 700 "$STATE_DEVICE" \
  || { echo "error: custom check is unavailable" >&2; exit 1; }
fm_pr_regular_destination_on_device_or_absent "$TRUST" "$STATE_DEVICE" \
  || { echo "error: custom check trust path is unavailable" >&2; exit 1; }
HASH=$(fm_custom_check_sha256 "$CHECK") || { echo "error: custom check hash is unavailable" >&2; exit 1; }
umask 077
TMP=$(mktemp "$STATE/.fm-custom-check-trust.XXXXXX") || exit 1
trap '[ -z "$TMP" ] || rm -f -- "$TMP"' EXIT HUP INT TERM
printf '%s\n%s\n' fm-custom-check-v1 "$HASH" > "$TMP" || exit 1
chmod 0600 "$TMP" || exit 1
fm_pr_regular_destination_on_device_or_absent "$TRUST" "$STATE_DEVICE" || exit 1
mv -f -- "$TMP" "$TRUST" || exit 1
TMP=
fm_custom_check_registered "$STATE" "$ID" || { rm -f -- "$TRUST"; exit 1; }
if [ -n "$INTERVAL_SECONDS" ]; then
  fm_pr_regular_destination_on_device_or_absent "$INTERVAL_FILE" "$STATE_DEVICE" \
    || { rm -f -- "$TRUST"; echo "error: custom check interval path is unavailable" >&2; exit 1; }
  TMP=$(mktemp "$STATE/.fm-custom-check-interval.XXXXXX") || { rm -f -- "$TRUST"; exit 1; }
  if ! { printf '%s\n' "$((10#$INTERVAL_SECONDS))" > "$TMP" \
    && chmod 0600 "$TMP" && mv -f -- "$TMP" "$INTERVAL_FILE"; }; then
    rm -f -- "$TMP" "$TRUST"
    echo "error: custom check interval could not be recorded" >&2
    exit 1
  fi
  TMP=
fi
printf 'registered: state/%s.check.sh\n' "$ID"
