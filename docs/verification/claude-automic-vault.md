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
It then scans every fixture file, captured launch command, fake argv log, and command output to prove the synthetic secret bytes were not persisted or displayed.

The inherited-material regression is also covered by:

```sh
tests/fm-secondmate-harness.test.sh
```

That test proves byte-exact propagation, primary-absence convergence, rejection of malformed opt-in files, and preservation of the last validated destination.

## Intentionally unperformed checks

Do not run `claude setup-token`, `av save CLAUDE_CODE_OAUTH_TOKEN`, or an enabled preflight with a real secret as part of automated validation, CI, review, or no-mistakes.
The implementation therefore does not prove that a particular captain Vault is unlocked, that Secret Gate policy currently permits a particular launch, that a real `CLAUDE_CODE_OAUTH_TOKEN` exists, or that a real subscription token is presently valid.
Those facts remain intentionally unproven until the captain runs `bin/fm-claude-automic-vault.sh provision` in an attended terminal after merge.
Remote Automic Vault availability and remote token provisioning also remain unproven and must be established independently on each remote host before that host can launch a Claude worker with the inherited opt-in.
The accepted threat model assumes same-user process integrity, so TOCTOU attacks by another process running as the same user remain intentionally unproven and out of scope by captain decision on 2026-09-02.
