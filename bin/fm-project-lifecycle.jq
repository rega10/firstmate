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

def fm_surface_limit($surface; $before; $total; $bounds; $omitted):
  if ($bounds[$surface] | type) == "number" then $bounds[$surface]
  elif $total > $before or any($omitted[]?; .surface == $surface) then $before
  else null
  end;

def fm_set_surface_omission($surface; $count):
  .omitted = ([.omitted[]? | select(.surface != $surface)]
    + [if $count > 0 then {surface:$surface,count:$count} else empty end]);

def fm_invalidity_reason($kind; $ids):
  if $kind == "child_current_unavailable" then
    "child current state unavailable: " + ($ids | join(", "))
  elif $kind == "orphan_in_flight" then
    "in-flight backlog item has no child metadata: " + ($ids | join(", "))
  elif $kind == "unowned_current" then
    "live child state has no in-flight backlog item: " + ($ids | join(", "))
  elif $kind == "terminal_in_flight" then
    "in-flight backlog item has terminal child state: " + ($ids | join(", "))
  else null
  end;

def fm_secondmate_summary_at($today):
  if (has("projects") and has("lifecycle_inventory")) | not then .
  else
  (.projects // []) as $projects
  | (.bounds // {}) as $bounds
  | {active_children:(.active_children | length),holds:(.holds | length),
     decisions_open:(.decisions_open | length),queued:(.queued | length),
     landed:(.landed | length),endpoints:(.endpoints | length)} as $before
  | ([((.active_children // []), (.holds // []), (.decisions_open // []),
       (.queued // []), (.landed // []), (.endpoints // []), (.lifecycle_inventory // []))[]?
      | fm_project_lifecycle(.repo; $projects; $today)
      | select(.archived)
      | .name]
     | map(select(. != null)) | unique) as $archived_projects
  | ([((.active_children // []), (.holds // []), (.decisions_open // []),
       (.queued // []), (.landed // []), (.endpoints // []))[]?
      | select(fm_project_lifecycle(.repo; $projects; $today).archived)
      | .id]
     | map(select(type == "string" and . != "")) | unique) as $archived_ids
  | (first((.omitted // [])[]? | select(.surface == "project_lifecycle")) // null) as $lifecycle_omission
  | .active_children |= map(select(fm_project_lifecycle(.repo; $projects; $today)
      | .archived | not))
  | .holds |= map(select(fm_project_lifecycle(.repo; $projects; $today)
      | .archived | not))
  | .decisions_open |= map(select(fm_project_lifecycle(.repo; $projects; $today)
      | .archived | not))
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
  | (.invalidity.kind // null) as $prior_invalid_kind
  | (.invalidity.ids // []) as $prior_invalid_ids
  | (.state == "unknown"
      and (["orphan_in_flight","unowned_current","terminal_in_flight"]
        | index($prior_invalid_kind)) != null) as $prior_unknown_state
  | ($prior_invalid_ids
     | [.[] as $id | select(($archived_ids | index($id)) == null) | $id]) as $retained_invalid_ids
  | ([.endpoints[]? | select(.state == "unknown") | .id]
     | map(select(type == "string" and . != "")) | unique) as $visible_unknown_ids
  | .omitted = ([.omitted[]?
        | select(.surface != "project_lifecycle" and .surface != "lifecycle_inventory")]
      + [if ($archived_projects | length) > 0 or $lifecycle_omission != null then
           {surface:"project_lifecycle",
            archived_projects:((($lifecycle_omission.archived_projects // []) + $archived_projects) | unique),
            parked_projects:([($lifecycle_omission.parked_projects // [])[]
              | select(fm_project_lifecycle(.; $projects; $today).parked)])}
         else empty end])
  | .lifecycle_inventory as $inventory
  | ([ $inventory[]?
      | fm_project_lifecycle(.repo; $projects; $today) as $life
      | select($life.posture == "parked" and ($life.parked | not))]) as $expired
  | ([ $expired[]
       | select(.backlog_state == "in_flight" and .current_role == "worker")
       | select(.child_state == null or .child_state == "")
       | .id] | unique) as $expired_orphans
  | ([ $expired[]
       | select(.backlog_state != "in_flight" and .kind != "secondmate")
       | select(.child_state != null and .child_state != "")
       | .id] | unique) as $expired_unowned
  | ([ $expired[]
       | select(.backlog_state == "in_flight"
           and (.child_state == "done" or .child_state == "failed"))
       | .id] | unique) as $expired_terminal
  | ([ $expired[]
       | select(.child_state == "unknown")
       | .id] | unique) as $expired_unknown
  | (.queued // []) as $queued
  | fm_surface_limit("active_children"; $before.active_children;
      .counts.active_children; $bounds; .omitted) as $active_limit
  | fm_surface_limit("holds"; $before.holds;
      .counts.holds; $bounds; .omitted) as $holds_limit
  | fm_surface_limit("decisions_open"; $before.decisions_open;
      .counts.decisions_open; $bounds; .omitted) as $decisions_limit
  | fm_surface_limit("queued"; $before.queued;
      .counts.queued; $bounds; .omitted) as $queued_limit
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
  | ([$expired[]
      | select(.backlog_state == "queued"
          or (.backlog_state == "in_flight"
            and (.child_state == "parked" or .child_state == "paused" or .child_state == "blocked")))]) as $expired_queueable
  | ([$expired[] | select(.id as $id | any($expired_queueable[]; .id == $id) | not) | .id]
     | unique) as $expired_dequeued_ids
  | (.queued // []
     | map(. as $row | select(any($expired[]; .id == $row.id) | not))) as $retained_queued
  | fm_merge_by_id($retained_queued; $expired_queueable) as $lifecycle_queued
  | ([0, ((.counts.queued // ($queued | length))
      - ($expired_dequeued_ids | length))] | max) as $queued_total
  | fm_merge_by_id((.active_children // []); $active) as $merged_active
  | fm_merge_by_id((.holds // []); $holds) as $merged_holds
  | fm_merge_by_id((.decisions_open // []); $decisions) as $merged_decisions
  | ((.counts.active_children // 0) + ($active | length)) as $active_total
  | ((.counts.holds // 0) + ($holds | length)) as $holds_total
  | ((.counts.decisions_open // 0) + ($decisions | length)) as $decisions_total
  | .queued = (if $queued_limit == null then $lifecycle_queued else $lifecycle_queued[:$queued_limit] end)
  | .active_children = (if $active_limit == null then $merged_active else $merged_active[:$active_limit] end)
  | .holds = (if $holds_limit == null then $merged_holds else $merged_holds[:$holds_limit] end)
  | .decisions_open = (if $decisions_limit == null then $merged_decisions else $merged_decisions[:$decisions_limit] end)
  | .counts.queued = $queued_total
  | .counts.active_children = $active_total
  | .counts.holds = $holds_total
  | .counts.decisions_open = $decisions_total
  | fm_set_surface_omission("queued"; ($queued_total - (.queued | length)))
  | fm_set_surface_omission("active_children"; ($active_total - (.active_children | length)))
  | fm_set_surface_omission("holds"; ($holds_total - (.holds | length)))
  | fm_set_surface_omission("decisions_open"; ($decisions_total - (.decisions_open | length)))
  | ((if $prior_invalid_kind == "orphan_in_flight" then $retained_invalid_ids else [] end)
      + $expired_orphans | unique) as $current_orphans
  | ((if $prior_invalid_kind == "unowned_current" then $retained_invalid_ids else [] end)
      + $expired_unowned | unique) as $current_unowned
  | ((if $prior_invalid_kind == "terminal_in_flight" then $retained_invalid_ids else [] end)
      + $expired_terminal | unique) as $current_terminal
  | ((if $prior_invalid_kind == "child_current_unavailable" then $retained_invalid_ids else [] end)
      + $visible_unknown_ids + $expired_unknown | unique) as $current_unknown
  | (["child_current_unavailable","orphan_in_flight","unowned_current","terminal_in_flight"]
      | index($prior_invalid_kind)) as $owned_prior_kind
  | ($prior_invalid_kind != null and $owned_prior_kind == null) as $fatal_prior
  | (if $fatal_prior then
       {kind:$prior_invalid_kind,ids:$prior_invalid_ids,reason:.reason}
     elif ($current_orphans | length) > 0 then
       {kind:"orphan_in_flight",ids:$current_orphans,
        reason:(if $prior_invalid_kind == "orphan_in_flight"
                   and ($expired_orphans | length) == 0
                   and $retained_invalid_ids == $current_orphans then .reason
                else fm_invalidity_reason("orphan_in_flight"; $current_orphans) end)}
     elif ($current_unowned | length) > 0 then
       {kind:"unowned_current",ids:$current_unowned,
        reason:(if $prior_invalid_kind == "unowned_current"
                   and ($expired_unowned | length) == 0
                   and $retained_invalid_ids == $current_unowned then .reason
                else fm_invalidity_reason("unowned_current"; $current_unowned) end)}
     elif ($current_terminal | length) > 0 then
       {kind:"terminal_in_flight",ids:$current_terminal,
        reason:(if $prior_invalid_kind == "terminal_in_flight"
                   and ($expired_terminal | length) == 0
                   and $retained_invalid_ids == $current_terminal then .reason
                else fm_invalidity_reason("terminal_in_flight"; $current_terminal) end)}
     elif ($current_unknown | length) > 0 then
       {kind:"child_current_unavailable",ids:$current_unknown,
        reason:(if $prior_invalid_kind == "child_current_unavailable"
                   and ($expired_unknown | length) == 0
                   and $retained_invalid_ids == $current_unknown then .reason
                else fm_invalidity_reason("child_current_unavailable"; $current_unknown) end)}
     else null end) as $current_invalidity
  | if $current_invalidity == null then
      .valid = true
      | .invalidity = {kind:null,ids:[]}
      | .reason = null
    else
      .valid = false
      | .invalidity = ($current_invalidity | del(.reason))
      | .reason = $current_invalidity.reason
    end
  | if .valid != true
      and (($current_unknown | length) > 0 or $prior_unknown_state or $fatal_prior) then
      .state = "unknown"
    else
      .state = (if any(.decisions_open[]; .verb == "needs-decision" or .verb == "captain-hold") then "captain_decision"
                elif (.active_children | length) > 0 then "active_child_work"
                elif (.holds | length) > 0 then "externally_held"
                else "no_active_work" end)
    end
  end;
