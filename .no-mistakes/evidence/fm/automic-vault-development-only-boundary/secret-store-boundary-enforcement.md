# Automic Vault development-only boundary - enforcement evidence

Change: `docs: state and enforce the Automic Vault development-only boundary`
(target 9f230d7, base de44bf7). Documentation-only change; the end-user surface
is the tracked docs plus the `bin/fm-doc-audience-check.sh` check that enforces
the cross-reference and boundary anchor. Evidence below is the CLI transcript of
that real check against the actual tracked docs.

## 1. Colocated regression test passes (fixture proves the boundary is enforced)

```
$ bash tests/fm-documentation-audiences.test.sh
ok - documentation inventory classifies every maintained prose surface exactly once
ok - classification, setup routing, and maintained-prose scope fail safely
ok - required documentation owner pointers cannot silently disappear
ok - local links resolve while dates, versions, commands, and incident prose remain semantically reviewed
ok - the configuration doc must carry the secret-store boundary section its mentions point at
EXIT=0
```

## 2. Real check on the actual repo passes

```
$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=76 local_links=291
```

## 3. End-to-end: the boundary is genuinely enforced against the real docs

Ran the real `fm-doc-audience-check.sh` against a git-archive copy of the target
commit, then mutated it.

Boundary section present (target commit as shipped):
```
fm-doc-audience-check: ok surfaces=76 local_links=291
exit=0
```

Remove the `## Secret stores` boundary section from `docs/configuration.md`:
```
fm-doc-audience-check: unresolved local anchor in docs/bitwarden-rollout.md: configuration.md#secret-stores
exit=1
```

Remove the `configuration.md#secret-stores` pointer from `docs/bitwarden-rollout.md`:
```
fm-doc-audience-check: required owner pointer missing: docs/bitwarden-rollout.md -> docs/configuration.md
exit=1
```

## Content deliverables confirmed present

- `docs/configuration.md:276` - authoritative `## Secret stores` section
  (Automic Vault = dev-only per-machine injection; Bitwarden = production/team
  custody; no production custody/recovery/deployment/team path through Automic
  Vault; secret values never written to repo/briefs/notes/chat).
- `docs/configuration.md:291` - existing Claude auth section framed as a
  development-time use with same-file `[Secret stores](#secret-stores)` link.
- `docs/bitwarden-rollout.md:9` - points at the boundary owner
  `configuration.md#secret-stores` instead of restating it.
- `docs/documentation-audiences.json` - `requiredOwnerPointers` registers
  `docs/bitwarden-rollout.md -> docs/configuration.md`.
