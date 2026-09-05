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
# check wake for that project and later polls remain quiet. Registries up to
# 10,000 lines are scanned completely; a larger registry emits one disclosure
# wake instead. FM_PROJECT_POSTURE_TODAY is a test/diagnostic override.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REG="$DATA/projects.md"
CHECK_ID="project-posture-expiry"
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
    function find_lifecycle(value,    i, start, char, token) {
      lifecycle_start=0
      lifecycle_length=0
      start=0
      for (i=1; i<=length(value)+1; i++) {
        char=substr(value, i, 1)
        if (i <= length(value) && char !~ /[[:space:]]/) {
          if (start == 0) start=i
        } else if (start != 0) {
          token=substr(value, start, i-start)
          if (token == "parked" || token == "archived" || token == "active" || token ~ /^parked:/) {
            lifecycle_start=start
            lifecycle_length=i-start
            return 1
          }
          start=0
        }
      }
      return 0
    }
    $1 == "-" && $2 == target {
      line=$0
      has_annotation=($3 ~ /^\[/)
      if (has_annotation) {
        match(line, /\[[^]]*\]/)
        before=substr(line, 1, RSTART - 1)
        after=substr(line, RSTART + RLENGTH)
        annotation=substr(line, RSTART + 1, RLENGTH - 2)
        if (find_lifecycle(annotation)) {
          prefix=substr(annotation, 1, lifecycle_start - 1)
          suffix=substr(annotation, lifecycle_start + lifecycle_length)
          if (posture != "active") {
            annotation=prefix posture suffix
          } else if (prefix ~ /[^[:space:]]/) {
            if (substr(prefix, length(prefix), 1) ~ /[[:space:]]/) prefix=substr(prefix, 1, length(prefix) - 1)
            annotation=prefix suffix
          } else if (suffix ~ /[^[:space:]]/) {
            if (substr(suffix, 1, 1) ~ /[[:space:]]/) suffix=substr(suffix, 2)
            annotation=prefix suffix
          } else {
            annotation=""
          }
        } else if (posture != "active") {
          if (annotation ~ /[^[:space:]]/) {
            match(annotation, /[[:space:]]*$/)
            annotation=substr(annotation, 1, RSTART - 1) " " posture substr(annotation, RSTART)
          } else {
            annotation=posture annotation
          }
        }
        if (annotation !~ /[^[:space:]]/) {
          match(before, /^[[:space:]]*-[[:space:]]+[^[:space:]]+/)
          line=substr(before, 1, RLENGTH) after
        } else {
          line=before "[" annotation "]" after
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
  local today max_lines oversized marker_input due tmp combined descriptions first project date
  [ -f "$REG" ] || return 0
  today=${FM_PROJECT_POSTURE_TODAY:-$(date -u +%Y-%m-%d)}
  valid_date "$today" || return 0
  max_lines=10000
  oversized=$(awk -v max="$max_lines" 'NR > max { print 1; exit }' "$REG")
  mkdir -p "$STATE" || return 0
  marker_input=/dev/null
  [ -f "$RECEIPTS" ] && marker_input=$RECEIPTS
  due=$(mktemp "$STATE/.project-posture-due.XXXXXX") || return 0
  tmp=$(mktemp "$STATE/.project-posture-receipts.XXXXXX") || { rm -f -- "$due"; return 0; }
  if [ -n "$oversized" ]; then
    awk -F '\t' '
      $1 == "@registry-oversized" && $2 == "data/projects.md" { seen=1 }
      END { if (!seen) print "@registry-oversized\tdata/projects.md" }
    ' "$marker_input" > "$due"
  else
    awk -F '\t' -v registry="$REG" -v today="$today" '
      FILENAME != registry { seen[$1 SUBSEP $2]=1; next }
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
  fi
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
  if [ -n "$oversized" ]; then
    rm -f -- "$due"
    printf 'project posture registry oversized: data/projects.md exceeds %s lines\n' "$max_lines"
    return 0
  fi
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
    existing=$(line_posture "$(registry_line "$project")") || {
      echo "error: project has multiple lifecycle posture tokens: $project" >&2
      exit 1
    }
    if [ "$value" != active ]; then
      case "$existing" in
        active|parked|archived) ;;
        parked:*) valid_date "${existing#parked:}" || { echo "error: malformed parked-until date for $project: ${existing#parked:}" >&2; exit 1; } ;;
        *) echo "error: unknown lifecycle posture for $project: $existing" >&2; exit 1 ;;
      esac
    fi
    case "$value" in parked:*) arm_expiry_check || { echo "error: could not arm project posture expiry check" >&2; exit 1; } ;; esac
    output=$(write_registry "$project" "$value") || { echo "error: could not update project registry" >&2; exit 1; }
    printf '%s\n' "$output"
    if [ "$existing" != "$value" ]; then
      forget_receipt "$project" || { echo "error: could not reset project posture expiry receipt" >&2; exit 1; }
    fi
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
