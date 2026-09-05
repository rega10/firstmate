def fm_project_record($repo; $projects):
  if $repo == null or $repo == "" then null
  else first($projects[]? | select(.name == $repo or .repo == $repo)) // null
  end;

def fm_project_lifecycle($repo; $projects; $today):
  (fm_project_record($repo; $projects)) as $project
  | if $project == null then
      {posture:"active", archived:false, parked:false, rank:0, reason:null, name:null, parked_until:null}
    elif $project.posture == "archived" then
      {posture:"archived", archived:true, parked:false, rank:3, reason:null, name:$project.name, parked_until:null}
    elif $project.posture == "parked" and ($project.parked_until == null or $project.parked_until > $today) then
      {posture:"parked", archived:false, parked:true,
       rank:(if $project.parked_until == null then 1 else 2 end),
       reason:(if $project.parked_until == null then "project parked"
               else "project parked until " + $project.parked_until end),
       name:$project.name, parked_until:$project.parked_until}
    else
      {posture:($project.posture // "active"), archived:false, parked:false,
       rank:0, reason:null, name:$project.name, parked_until:$project.parked_until}
    end;

def fm_merge_by_id($base; $extra):
  reduce $extra[] as $row ($base;
    if any(.[]; .id == $row.id) then . else . + [$row] end);

def fm_secondmate_summary_at($today):
  (.projects // []) as $projects
  | (has("projects") and (has("lifecycle_inventory") | not)) as $legacy_summary
  | (((.active_children // []) + (.holds // []) + (.decisions_open // [])
      + (.queued // []) + (.landed // []) + (.endpoints // [])
      + (.lifecycle_inventory // []))) as $identified_rows
  | def resolved_repo($row):
      $row.repo // first($identified_rows[]?
        | select(.id == $row.id and .repo != null and .repo != "") | .repo) // null;
  def with_resolved_repo:
      . as $row | resolved_repo($row) as $repo
      | if $repo == null or $repo == "" then . else . + {repo:$repo} end;
  ([{surface:"active_children",rows:(.active_children // [])},
       {surface:"holds",rows:(.holds // [])},
       {surface:"decisions_open",rows:(.decisions_open // [])},
       {surface:"queued",rows:(.queued // [])},
       {surface:"landed",rows:(.landed // [])},
       {surface:"endpoints",rows:(.endpoints // [])}]
      | [.[] as $group
         | $group.rows[]?
         | select($legacy_summary and resolved_repo(.) == null)
         | {surface:$group.surface,id}]) as $unidentified_legacy_rows
  | .active_children |= map(with_resolved_repo)
  | .holds |= map(with_resolved_repo)
  | .decisions_open |= map(with_resolved_repo)
  | .queued |= map(with_resolved_repo
      | if $legacy_summary and (has("backlog_state") | not) then
          . + {backlog_state:"queued"}
        else . end)
  | .landed |= map(with_resolved_repo)
  | .endpoints |= map(with_resolved_repo)
  | ([
      (.active_children[]?
       | select($legacy_summary and fm_project_lifecycle(.repo; $projects; $today).parked)
       | {id,title:(.doing // .id),repo,backlog_state:"in_flight",current_role:"active",
          child_state:(.state // "working"),child_source:(.source // null),
          child_doing:(.doing // null),captain_actionable:false}),
      (.holds[]?
       | select($legacy_summary and fm_project_lifecycle(.repo; $projects; $today).parked)
       | {id,title:(.title // .id),repo,backlog_state:"in_flight",current_role:"held",
          child_state:"paused",child_source:(.source // null),child_doing:(.reason // null),
          blocked_by:(.blocked_by // null),blocked_by_ids:(.blocked_by_ids // []),
          unresolved_blocker_ids:(.unresolved_blocker_ids // []),captain_actionable:false}),
      (.decisions_open[]?
       | select($legacy_summary and fm_project_lifecycle(.repo; $projects; $today).parked)
       | {id,title:(.summary // .id),repo,backlog_state:"in_flight",current_role:"held",
          child_state:"paused",child_source:(.source // null),child_doing:(.reason // null),
          hold_reason:(.reason // null),hold_until:(.hold_until // null),
          hold_bucket:(.hold_bucket // null),hold_age_days:(.hold_age_days // null),
          captain_actionable:true})
    ]) as $legacy_parked
  | {active_children:(.active_children | length),holds:(.holds | length),
     decisions_open:(.decisions_open | length),queued:(.queued | length),
     landed:(.landed | length),endpoints:(.endpoints | length)} as $before
  | ([((.active_children // []), (.holds // []), (.decisions_open // []),
       (.queued // []), (.landed // []), (.endpoints // []), (.lifecycle_inventory // []))[]?
      | fm_project_lifecycle(.repo; $projects; $today)
      | select(.archived)
      | .name]
     | map(select(. != null)) | unique) as $archived_projects
  | (first((.omitted // [])[]? | select(.surface == "project_lifecycle")) // null) as $lifecycle_omission
  | .active_children |= map(select(fm_project_lifecycle(.repo; $projects; $today)
      | (.archived or ($legacy_summary and .parked)) | not))
  | .holds |= map(select(fm_project_lifecycle(.repo; $projects; $today)
      | (.archived or ($legacy_summary and .parked)) | not))
  | .decisions_open |= map(select(fm_project_lifecycle(.repo; $projects; $today)
      | (.archived or ($legacy_summary and .parked)) | not))
  | .queued |= map(select(fm_project_lifecycle(.repo; $projects; $today).archived | not))
  | .landed |= map(select(fm_project_lifecycle(.repo; $projects; $today).archived | not))
  | .endpoints |= map(select(fm_project_lifecycle(.repo; $projects; $today).archived | not))
  | .counts.active_children = ([0, ((.counts.active_children // $before.active_children)
      - ($before.active_children - (.active_children | length)))] | max)
  | .counts.holds = ([0, ((.counts.holds // $before.holds)
      - ($before.holds - (.holds | length)))] | max)
  | .counts.decisions_open = ([0, ((.counts.decisions_open // $before.decisions_open)
      - ($before.decisions_open - (.decisions_open | length)))] | max)
  | .counts.queued = ([0, ((.counts.queued // $before.queued)
      - ($before.queued - (.queued | length)))] | max)
  | .counts.landed = ([0, ((.counts.landed // $before.landed)
      - ($before.landed - (.landed | length)))] | max)
  | .counts.endpoints = ([0, ((.counts.endpoints // $before.endpoints)
      - ($before.endpoints - (.endpoints | length)))] | max)
  | .omitted = ([.omitted[]?
        | select(.surface != "project_lifecycle" and .surface != "legacy_posture_unknown")]
      + [if ($archived_projects | length) > 0 or $lifecycle_omission != null then
           {surface:"project_lifecycle",
            archived_projects:((($lifecycle_omission.archived_projects // []) + $archived_projects) | unique),
            parked_projects:([($lifecycle_omission.parked_projects // [])[]
              | select(fm_project_lifecycle(.; $projects; $today).parked)])}
         else empty end]
      + [if ($unidentified_legacy_rows | length) > 0 then
           {surface:"legacy_posture_unknown",count:($unidentified_legacy_rows | length),
            surfaces:([$unidentified_legacy_rows[].surface] | unique)}
         else empty end])
  | (.lifecycle_inventory // .queued // []) as $inventory
  | ([ $inventory[]?
      | fm_project_lifecycle(.repo; $projects; $today) as $life
      | select($life.posture == "parked" and ($life.parked | not))]) as $expired
  | ([ $expired[]
       | select(.backlog_state == "in_flight" and .current_role != "program")
       | select(.child_state == null or .child_state == "")
       | .id] | unique) as $expired_orphans
  | ([ $expired[]
       | select(.backlog_state == null and .kind != "secondmate")
       | select(.child_state != null and .child_state != "")
       | .id] | unique) as $expired_unowned
  | ([ $expired[]
       | select(.backlog_state == "in_flight"
           and (.child_state == "done" or .child_state == "failed"))
       | .id] | unique) as $expired_terminal
  | ([ $expired[]
       | select(.child_state == "unknown")
       | .id] | unique) as $expired_unknown
  | (if ($expired_orphans | length) > 0 then
       {kind:"orphan_in_flight",ids:$expired_orphans,
        reason:("in-flight backlog item has no child metadata: " + ($expired_orphans | join(", ")))}
     elif ($expired_unowned | length) > 0 then
       {kind:"unowned_current",ids:$expired_unowned,
        reason:("live child state has no in-flight backlog item: " + ($expired_unowned | join(", ")))}
     elif ($expired_terminal | length) > 0 then
       {kind:"terminal_in_flight",ids:$expired_terminal,
        reason:("in-flight backlog item has terminal child state: " + ($expired_terminal | join(", ")))}
     elif ($expired_unknown | length) > 0 then
       {kind:"child_current_unavailable",ids:$expired_unknown,
        reason:("child current state unavailable: " + ($expired_unknown | join(", ")))}
     else null end) as $expiry_invalidity
  | ([ $inventory[]?
      | fm_project_lifecycle(.repo; $projects; $today) as $life
      | select($life.parked)
      | select(.backlog_state == "queued" or .backlog_state == "in_flight")]) as $parked
  | (.queued // []) as $queued
  | ([$expired[]
      | select(.backlog_state == "in_flight" and .current_role != "program" and .child_state == "working")
      | {id, kind:(.kind // "secondmate"), state:.child_state, repo,
         source:(.child_source // "status-log"), doing:(.child_doing // "")}]) as $active
  | ([$expired[]
      | select(.backlog_state == "in_flight")
      | select(.child_state == "parked" or .child_state == "paused" or .child_state == "blocked")
      | {id, title:(.title // .id), repo, blocked_by:(.blocked_by // null),
         blocked_by_ids:(.blocked_by_ids // []), unresolved_blocker_ids:(.unresolved_blocker_ids // []),
         reason:(.child_doing // .hold_reason // .blocked_reason // .child_state), source:"child-state"}]) as $holds
  | ([$expired[]
      | select(.captain_actionable == true)
      | {id, key:.id, verb:"captain-hold", summary:.title, reason:.hold_reason, repo,
         hold_until, hold_bucket, hold_age_days, source:"backlog"}]) as $decisions
  | ([$expired[] | select(.backlog_state == "queued")]) as $expired_queued
  | fm_merge_by_id($queued; ($parked + $expired_queued)) as $lifecycle_queued
  | fm_merge_by_id($lifecycle_queued; $legacy_parked) as $merged_queued
  | .queued = $merged_queued
  | .counts.queued += (($merged_queued | length) - ($lifecycle_queued | length))
  | .active_children = fm_merge_by_id((.active_children // []); $active)
  | .holds = fm_merge_by_id((.holds // []); $holds)
  | .decisions_open = fm_merge_by_id((.decisions_open // []); $decisions)
  | .counts.active_children += ($active | length)
  | .counts.decisions_open += ($decisions | length)
  | .counts.holds += ($holds | length)
  | if .valid == true and $expiry_invalidity != null then
      .valid = false
      | .invalidity = ($expiry_invalidity | del(.reason))
      | .reason = $expiry_invalidity.reason
      | .state = "unknown"
    elif .valid == true then
      .state = (if any(.decisions_open[]; .verb == "needs-decision" or .verb == "captain-hold") then "captain_decision"
                elif (.active_children | length) > 0 then "active_child_work"
                elif (.holds | length) > 0 then "externally_held"
                else "no_active_work" end)
    else . end;
