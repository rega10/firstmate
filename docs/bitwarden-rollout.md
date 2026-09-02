# Bitwarden rollout for production and team credentials

This runbook is the staged path from temporary local-only credential custody to organization-owned Bitwarden custody for production and team credentials.
It is written for a normal operator: every routine action is a short checklist step, and engineering is only needed when a step says so.
Current access is preserved throughout: every move requires captain approval for its specific batch, and old custody remains unchanged after post-move verification as part of the intended Bitwarden and Automic Vault coexistence end state.

## Custody boundaries this rollout does not change

- Local secrets stay in the hardened local vault (Automic Vault).
  This rollout covers production and team credentials only; it never weakens, duplicates, or replaces hardened local access.
- Machine and unattended secrets are out of the initial migration.
  Bitwarden Password Manager (human and team credentials) and Bitwarden Secrets Manager (machine and unattended access) are separate custody models with separate consequences.
  Secrets Manager is deliberately not selected or enabled here; see the open decisions below.
- No secret value ever appears in this repo, in ceremony records, in task reports, or in chat.
  Every record names credentials by label, owner, and collection only.

## Roles

- **Owner (captain)**: approves phase gates and migration batches; holds one organization owner account.
- **Second owner/admin**: an independent person or independently held account that can recover the organization if the captain's account is lost.
- **Batch operator**: runs a migration batch's checklist; may be the captain or a delegate; never approves their own batch when dual control applies.

## Open decisions the captain must make before phase 1

These are recorded here because the rollout cannot choose them on anyone's behalf:

1. **Subscription and plan**: which Bitwarden plan and billing arrangement, chosen and purchased by the captain.
2. **Owner identities**: which two (or more) independent people or independently held accounts hold owner/admin recovery, so no single person is a recovery dependency.
3. **Retention and compliance**: any legal or contractual retention requirements that constrain export retention and deletion evidence.
4. **Machine-access architecture**: whether machine and unattended secrets later adopt Bitwarden Secrets Manager (bringing service accounts and access tokens that themselves become credentials to custody), stay on their current mechanisms, or use another store.
   Until this is decided, machine and unattended secrets remain on their current access paths, and nothing in the interim may copy them into Password Manager items as a workaround.

## Credential class inventory

Inventory classes and owners before the first batch; never enumerate or record secret values while doing it.

| Class | Examples | Initial migration? | Why |
| --- | --- | --- | --- |
| Human interactive | a person's own logins to production consoles and forges | yes | core Password Manager fit |
| Shared team | credentials several people legitimately share | yes | collections give least-privilege sharing |
| Production service | database and service passwords humans hold today | yes, human copies only | the human-held copy moves; the deployed configuration is untouched |
| CI/CD tokens | pipeline and deploy tokens | deferred | machine-access decision above owns their target |
| Break-glass | emergency access used when normal paths fail | yes, last batch, dual control | highest blast radius; migrate only after the process is proven on lower-risk batches |
| Local development | developer-machine secrets | no | stays in the hardened local vault |
| Machine/unattended | service-to-service secrets no human types | no | Secrets Manager decision not made |

## Phases and gates

Each phase has an entry gate; do not start a phase until the previous phase's exit condition is met and the captain has approved moving on.

### Phase 0 - decisions and inventory (no Bitwarden footprint)

- Captain resolves the open decisions above.
- Inventory the credential classes and owners (labels only).
- Exit: decisions recorded, inventory exists, captain approves phase 1.

### Phase 1 - organization hardening (no credentials migrated)

- Captain creates the organization on the chosen plan.
- Both owner/admin recovery paths are established and independently tested: each owner proves they can sign in, and account recovery (or an equivalent second path) is confirmed before any credential arrives.
- Hardware-backed MFA is enrolled on every privileged account, with a documented MFA-loss recovery that does not depend on a single person.
- Collections and groups are created least-privilege: one collection per team or system boundary, no default all-access group, admin roles held only by the named owners.
- Joiner/mover/leaver procedure is written into the organization's own documentation: joiners get group membership only, movers change groups not items, leavers lose access by group removal and trigger rotation of anything they could have exported.
- Exit: a second owner has demonstrated recovery access, MFA is verified on all privileged accounts, and the captain approves the pilot.

