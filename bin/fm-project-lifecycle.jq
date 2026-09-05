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
  | (.lifecycle_inventory // .queued // []) as $inventory
  | ([ $inventory[]?
      | fm_project_lifecycle(.repo; $projects; $today) as $life
      | select($life.posture == "parked" and ($life.parked | not))]) as $expired
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
  | .queued = fm_merge_by_id($queued; $parked)
  | .active_children = fm_merge_by_id((.active_children // []); $active)
  | .holds = fm_merge_by_id((.holds // []); $holds)
  | .decisions_open = fm_merge_by_id((.decisions_open // []); $decisions)
  | .counts.active_children += ($active | length)
  | .counts.decisions_open += ($decisions | length)
  | .counts.holds += ($holds | length)
  | if .valid == true then
      .state = (if any(.decisions_open[]; .verb == "needs-decision" or .verb == "captain-hold") then "captain_decision"
                elif (.active_children | length) > 0 then "active_child_work"
                elif (.holds | length) > 0 then "externally_held"
                else "no_active_work" end)
    else . end;
