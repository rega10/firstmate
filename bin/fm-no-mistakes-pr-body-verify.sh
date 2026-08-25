#!/usr/bin/env bash
# fm-no-mistakes-pr-body-verify.sh - verify no-mistakes PR body evidence.
#
# The current structured comment is authoritative whenever it is present.
# Older no-mistakes releases emitted only deterministic Markdown step blocks;
# accept those blocks when review, test, and document visibly completed.
#
# Usage:
#   PR_BODY=... PR_AUTHOR=... PR_NUMBER=... fm-no-mistakes-pr-body-verify.sh
set -u

marker='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
prefix='<!-- no-mistakes-pipeline-attestation:v1 '
suffix=' -->'
body=${PR_BODY:-}
author=${PR_AUTHOR:-unknown}
number=${PR_NUMBER:-unknown}

fail_missing_signature() {
  {
    echo "::error::This PR was not raised through no-mistakes."
    echo
    echo "Contributions to this repository must be submitted via 'git push no-mistakes'."
    echo "That pipeline runs the required review/test/lint/CI steps and writes a"
    echo "deterministic '## Pipeline' section into the PR body containing:"
    echo
    echo "    $marker"
    echo
    echo "See CONTRIBUTING.md for setup and the full workflow."
    echo
    echo "PR author: $author"
  } >&2
  exit 1
}

fail_attestation() {
  {
    echo "::error::$1"
    echo
    echo "This repository requires review, test, and document to complete through no-mistakes."
    echo "Re-run the pipeline with 'git push no-mistakes' so those steps complete."
    echo "See CONTRIBUTING.md for setup and the full workflow."
    echo
    echo "PR author: $author"
  } >&2
  exit 1
}

printf '%s' "$body" | grep -qF -- "$marker" || fail_missing_signature
echo "Found no-mistakes signature in PR #${number} body."

case "$body" in
  *"$prefix"*)
    command -v jq >/dev/null 2>&1 \
      || fail_attestation "This check requires jq to parse no-mistakes pipeline step attestation, but jq was not found on the runner."
    rest=${body#*"$prefix"}
    case "$rest" in
      *"$suffix"*) json=${rest%%"$suffix"*} ;;
      *) fail_attestation "Structured no-mistakes pipeline step attestation is unparseable." ;;
    esac
    printf '%s' "$json" | jq -e . >/dev/null 2>&1 \
      || fail_attestation "Structured no-mistakes pipeline step attestation is unparseable."
    incomplete=
    for required in review test document; do
      status=$(printf '%s' "$json" | jq -r --arg step "$required" \
        '([(.steps | arrays | .[]) | select(.step == $step) | .status] | first // empty | select(. != "")) // "missing"')
      if [ "$status" != completed ]; then
        [ -z "$incomplete" ] || incomplete="$incomplete, "
        incomplete="${incomplete}${required}=${status}"
      fi
    done
    [ -z "$incomplete" ] \
      || fail_attestation "Required no-mistakes pipeline steps are not completed: $incomplete."
    echo "Pipeline step attestation is valid: review, test, and document are completed."
    exit 0
    ;;
esac

legacy_step_block() {
  printf '%s\n' "$body" | awk -v step="$1" '
    $0 == "## Pipeline" { in_pipeline=1 }
    in_pipeline && $0 == "<details>" { block=$0 ORS; target=0; next }
    in_pipeline && block != "" { block=block $0 ORS }
    in_pipeline && block != "" && index($0, "<summary>") && index($0, "**" step "**") { target=1 }
    in_pipeline && block != "" && $0 == "</details>" {
      if (target) { printf "%s", block; exit }
      block=""
      target=0
    }
  '
}

incomplete=
for required in Review Test Document; do
  block=$(legacy_step_block "$required")
  if [ -z "$block" ]; then
    status=missing
  elif printf '%s' "$block" | grep -Fq "<summary>✅ **${required}** - passed</summary>"; then
    status=completed
  elif printf '%s' "$block" | grep -Fqx '✅ Re-checked - no issues remain.'; then
    status=completed
  else
    status=incomplete
  fi
  if [ "$status" != completed ]; then
    [ -z "$incomplete" ] || incomplete="$incomplete, "
    normalized=$(printf '%s' "$required" | tr '[:upper:]' '[:lower:]')
    incomplete="${incomplete}${normalized}=${status}"
  fi
done

[ -z "$incomplete" ] \
  || fail_attestation "Required legacy no-mistakes pipeline steps are not completed: $incomplete."
echo "Legacy pipeline evidence is valid: review, test, and document are completed."