### Phase 2 - pilot batch (lowest-risk shared team credentials)

- Run one full migration ceremony (below) on a small, low-risk batch.
- Run one full recovery drill (below) while the stakes are low.
- Exit: pilot batch verified, drill passed, captain approves production batches.

### Phase 3 - production batches

- Migrate remaining in-scope classes in captain-approved batches, riskiest last.
- Break-glass credentials move only under dual control: one person moves, a different person verifies, the captain approves.
- Exit: all in-scope classes migrated or explicitly deferred with a recorded reason.

### Phase 4 - routine operation

- Joiner/mover/leaver runs as written; drills run on the recovery cadence below; deferred classes wait on their owning decision.

## Migration ceremony (per batch)

Every batch follows the same ordered ceremony, and its auditable no-secret record is kept with `bin/fm-bitwarden-ceremony.sh` (its `--help` owns the record format and step gates; the tool validates structure and status only and must never be given a secret value):

1. **Init and plan**: initialize the batch record; register every item as label, owner, and target collection.
2. **Preflight**: confirm each item's current custody still works, its target collection exists with the right group access, and its owner is available for verification.
3. **Captain approval**: the captain approves this exact batch; the approval is recorded with the approver's identity.
4. **Move**: the owner (or batch operator, with the owner for dual control) creates each item in Bitwarden by signing into both sides directly; values pass through no intermediate file, chat, or tool.
5. **Verify coexistence**: each item's intended users prove real access through Bitwarden (an actual sign-in or connection using the migrated item), anyone who should not see it confirms they cannot, and the operator confirms the old custody remains intact and usable.
6. **Rollback point**: if Bitwarden verification fails, the old custody is still intact; fix or remove the Bitwarden item and re-verify - nothing has been lost.
7. **Record**: the verified batch record (labels, owners, collections, dates, approver - never values) is the completion evidence for coexistence.

The record tool has no retirement transition: verification completes the batch as coexistence evidence, and neither batch approval nor completion authorizes deletion, invalidation, rotation, or retirement of old custody.
It also refuses to read any record it cannot fully validate - a hand-edited, truncated, or misfiled history is never reported as progress - and its `--help` owns the exact record rules.
When a record is refused, correct it back to its last valid prefix (delete only the trailing lines that are not yet true) or quarantine it outside the record directory and start a new batch; never edit it into a shape that merely satisfies the tool.

## Encrypted export and recovery drills

Design only until phase 2; no export is created outside a drill or the operational cadence.

- **What**: the organization's encrypted export (password-protected, account-independent format), never a plaintext export, with no plaintext staging step at any point.
- **Custody**: stored offline on dedicated media, at least two copies in separate physical locations.
- **Split ownership**: the export file and its encryption passphrase are held by different people, so neither holder can read it alone; the passphrase itself is written down once per holder and stored with their personal recovery material, not in any vault the export is meant to recover.
- **Restore verification**: a drill is passed only when a restore into a scratch client proves a sampled item actually opens; an unverified export is treated as no export.
- **Rotation after exposure**: if an export or passphrase may have been exposed, rotate the credentials it contained, not just the export.
- **Cadence**: refresh the export and run a restore drill at least quarterly, and immediately after any owner/admin change.
- **Retention and deletion**: superseded exports are destroyed (media erased or physically destroyed), and the drill evidence records export date, holders, restore result, and destruction of the superseded copy - never contents.

Drill evidence template (copy per drill, no secret values):

```
drill: <YYYY-MM-DD>
export-created: <YYYY-MM-DD> by <label>
copies: <location-label-1>, <location-label-2>
passphrase-holder: <label> (distinct from export holder: <label>)
restore-verified: <YYYY-MM-DD> by <label>, sampled item opened: yes/no
superseded-copy-destroyed: <YYYY-MM-DD> by <label>
notes: <free text, labels only>
```

## What this runbook never authorizes

This runbook never authorizes deleting, invalidating, rotating, or retiring existing custody or credentials, and no migration-batch approval can authorize those actions.
Creating accounts or organizations, choosing or purchasing a plan, inviting users, changing billing, reading or moving secret values, or changing production access require the captain's direct participation or explicit approval at the gate that names them.
