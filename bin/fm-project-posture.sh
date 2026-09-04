#!/usr/bin/env bash
# Read or atomically change a project's lifecycle posture in data/projects.md.
# This is the only writer of the optional parked, parked:YYYY-MM-DD, or archived
# token inside a registry line's existing annotation. It never adds, removes,
# reorders, or otherwise changes the delivery-mode or +yolo tokens.
#
# Usage:
#   fm-project-posture.sh get <project>
#   fm-project-posture.sh set <project> <parked|parked:YYYY-MM-DD|archived|active>
#   fm-project-posture.sh clear <project>
#
# `get` prints the registered token, defaulting to active when it is absent.
# `set ... active` and `clear` both remove the lifecycle token. Mutations print
# the exact previous and current registry lines, so the replaced line remains in
# command output as the operator's backup. The file publication is an atomic
# same-directory replace.
#
# A dated park arms state/project-posture-expiry.check.sh through
# fm-check-register.sh. The check is finite and local-only. On or after the date
# it records a private receipt before printing one line, so the watcher emits one
# check wake for that project and later polls remain quiet. FM_PROJECT_POSTURE_TODAY
# and FM_PROJECT_POSTURE_MAX_LINES are test/diagnostic overrides.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REG="$DATA/projects.md"
CHECK_ID=project-posture-expiry
CHECK="$STATE/$CHECK_ID.check.sh"
TRUST="$STATE/$CHECK_ID.check-trust"
RECEIPTS="$STATE/.project-posture-expiry-fired"

usage() {
  cat <<'EOF'
usage: fm-project-posture.sh get <project>
       fm-project-posture.sh set <project> <parked|parked:YYYY-MM-DD|archived|active>
       fm-project-posture.sh clear <project>
EOF
}

valid_date() { # <YYYY-MM-DD>
  local value=$1 normalized
  case "$value" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  normalized=$(date -j -f '%Y-%m-%d' "$value" '+%Y-%m-%d' 2>/dev/null \
    || date -d "$value" '+%Y-%m-%d' 2>/dev/null) || return 1
  [ "$normalized" = "$value" ]
}

registry_line_count() { # <project>
  awk -v n="$1" '$1 == "-" && $2 == n { count++ } END { print count + 0 }' "$REG"
}

registry_line() { # <project>
  awk -v n="$1" '$1 == "-" && $2 == n { print; exit }' "$REG"
}

line_posture() { # <registry-line>
  printf '%s\n' "$1" | awk '
    {
      posture=""; count=0
      if ($3 ~ /^\[/) {
        annotation=""
        for (i=3; i<=NF; i++) {
          annotation = annotation (annotation == "" ? "" : " ") $i
          if ($i ~ /\]$/) break
        }
        gsub(/^\[|\]$/, "", annotation)
        n=split(annotation, token, /[[:space:]]+/)
        for (i=1; i<=n; i++) {
          if (token[i] == "parked" || token[i] == "archived" || token[i] == "active" || token[i] ~ /^parked:/) {
            posture=token[i]
            count++
          }
        }
      }
      if (count > 1) exit 3
      print (posture == "" ? "active" : posture)
    }
  '
}

project_preflight() { # <project>
  local count=$1
  [ -f "$REG" ] || { echo "error: project registry unavailable: $REG" >&2; return 1; }
  count=$(registry_line_count "$1") || return 1
  case "$count" in
    1) return 0 ;;
    0) echo "error: project not registered: $1" >&2 ;;
    *) echo "error: project is registered more than once: $1" >&2 ;;
  esac
  return 1
}

file_mode() { # <path>
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null || printf '600\n'
}

