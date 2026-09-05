#!/usr/bin/env bash
# bin/fm-landed-lib.sh - the single owner of the landed-work predicate.
# It answers one question for any worktree: has the worktree's committed work
# actually LANDED even though its commits are not reachable from any
# remote-tracking branch?
#
# bin/fm-teardown.sh and bin/fm-herdr-legacy-repair.sh both consume this so
# they cannot drift from one another. bin/fm-teardown.sh remains the owner of
# the COMPLETE landed-work decision it enforces (when the test runs, what
# --force may skip, the uncommitted-change test the caller runs first, and
# every refusal message); this lib holds only the shared reachability
# predicate, and every function takes explicit arguments and reads no caller
# globals.
#
# Landed means: a merged PR's head contains the current local work, OR the
# branch's content is already present in the up-to-date default branch (the
# squash-merge-then-delete-branch flow). The caller first proves the work is
# not already reachable from a remote (git log HEAD --not --remotes) and that
# there are no uncommitted changes; uncommitted work is never landed.
# Sourced only; not executable on its own.

# fm_landed_default_branch <project-dir>: the project's default branch name from
# origin/HEAD, falling back to a local main or master head.
fm_landed_default_branch() {  # <project-dir>
  local proj=$1 ref branch
  ref=$(git -C "$proj" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$proj" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

# Resolve the PR number for a worktree branch via gh-axi. Echoes the number on a
# single match and returns 0; returns non-zero on no match or any lookup failure,
# so the caller treats it as "no PR found" (fail-safe).
fm_landed_pr_number_from_branch() {  # <worktree> <branch>
  local wt=$1 branch=$2 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$( cd "$wt" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

# Extract the PR number from a recorded pr= URL or bare number.
fm_landed_pr_number_from_target() {  # <pr-url-or-number>
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

# Ensure the PR head commit object is present locally, fetching refs/pull/<n>/head
# when it is not, so the ancestry and patch-id checks below can run.
fm_landed_ensure_commit_object() {  # <worktree> <pr-target> <commit>
  local wt=$1 target=$2 commit=$3 n
  git -C "$wt" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  n=$(fm_landed_pr_number_from_target "$target") || return 1
  git -C "$wt" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$wt" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  git -C "$wt" cat-file -e "$commit^{commit}" 2>/dev/null
}

fm_landed_patch_id_for_commit() {  # <worktree> <commit>
  local wt=$1 commit=$2
  git -C "$wt" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

# True when every unpushed local commit's patch-id is present in the merged PR
# head, i.e. the local work landed in the PR even though the local commits were
# never pushed to a remote-tracking branch (a rebased or squashed merge).
fm_landed_unpushed_patches_are_in_pr_head() {  # <worktree> <pr-head>
  local wt=$1 pr_head=$2 current base pr_patch_ids commit patch_id unpushed
  current=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || return 1
  base=$(git -C "$wt" merge-base "$current" "$pr_head" 2>/dev/null) || return 1
  pr_patch_ids=$(
    git -C "$wt" log --format=%H "$base..$pr_head" -- 2>/dev/null \
      | while IFS= read -r commit; do
          fm_landed_patch_id_for_commit "$wt" "$commit"
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  [ -n "$pr_patch_ids" ] || return 1
  unpushed=$(git -C "$wt" log --format=%H HEAD --not --remotes -- 2>/dev/null) || return 1
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(fm_landed_patch_id_for_commit "$wt" "$commit") || return 1
    [ -n "$patch_id" ] || return 1
    printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

# Is the worktree's PR merged for local work contained in that PR? Resolves the
# PR from the passed pr= URL first, then from the branch name, and asks GitHub
# for the PR state, head, and canonical url. Returns non-zero when the PR is not
# merged, the current work is not contained in the PR head, no PR is found, or
# any gh error occurs - the caller then falls back to the content check. On
# success, echoes the canonical PR url (the passed url when it was non-empty,
# otherwise the resolved one) so a caller that started without a url can adopt
# it; a merged PR whose url cannot be resolved when none was passed is treated
# as not-landed.
fm_landed_pr_is_merged() {  # <worktree> <pr-url-or-empty> <branch> -> echoes canonical url on success
  local wt=$1 pr_url=$2 branch=$3 target view state remainder head resolved_url current landed=0
  if [ -n "$pr_url" ]; then
    target=$pr_url
  else
    target=$(fm_landed_pr_number_from_branch "$wt" "$branch") || return 1
  fi
  [ -n "$target" ] || return 1
  view=$(cd "$wt" && gh pr view "$target" --json state,headRefOid,url -q '.state + "\t" + .headRefOid + "\t" + .url' 2>/dev/null) || return 1
  state=${view%%$'\t'*}
  remainder=${view#*$'\t'}
  [ "$state" != "$view" ] || return 1
  head=${remainder%%$'\t'*}
  resolved_url=${remainder#*$'\t'}
  [ "$head" != "$remainder" ] || return 1
  case "$state" in
    MERGED|merged) ;;
    *) return 1 ;;
  esac
  [ -n "$head" ] || return 1
  fm_landed_ensure_commit_object "$wt" "$target" "$head" || return 1
  current=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || return 1
  if git -C "$wt" merge-base --is-ancestor "$current" "$head" 2>/dev/null; then
    landed=1
  elif fm_landed_unpushed_patches_are_in_pr_head "$wt" "$head"; then
    landed=1
  fi
  [ "$landed" = 1 ] || return 1
  if [ -n "$pr_url" ]; then
    printf '%s' "$pr_url"
  else
    [ -n "$resolved_url" ] || return 1
    printf '%s' "$resolved_url"
  fi
}

# Is the branch's content already present in the up-to-date default branch? Fetches
# first, then 3-way merges the default branch with HEAD: when HEAD introduces nothing
# the default branch does not already contain (e.g. its change landed via squash) the
# merged tree equals the default branch's tree. This isolates branch-only changes, so
# unrelated commits the default branch gained past the merge-base do not count as
# "added". Returns non-zero when inconclusive (no default ref, or a merge conflict),
# so the caller refuses rather than guesses.
fm_landed_content_in_default() {  # <worktree> <project-dir>
  local wt=$1 proj=$2 name ref default_tree merged_tree
  name=$(fm_landed_default_branch "$proj") || return 1
  if git -C "$wt" remote get-url origin >/dev/null 2>&1; then
    git -C "$wt" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    ref="refs/remotes/origin/$name"
  elif git -C "$wt" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$wt" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$wt" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$default_tree" ]
}

# Has the worktree's committed work actually LANDED, though its commits are not
# reachable from any remote-tracking branch? True when a merged PR proves the
# current local work is contained in the PR head, OR the content is already in the
# default branch (fallback, which also covers the no-PR and gh-error paths). False
# only for genuinely unlanded work. The merged-PR url is not returned here; a
# caller that also needs the resolved url calls fm_landed_pr_is_merged directly.
fm_landed_work_is_landed() {  # <worktree> <project-dir> <pr-url-or-empty> <branch>
  local wt=$1 proj=$2 pr_url=$3 branch=$4
  fm_landed_pr_is_merged "$wt" "$pr_url" "$branch" >/dev/null && return 0
  fm_landed_content_in_default "$wt" "$proj"
}
