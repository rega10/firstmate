#!/usr/bin/env bash
# fm-deliver.sh - send files to one listed contact on the contact's preferred
# channel, after a preflight, and record every attempt in the send log.
#
# Usage:
#   fm-deliver.sh <contact-id> <file>... --order-file <path>
#                 [--confirm-file <path>] [--note-file <path>]
#                 [--allow-away] [--dry-run]
#
#   <contact-id>        An id in the contact book (bin/fm-contacts.sh). Any
#                       other value, a raw address included, is refused.
#   --order-file        The owner's exact words that ordered this send.
#   --confirm-file      The owner's exact confirmation words; required for an
#                       external contact.
#   --note-file         The covering text; without it a short default in the
#                       contact's language names the files.
#   --allow-away        Send although away or quiet mode is active; only when
#                       the owner's away words name this send.
#   --dry-run           Run every check, print the confirmation card, and
#                       exit 0 without sending or logging. Skips only the
#                       confirmation check, because the card comes first.
#
# Exit codes: 0 sent (or dry run passed), 1 usage or configuration error,
# 2 contact not in the book, 3 confirmation missing, 4 away or quiet mode,
# 5 preflight refused, 6 no implemented channel, 7 the mail plane or the
# sharing command failed.
#
# Email goes through bin/fm-mail.sh with the environment passed through
# unchanged, so the password arrives only through
# `av inject +FM_MAIL_PASS -- bin/fm-deliver.sh ...`; this tool never reads,
# prints, or logs it. Files that together exceed the attachment cap go as
# signed 7-day links in the mail body, made by the sharing command named in
# FM_DELIVER_SHARE_CMD, which also runs with the environment unchanged. Every attempt that passed argument parsing appends one
# JSON line to $FM_HOME/data/outbound/sends.jsonl (FM_DATA_OVERRIDE replaces
# $FM_HOME/data). docs/configuration.md "Outbound send" owns the preflight
# rules, link mode, the log format, and away-mode enforcement; the agent-only
# `outbound-send` skill owns confirmation and away authorization rules.
#
# Optional settings, from the environment or else the home's .env (env wins):
# FM_DELIVER_MAX_BYTES (default 104857600, total file bytes of one send),
# FM_MAIL_MAX_ATTACH_BYTES (the mail plane's attachment cap, default
# 20971520), and FM_DELIVER_SHARE_CMD (the sharing command for link mode, a
# path relative to FM_HOME unless absolute; unset refuses an oversized send).
# FM_HOME falls back to the repo root when unset.
#
# The work is delegated to bin/fm-deliver.py (Python 3 standard library only),
# run isolated with `python3 -I` so no ambient Python path or module shadows it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-}"
if [ -z "$FM_HOME" ]; then
  FM_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

usage() {
  cat <<'EOF'
fm-deliver.sh <contact-id> <file>... --order-file <path>
              [--confirm-file <path>] [--note-file <path>]
              [--allow-away] [--dry-run]

Sends the files to one listed contact on the first preferred channel that has
an address (email today), after the preflight, and appends one line to
data/outbound/sends.jsonl. Files above the mail attachment cap go as signed
7-day links made by FM_DELIVER_SHARE_CMD. Run a real send as
  av inject +FM_MAIL_PASS -- bin/fm-deliver.sh ...
Exit codes: 0 sent or dry run passed, 1 usage or configuration error,
2 contact not listed, 3 confirmation missing, 4 away or quiet mode,
5 preflight refused, 6 no implemented channel, 7 the mail plane or the
sharing command failed.
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  '')
    usage >&2
    exit 1
    ;;
esac

PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  echo "fm-deliver: python3 required" >&2
  exit 1
fi
PY_BIN="$SCRIPT_DIR/fm-deliver.py"
if [ ! -f "$PY_BIN" ]; then
  echo "fm-deliver: $PY_BIN missing" >&2
  exit 1
fi

# Away and quiet mode: the away-posture record (owned by fm-afk-contract.sh)
# backs both postures, and state/.afk is the daemon flag either posture sets.
# shellcheck source=bin/fm-afk-contract.sh
. "$SCRIPT_DIR/fm-afk-contract.sh"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
AWAY=""
if fm_afk_contract_present "$STATE"; then
  AWAY="$(fm_afk_contract_path "$STATE")"
elif [ -e "$STATE/.afk" ]; then
  AWAY="$STATE/.afk"
fi

# Non-secret settings: the environment wins, and the home's .env fills the rest.
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
for key in FM_DELIVER_MAX_BYTES FM_MAIL_MAX_ATTACH_BYTES FM_DELIVER_SHARE_CMD; do
  if [ -z "${!key:-}" ]; then
    value="$(fmx_env_get "$key" "$FM_HOME/.env")"
    if [ -n "$value" ]; then
      export "$key=$value"
    fi
  fi
done

DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
FM_DELIVER_HOME="$FM_HOME" \
FM_DELIVER_DATA="$DATA" \
FM_DELIVER_AWAY="$AWAY" \
FM_DELIVER_MAIL="$SCRIPT_DIR/fm-mail.sh" \
FM_DELIVER_CONTACTS_PY="$SCRIPT_DIR/fm-contacts.py" \
  exec "$PY" -I "$PY_BIN" "$@"