write_registry() { # <project> <active|parked|parked:date|archived>
  local project=$1 posture=$2 tmp mode previous current
  previous=$(registry_line "$project") || return 1
  tmp=$(mktemp "$DATA/.projects.md.XXXXXX") || return 1
  mode=$(file_mode "$REG")
  trap 'rm -f -- "$tmp"' EXIT HUP INT TERM
  if ! awk -v target="$project" -v posture="$posture" '
    function append(value, token) { return value == "" ? token : value " " token }
    $1 == "-" && $2 == target {
      line=$0
      has_annotation=($3 ~ /^\[/)
      if (has_annotation) {
        match(line, /\[[^]]*\]/)
        before=substr(line, 1, RSTART - 1)
        after=substr(line, RSTART + RLENGTH)
        annotation=substr(line, RSTART + 1, RLENGTH - 2)
        kept=""
        n=split(annotation, token, /[[:space:]]+/)
        for (i=1; i<=n; i++) {
          if (token[i] == "parked" || token[i] == "archived" || token[i] == "active" || token[i] ~ /^parked:/) continue
          if (token[i] != "") kept=append(kept, token[i])
        }
        if (posture != "active") kept=append(kept, posture)
        if (kept == "") {
          match(before, /^[[:space:]]*-[[:space:]]+[^[:space:]]+/)
          line=substr(before, 1, RLENGTH) after
        } else {
          line=before "[" kept "]" after
        }
      } else if (posture != "active") {
        match(line, /^[[:space:]]*-[[:space:]]+[^[:space:]]+/)
        line=substr(line, 1, RLENGTH) " [" posture "]" substr(line, RLENGTH + 1)
      }
      print line
      next
    }
    { print }
  ' "$REG" > "$tmp"; then
    rm -f -- "$tmp"
    trap - EXIT HUP INT TERM
    return 1
  fi
  chmod "$mode" "$tmp" 2>/dev/null || chmod 0600 "$tmp" || {
    rm -f -- "$tmp"
    trap - EXIT HUP INT TERM
    return 1
  }
  mv -f -- "$tmp" "$REG" || {
    rm -f -- "$tmp"
    trap - EXIT HUP INT TERM
    return 1
  }
  trap - EXIT HUP INT TERM
  current=$(registry_line "$project") || return 1
  printf 'previous: %s\ncurrent: %s\n' "$previous" "$current"
}

forget_receipt() { # <project>
  local project=$1 tmp
  [ -f "$RECEIPTS" ] || return 0
  tmp=$(mktemp "$STATE/.project-posture-receipts.XXXXXX") || return 1
  awk -F '\t' -v n="$project" '$1 != n' "$RECEIPTS" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECEIPTS"
}

