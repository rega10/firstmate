#!/usr/bin/env bash
# fm-contacts.sh - the home's contact book for outbound sends.
#
# Resolves a spoken person ("send it to el de sistemas") to exactly one listed
# contact, or reports that the match needs the owner's confirmation, so a send
# never goes to an address that is not in the book. This script only stores
# and resolves contacts; it never sends anything on any channel.
#
# Subcommands:
#   add --id <id> --name <name> [--alias <a>]... --role <text>
#       --trust <self|internal|external> --language <es|en>
#       [--email <addr>] [--telegram-chat-id <id>] [--imessage <addr>]
#       [--whatsapp <+phone>] [--preferred <channel>]... --added-by <text>
#                        Validate and store one contact, then print it as
#                        JSON. Refuses an invalid field, a duplicate id, or an
#                        address another contact already uses. Without
#                        --preferred, the channels that have an address are
#                        preferred in the order email, telegram, imessage,
#                        whatsapp.
#   list                 One tab-separated line per contact: id, name, role,
#                        trust, and the masked email. Never prints a full
#                        address.
#   show <id>            Print one full entry as JSON.
#   resolve <spoken words>...
#                        Normalize the words and print scored matches as one
#                        JSON object. Exit 0 for exactly one exact match, 2 for
#                        no match, 3 when a fuzzy or ambiguous result needs the
#                        owner's confirmation. The caller decides what to ask.
#
# Every other failure (usage, validation, an unreadable or unsupported book)
# exits 1 with one `fm-contacts:` line on stderr.
#
# The book is $FM_HOME/data/contacts.json (FM_DATA_OVERRIDE replaces
# $FM_HOME/data), home-private and gitignored; a missing file is an empty book.
# docs/configuration.md "Contact book" is the single owner of its schema, the
# trust meanings, the resolve tiers and exit codes, and the masking rule.
# FM_HOME falls back to the repo root when unset.
#
# The work is delegated to bin/fm-contacts.py (Python 3 standard library only),
# run isolated with `python3 -I` so no ambient Python path or module shadows it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-}"
if [ -z "$FM_HOME" ]; then
  FM_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

usage() {
  cat <<'EOF'
fm-contacts.sh add --id <id> --name <name> [--alias <a>]... --role <text>
                   --trust <self|internal|external> --language <es|en>
                   [--email <addr>] [--telegram-chat-id <id>] [--imessage <addr>]
                   [--whatsapp <+phone>] [--preferred <channel>]... --added-by <text>
fm-contacts.sh list
fm-contacts.sh show <id>
fm-contacts.sh resolve <spoken words>...
EOF
}

case "${1:-}" in
  add|list|show|resolve) ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  echo "fm-contacts: python3 required" >&2
  exit 1
fi
PY_BIN="$SCRIPT_DIR/fm-contacts.py"
if [ ! -f "$PY_BIN" ]; then
  echo "fm-contacts: $PY_BIN missing" >&2
  exit 1
fi

DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
FM_CONTACTS_FILE="$DATA/contacts.json" exec "$PY" -I "$PY_BIN" "$@"
