# Claude Automic Vault verification

Audience: maintainer verification.

This record supports the operator contract in [`docs/configuration.md`](../configuration.md#claude-authentication-through-automic-vault-configclaude-automic-vault) and the executable owner in `bin/fm-claude-automic-vault.sh`.
It records repeatable synthetic evidence and deliberately excludes credential material, private Vault state, account identifiers, task chronology, and live token results.

## Verified local tool surfaces

Verified 2026-08-29 with Claude Code 2.1.231 and Automic Vault 3.18.0 on macOS.
`claude --help` advertised `setup-token`, `--settings`, `--safe-mode`, `--no-session-persistence`, `--tools`, and JSON output.
`claude auth status --help` advertised `--json`.
`av inject --help` advertised process-scoped injection, requested-key syntax, command separation, and `--replace-existing-env`.
Automic Vault's documented `av save KEY` path reads the value from the controlling terminal rather than a command argument or ordinary stdin.
The installed Automic Vault hardener catalog contained no Claude-specific hardener, so this integration deliberately does not alter the ordinary `claude` executable or global shell path.

## Claude version qualification

Claude Code 2.1.258 from the `claude-code@latest` Homebrew cask was qualified on 2026-09-03 at `/opt/homebrew/Caskroom/claude-code@latest/2.1.258/claude`, which reported `2.1.258 (Claude Code)`.
The recorded command was `bin/fm-claude-automic-vault-qualify.sh /opt/homebrew/Caskroom/claude-code@latest/2.1.258/claude`.
Its successful output was exactly:

```text
qualified: 2.1.258 (Claude Code) at /opt/homebrew/Caskroom/claude-code@latest/2.1.258/claude matched Anthropic release attestation and executed one approval-free tool with its OAuth environment scrubbed.
```
The executable admission owner is `bin/fm-claude-automic-vault-qualified-versions`, which records the exact reported version, qualification date, and resolved canonical path for each evidence-backed entry.
To qualify an upgrade, first pin its official release-manifest checksum, then run `bin/fm-claude-automic-vault-qualify.sh /absolute/path/to/supported/canonical/claude-executable` against the actual candidate executable that will be admitted.
The check attests that exact candidate against the pinned Anthropic release manifest, runs it through Firstmate's pinned startup-clean sanitizer, supplies a clearly non-secret placeholder token, directs it to a loopback model fixture, requires approval-free Bash tool execution, and requires the tool subprocess to receive no OAuth token.
After a successful result, add that exact reported version, check date, and resolved path to the qualification list, then rerun `tests/fm-claude-automic-vault.test.sh` before review.
Do not infer qualification from a newer version number, advertised flags, release-manifest attestation, or another version's result.
This procedure uses no Vault and only a loopback model fixture with a fake token; it does not authorize a real Vault, real token, or live authenticated Claude operation.

## Authentication counterfactual

An isolated run with a synthetic invalid `CLAUDE_CODE_OAUTH_TOKEN` made `claude auth status --json` exit successfully and report `loggedIn=true`, `authMethod=oauth_token`, and `apiProvider=firstParty`.
The same synthetic token made one safe, tool-free, non-persistent print request fail with a redacted 401 authentication result.
That counterfactual is why preflight requires both local classification and a minimal live request rather than treating status alone as proof.
No real token was created, saved, printed, rotated, revoked, migrated, or read while establishing this evidence.

## Repeatable synthetic coverage

Run:

```sh
tests/fm-claude-automic-vault.test.sh
```

The test uses fake `av` and fake `claude` executables with synthetic secret bytes held only in process environment.
It exercises public provisioning, one-time enable recovery, renewal, and preflight, enabled and disabled spawn behavior, direct, assignment-prefixed, option-prefixed, split-string `env`, literal shell-payload, literal-eval, and classifier-unavailable opted-in raw Claude refusal before endpoint creation, Claude versus non-Claude isolation, missing Vault state, Secret Gate denial, a missing secret, revoked-token rejection, unsupported tool surfaces, inconclusive authentication, executable recursion refusal, model and effort argument preservation, redacted output, persistent secondmate launch and relaunch, inherited opt-in, and a nested worker launched from the inherited home.
It executes the captured enabled worker launch and proves the fake Claude process received the injected environment while higher-precedence auth inputs were absent.
It also proves the final Claude exec receives exactly one `--settings` value, that this authoritative value disables `apiKeyHelper` and matching authentication environment settings while preserving `feedbackDrafts: off`, and that no worker-template settings survive into the exec arguments.
It then scans every fixture file, captured launch command, fake argv log, and command output to prove the synthetic secret bytes were not persisted or displayed.
The fake Claude coverage exercises general launch mechanics but never qualifies or admits a real Claude version; only the actual-candidate command in the qualification section can supply that evidence.

The inherited-material regression is also covered by:

```sh
tests/fm-secondmate-harness.test.sh
```

That test proves byte-exact propagation, primary-absence convergence, rejection of malformed opt-in files, and preservation of the last validated destination.
It also proves that enabled propagation requires compatible tracked owner files and rejects missing or untracked owner proof.

The remote exclusion regression is covered by:

```sh
tests/fm-remote-secondmate-lifecycle-e2e.test.sh
```

That test proves a remote receiver refuses publication of the Mac-local flag and that remote launch convergence removes a stale copy instead of inheriting the primary flag.

## Intentionally unperformed checks

Do not run `claude setup-token`, `av save CLAUDE_CODE_OAUTH_TOKEN`, or an enabled preflight with a real secret as part of automated validation, CI, review, or no-mistakes.
The implementation therefore does not prove that a particular captain Vault is unlocked, that Secret Gate policy currently permits a particular launch, that a real `CLAUDE_CODE_OAUTH_TOKEN` exists, or that a real subscription token is presently valid.
Those facts remain intentionally unproven until the captain runs `bin/fm-claude-automic-vault.sh provision` in an attended terminal after merge.
Remote inheritance omits and removes this Mac-local opt-in, so this integration does not authorize or instruct remote Vault or Claude credential provisioning.
The accepted threat model assumes same-user process integrity, so TOCTOU attacks by another process running as the same user remain intentionally unproven and out of scope by captain decision on 2026-09-02.