registry_has_dated_park() {
  awk '
    {
      fields=split($0, field, /[[:space:]]+/)
    }
    fields >= 3 && field[1] == "-" && field[3] ~ /^\[/ {
      annotation=""
      for (i=3; i<=fields; i++) {
        annotation = annotation (annotation == "" ? "" : " ") field[i]
        if (field[i] ~ /\]$/) break
      }
      gsub(/^\[|\]$/, "", annotation)
      n=split(annotation, token, /[[:space:]]+/)
      for (i=1; i<=n; i++) if (token[i] ~ /^parked:[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) found=1
    }
    END { exit found ? 0 : 1 }
  ' "$REG"
}

arm_expiry_check() {
  local tmp
  mkdir -p "$STATE" || return 1
  tmp=$(mktemp "$STATE/.project-posture-check.XXXXXX") || return 1
  printf '#!/usr/bin/env bash\nexec env FM_ROOT_OVERRIDE=%q FM_HOME=%q FM_DATA_OVERRIDE=%q FM_STATE_OVERRIDE=%q %q _check-expiry\n' \
    "$FM_ROOT" "$FM_HOME" "$DATA" "$STATE" "$SCRIPT_DIR/fm-project-posture.sh" > "$tmp" || {
      rm -f -- "$tmp"
      return 1
    }
  chmod 0700 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$CHECK" || { rm -f -- "$tmp"; return 1; }
  FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null
}

sync_expiry_check() {
  if registry_has_dated_park; then
    arm_expiry_check
  else
    rm -f -- "$CHECK" "$TRUST" "$RECEIPTS"
  fi
}

check_expiry() {
  local today max_lines marker_input due tmp combined descriptions first project date
  [ -f "$REG" ] || return 0
  today=${FM_PROJECT_POSTURE_TODAY:-$(date -u +%Y-%m-%d)}
  valid_date "$today" || return 0
  max_lines=${FM_PROJECT_POSTURE_MAX_LINES:-1000}
  case "$max_lines" in ''|*[!0-9]*|0) max_lines=1000 ;; esac
  mkdir -p "$STATE" || return 0
  marker_input=/dev/null
  [ -f "$RECEIPTS" ] && marker_input=$RECEIPTS
  due=$(mktemp "$STATE/.project-posture-due.XXXXXX") || return 0
  tmp=$(mktemp "$STATE/.project-posture-receipts.XXXXXX") || { rm -f -- "$due"; return 0; }
  awk -F '\t' -v registry="$REG" -v today="$today" -v max="$max_lines" '
    FILENAME != registry { seen[$1 SUBSEP $2]=1; next }
    FNR > max { next }
    {
      fields=split($0, field, /[[:space:]]+/)
    }
    fields >= 3 && field[1] == "-" && field[3] ~ /^\[/ {
      annotation=""
      for (i=3; i<=fields; i++) {
        annotation = annotation (annotation == "" ? "" : " ") field[i]
        if (field[i] ~ /\]$/) break
      }
      gsub(/^\[|\]$/, "", annotation)
      n=split(annotation, token, /[[:space:]]+/)
      for (i=1; i<=n; i++) {
        if (token[i] ~ /^parked:[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) {
          date=substr(token[i], 8)
          if (date <= today && !seen[field[2] SUBSEP date]) print field[2] "\t" date
        }
      }
    }
  ' "$marker_input" "$REG" > "$due"
  if [ ! -s "$due" ]; then
    rm -f -- "$due" "$tmp"
    return 0
  fi
  combined=$(mktemp "$STATE/.project-posture-combined.XXXXXX") || { rm -f -- "$due" "$tmp"; return 0; }
  { [ -f "$RECEIPTS" ] && cat "$RECEIPTS"; cat "$due"; } > "$combined"
  awk '!seen[$0]++' "$combined" > "$tmp" || { rm -f -- "$due" "$tmp" "$combined"; return 0; }
  chmod 0600 "$tmp" || { rm -f -- "$due" "$tmp" "$combined"; return 0; }
  mv -f -- "$tmp" "$RECEIPTS" || { rm -f -- "$due" "$tmp" "$combined"; return 0; }
  rm -f -- "$combined"
  descriptions=""
  first=1
  while IFS=$'\t' read -r project date; do
    [ -n "$project" ] || continue
    if [ "$first" -eq 0 ]; then descriptions="$descriptions, "; fi
    descriptions="${descriptions}${project} (parked until ${date})"
    first=0
  done < "$due"
  rm -f -- "$due"
  [ -n "$descriptions" ] && printf 'project posture expired: %s\n' "$descriptions"
}

case "${1:-}" in
  _check-expiry)
    [ "$#" -eq 1 ] || exit 2
    check_expiry
    exit 0
    ;;
  get)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    project_preflight "$2" || exit 1
    value=$(line_posture "$(registry_line "$2")") || {
      echo "error: project has multiple lifecycle posture tokens: $2" >&2
      exit 1
    }
    case "$value" in
      active|parked|archived) ;;
      parked:*) valid_date "${value#parked:}" || { echo "error: malformed parked-until date for $2: ${value#parked:}" >&2; exit 1; } ;;
      *) echo "error: unknown lifecycle posture for $2: $value" >&2; exit 1 ;;
    esac
    printf '%s\n' "$value"
    ;;
  set)
    [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    project=$2
    value=$3
    case "$value" in
      active|parked|archived) ;;
      parked:*) valid_date "${value#parked:}" || { echo "error: malformed parked-until date: ${value#parked:}" >&2; exit 2; } ;;
      *) echo "error: unknown lifecycle posture: $value" >&2; exit 2 ;;
    esac
    project_preflight "$project" || exit 1
    if [ "$value" != active ]; then
      existing=$(line_posture "$(registry_line "$project")") || {
        echo "error: project has multiple lifecycle posture tokens: $project" >&2
        exit 1
      }
      case "$existing" in
        active|parked|archived) ;;
        parked:*) valid_date "${existing#parked:}" || { echo "error: malformed parked-until date for $project: ${existing#parked:}" >&2; exit 1; } ;;
        *) echo "error: unknown lifecycle posture for $project: $existing" >&2; exit 1 ;;
      esac
    fi
    case "$value" in parked:*) arm_expiry_check || { echo "error: could not arm project posture expiry check" >&2; exit 1; } ;; esac
    output=$(write_registry "$project" "$value") || { echo "error: could not update project registry" >&2; exit 1; }
    printf '%s\n' "$output"
    forget_receipt "$project" || { echo "error: could not reset project posture expiry receipt" >&2; exit 1; }
    sync_expiry_check || { echo "error: could not reconcile project posture expiry check" >&2; exit 1; }
    ;;
  clear)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    project=$2
    project_preflight "$project" || exit 1
    output=$(write_registry "$project" active) || { echo "error: could not update project registry" >&2; exit 1; }
    printf '%s\n' "$output"
    forget_receipt "$project" || { echo "error: could not reset project posture expiry receipt" >&2; exit 1; }
    sync_expiry_check || { echo "error: could not reconcile project posture expiry check" >&2; exit 1; }
    ;;
  *) usage >&2; exit 2 ;;
esac
