#!/usr/bin/env bash
# fm-bearings-contract-lib.sh - the single owner of the machine-readable contract
# that describes bin/fm-bearings-snapshot.sh's `--json` output (schema
# `fm-bearings.v1`).
#
# Sourced by fm-bearings-snapshot.sh, never executed on its own. Provides one
# function, fm_bearings_emit_contract, which prints a deterministic JSON document
# a consumer (such as Orchestra) reads INSTEAD of guessing at field names, enum
# values, or which surfaces are bounded or opt-in. The rule the contract exists to
# serve: a consumer keeps no second source of truth for the snapshot's meaning; it
# reads the contract and renders whatever the snapshot says.
#
# This is a DESCRIPTION of the `--json` model produced by fm-bearings-snapshot.sh,
# and its counterpart, the colocated contract test in
# tests/fm-bearings-snapshot.test.sh, is what keeps the two honest: the test
# validates real `--json` output against this contract and fails when a field or
# enum value appears that the contract does not declare. Change one and the test
# forces the other to follow.
#
# The contract document itself:
#   contract        the contract document's own id (fm-bearings-contract.v1)
#   schema/version  the `--json` .schema value this contract describes, reused as
#                   the version anchor (fm-bearings.v1)
#   compatibility   the rule: adding optional fields is a minor change; renaming or
#                   removing a field or an enum value requires bumping the schema id
#   identity        the identity rules a consumer needs (task id, decision key, PR URL)
#   enums           the closed value sets, keyed by name; a field cites one by name
#   surfaces        every top-level surface, keyed by name, each with:
#                     type      "scalar" or "array"
#                     presence  "always" | "conditional" | "opt-in"
#                     reveal    the flag/condition that reveals a non-always surface
#                     fields    for arrays, each row field -> {type, enum?}
#                     notes     free-text clarification (optional)
#   bounds          which array surfaces are capped, by which env var, the flag that
#                   lifts the cap, and how `omitted` discloses the cut
#
# The enum value sets are authored here to match their producers: task states from
# bin/fm-crew-state.sh, secondmate state/provenance/freshness and decision verbs
# from bin/fm-fleet-snapshot.sh, postures from bin/fm-project-posture.sh, and the
# pr_checks/endpoint fields from fm-bearings-snapshot.sh's own projection. When any
# producer's vocabulary changes, update the matching enum here; the test catches a
# value that escapes an unchanged declaration.
set -u

