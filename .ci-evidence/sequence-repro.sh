#!/usr/bin/env bash
set -eu
. ./bin/fm-remote-job-lib.sh
mkdir -p .ci-evidence/seq-state/.seq-claims
FM_REMOTE_JOB_STATE=$PWD/.ci-evidence/seq-state
FM_REMOTE_JOB_SEQ_CLAIMS=$FM_REMOTE_JOB_STATE/.seq-claims
for round in $(seq 1 20); do
  rm -rf "$FM_REMOTE_JOB_SEQ_CLAIMS" "$FM_REMOTE_JOB_STATE/seq"
  mkdir "$FM_REMOTE_JOB_SEQ_CLAIMS"
  pids=()
  for i in $(seq 1 50); do
    fm_remote_job_next_seq > "$FM_REMOTE_JOB_STATE/result-$i" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
  results=$(cat "$FM_REMOTE_JOB_STATE"/result-* | sort -n)
  [ "$results" = "$(seq 1 50)" ] || { printf 'failed round %s\n%s\n' "$round" "$results"; exit 1; }
done
printf 'all rounds passed\n'