# fm_bearings_emit_contract - print the contract JSON to stdout. Static, so it
# needs no fleet read, no network, and no locks; it is deterministic across runs.
fm_bearings_emit_contract() {
  command -v jq >/dev/null 2>&1 || { echo "fm-bearings-snapshot: jq not found" >&2; return 1; }
  # A here-doc through jq so malformed JSON fails loudly at authoring time and the
  # output is canonicalized (insertion order preserved) rather than trusted raw.
  jq -e . <<'CONTRACT' || { echo "fm-bearings-snapshot: contract JSON is invalid" >&2; return 1; }
{
  "contract": "fm-bearings-contract.v1",
  "schema": "fm-bearings.v1",
  "version": "fm-bearings.v1",
  "describes": "the bin/fm-bearings-snapshot.sh --json output; the TOON default is a parity rendering of the same model",
  "compatibility": "Adding an optional field or a new opt-in/conditional surface is a minor, backward-compatible change and does not bump the schema id. Renaming or removing any field or surface, or removing or renaming an enum value, is a breaking change and requires bumping the schema id (fm-bearings.v2). A consumer must read .schema first and refuse a major version it does not understand.",
  "identity": {
    "task_id": "A task id (the `id` field on in_flight, landed, gates, reports, recorded_prs, unhealthy_endpoints, and the bodies/paths/actions/endpoints surfaces) is stable identity for that unit of work; it does not change across snapshots and is safe to key a consumer's records on. A secondmate-owned row is namespaced as `<secondmate-id>/<child-id>`.",
    "decision_key": "A decisions_open row's `key` is the captain-held backlog task id that a reply resolves; `id` is the same key for a main-home decision and the namespaced `<secondmate-id>/<key>` for a secondmate-owned one. The `key` is the stable handle a consumer uses to refer to the decision.",
    "pr_url": "Every PR reference is a full URL (https://...), never a bare number: recorded_prs[].url, landed[].artifact when it is a PR, and candidate_prs[].url."
  },
  "enums": {
    "task_kind": ["ship", "scout", "secondmate"],
    "task_state": ["working", "parked", "done", "blocked", "paused", "failed", "unknown", "active_child_work"],
    "secondmate_state": ["captain_decision", "active_child_work", "externally_held", "no_active_work", "unknown"],
    "secondmate_provenance": ["structured-home", "parent-event-fallback", "registered-table", "unknown"],
    "secondmate_freshness": ["fresh", "historical-event", "unavailable", "unknown"],
    "decision_verb": ["captain-hold"],
    "project_posture": ["active", "parked", "archived"],
    "pr_checks": ["none", "passing", "failing", "pending"],
    "pr_mergeable": ["MERGEABLE", "CONFLICTING", "UNKNOWN"],
    "endpoint_agent": ["alive", "dead", "unknown", "not_checked"]
  },
  "surfaces": {
    "schema": {
      "type": "scalar",
      "value_type": "string",
      "presence": "always",
      "notes": "Always the literal \"fm-bearings.v1\". A consumer reads this first and refuses an unknown major version."
    },
    "home": {
      "type": "scalar",
      "value_type": "string",
      "presence": "always",
      "notes": "The last two path segments identifying which firstmate home produced the snapshot."
    },
    "generated": {
      "type": "scalar",
      "value_type": "string",
      "presence": "always",
      "notes": "The generation timestamp (UTC ISO 8601). Not stable across runs; not an identity."
    },
    "prs": {
      "type": "scalar",
      "value_type": "string",
      "presence": "always",
      "notes": "Free-text status of live PR discovery. Begins with \"not_requested\" on the default local-only path and \"checked\"/\"unavailable\" under --include-prs. Not an enum."
    },
    "projects": {
      "type": "array",
      "presence": "always",
      "notes": "The registered project lifecycle registry, verbatim from the canonical snapshot. Includes archived projects even though their work is omitted from the work surfaces.",
      "fields": {
        "name": {"type": "string"},
        "posture": {"type": "string", "enum": "project_posture"},
        "parked_until": {"type": "string", "notes": "ISO date when posture is a dated park; null otherwise."},
        "repo": {"type": "string"},
        "delivery": {"type": "string", "notes": "The project's standing delivery mode as recorded in the registry; free text, not enumerated by this contract."}
      }
    },
    "in_flight": {
      "type": "array",
      "presence": "always",
      "notes": "Work under way in this home, plus a per-secondmate row summarizing active child work.",
      "fields": {
        "id": {"type": "string"},
        "kind": {"type": "string", "enum": "task_kind"},
        "state": {"type": "string", "enum": "task_state"},
        "doing": {"type": "string", "notes": "Truncated current-activity summary; free text."}
      }
    },
    "secondmates": {
      "type": "array",
      "presence": "always",
      "notes": "One row per registered secondmate (and a synthetic \"(registry)\" row when the registry itself is unreadable).",
      "fields": {
        "id": {"type": "string"},
        "state": {"type": "string", "enum": "secondmate_state"},
        "doing": {"type": "string", "notes": "Truncated summary of what the home is doing; free text."},
        "provenance": {"type": "string", "enum": "secondmate_provenance"},
        "freshness": {"type": "string", "enum": "secondmate_freshness"},
        "age_seconds": {"type": "number", "notes": "Age of the evidence in seconds, or null when unknown."},
        "contradiction": {"type": "boolean"},
        "reason": {"type": "string"}
      }
    },
    "decisions_open": {
      "type": "array",
      "presence": "always",
      "notes": "Captain-actionable open holds (Captain's Call). Includes secondmate-owned holds, namespaced.",
      "fields": {
        "id": {"type": "string"},
        "key": {"type": "string", "notes": "The captain-held task id a reply resolves (see identity.decision_key)."},
        "verb": {"type": "string", "enum": "decision_verb"},
        "summary": {"type": "string"},
        "owner": {"type": "string", "notes": "\"(main)\" for this home, or the owning secondmate id."}
      }
    },
    "landed": {
      "type": "array",
      "presence": "always",
      "notes": "Recently landed work merged across this home and registered secondmate homes. Bounded and balanced across homes by default.",
      "fields": {
        "id": {"type": "string"},
        "what": {"type": "string"},
        "artifact": {"type": "string", "notes": "A full PR URL, a report path, a local note, or \"-\"."},
        "owner": {"type": "string", "notes": "\"(main)\" or the owning secondmate id."}
      }
    },
    "gates": {
      "type": "array",
      "presence": "always",
      "notes": "Charted Next: queued or blocked work, parked-project work, and a synthetic \"(main-inventory)\" row when main current state is invalid. No field on a gate row is enum-typed: blocked_by and reason are free text and id is a task id or that sentinel.",
      "fields": {
        "id": {"type": "string"},
        "title": {"type": "string"},
        "blocked_by": {"type": "string", "notes": "Comma-joined blocker task ids, or \"-\"."},
        "reason": {"type": "string"},
        "owner": {"type": "string", "notes": "\"(main)\" or the owning secondmate id."}
      }
    },
    "reports": {
      "type": "array",
      "presence": "always",
      "notes": "Scout report pointers relevant to current work (or all reports under --all-reports).",
      "fields": {
        "id": {"type": "string"},
        "path": {"type": "string"}
      }
    },
    "recorded_prs": {
      "type": "array",
      "presence": "always",
      "notes": "PRs recorded locally in task metadata; no network read. Every url is a full URL.",
      "fields": {
        "id": {"type": "string"},
        "url": {"type": "string"}
      }
    },
    "unhealthy_endpoints": {
      "type": "array",
      "presence": "conditional",
      "reveal": "present only when at least one endpoint is unhealthy (missing or dead); absent otherwise",
      "notes": "Tasks whose recorded backend endpoint is missing or dead. Includes namespaced secondmate child endpoints.",
      "fields": {
        "id": {"type": "string"},
        "backend": {"type": "string"},
        "target": {"type": "string"},
        "exists": {"type": "boolean", "notes": "null when the task's endpoint target is empty (a local task with no recorded endpoint target); true or false otherwise."},
        "agent": {"type": "string", "enum": "endpoint_agent"}
      }
    },
    "candidate_prs": {
      "type": "array",
      "presence": "opt-in",
      "reveal": "--include-prs",
      "notes": "Live open-PR discovery and checks. The only surface that touches the network.",
      "fields": {
        "num": {"type": "string"},
        "repo": {"type": "string"},
        "task": {"type": "string", "notes": "The fm/ branch's task id, or \"-\"."},
        "url": {"type": "string"},
        "review": {"type": "string", "notes": "GitHub review decision (APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, ...) or \"none\"; GitHub's vocabulary, not closed by this contract."},
        "mergeable": {"type": "string", "enum": "pr_mergeable"},
        "checks": {"type": "string", "enum": "pr_checks"}
      }
    },
    "bodies": {
      "type": "array",
      "presence": "opt-in",
      "reveal": "--fields bodies",
      "notes": "Truncated backlog item body excerpts for queued and done items.",
      "fields": {
        "id": {"type": "string"},
        "body": {"type": "string"}
      }
    },
    "paths": {
      "type": "array",
      "presence": "opt-in",
      "reveal": "--fields paths",
      "notes": "Local filesystem paths for each task.",
      "fields": {
        "id": {"type": "string"},
        "worktree": {"type": "string"},
        "home": {"type": "string"},
        "status": {"type": "string"},
        "report": {"type": "string"}
      }
    },
    "actions": {
      "type": "array",
      "presence": "opt-in",
      "reveal": "--fields actions",
      "notes": "Watch/steer command hints for each task.",
      "fields": {
        "id": {"type": "string"},
        "watch": {"type": "string"},
        "steer": {"type": "string"}
      }
    },
    "endpoints": {
      "type": "array",
      "presence": "opt-in",
      "reveal": "--fields endpoints",
      "notes": "Endpoint detail for every task (healthy and unhealthy), unlike unhealthy_endpoints which lists only the unhealthy.",
      "fields": {
        "id": {"type": "string"},
        "backend": {"type": "string"},
        "target": {"type": "string"},
        "exists": {"type": "boolean", "notes": "null when the task's endpoint target is empty (a local task with no recorded endpoint target); true or false otherwise."},
        "agent": {"type": "string", "enum": "endpoint_agent"}
      }
    },
    "omitted": {
      "type": "array",
      "presence": "always",
      "notes": "The disclosure surface: a consumer must SURFACE these to the reader, never hide them. Each row names something the default view did not include and how to reveal it. The `surface` text is templated (it interpolates counts and project names), so it is not enumerable; the `reveal` values are the flags, env vars, or inspection hints listed under `bounds` plus \"--include-prs\", \"--fields bodies|paths|actions|endpoints\", and \"bin/fm-project-posture.sh set <project> active\".",
      "fields": {
        "surface": {"type": "string"},
        "reveal": {"type": "string"}
      }
    }
  },
  "bounds": [
    {"surface": "in_flight", "env": "FM_BEARINGS_IN_FLIGHT", "reveal": "--all-in-flight", "disclosed_as": "in_flight showing <n> of <m>"},
    {"surface": "secondmates", "env": "FM_BEARINGS_SECONDMATES", "reveal": "--all-secondmates", "disclosed_as": "secondmates showing <n> of <m>"},
    {"surface": "decisions_open", "env": "FM_BEARINGS_DECISIONS", "reveal": "--all-decisions", "disclosed_as": "decisions_open showing <n> of <m>"},
    {"surface": "landed", "env": "FM_BEARINGS_LANDED (overall) and FM_BEARINGS_LANDED_PER_HOME (per home)", "reveal": "--all-landed", "disclosed_as": "landed showing <n> of <m> and landed per-home capped at <k> for <h> home(s)"},
    {"surface": "gates", "env": "FM_BEARINGS_GATES", "reveal": "--all-queued", "disclosed_as": "gates showing <n> of <m>"},
    {"surface": "reports", "env": "FM_BEARINGS_REPORTS", "reveal": "--all-reports", "disclosed_as": "reports showing <n> of <m>"},
    {"surface": "recorded_prs", "env": "FM_BEARINGS_RECORDED_PRS", "reveal": "--all-recorded-prs", "disclosed_as": "recorded_prs showing <n> of <m>"},
    {"surface": "unhealthy_endpoints", "env": "FM_BEARINGS_UNHEALTHY", "reveal": "--all-unhealthy", "disclosed_as": "unhealthy_endpoints showing <n> of <m>"},
    {"surface": "candidate_prs", "env": "FM_BEARINGS_PR_REPOS (repositories) and FM_BEARINGS_PR_LIMIT (per-repo rows)", "reveal": "--all-pr-repos and raise FM_BEARINGS_PR_LIMIT", "disclosed_as": "PR repositories showing <n> of <m> and candidate_prs showing <n> of at least <m>"}
  ]
}
CONTRACT
}
