# Worker launch validation

Normal launches made one announced origin contact. All live scenarios passed.

The checks used real Treehouse and Herdr, disposable local Git remotes, and shell workers. They did not request production credentials or device approvals.

| Scenario | Origin contacts | Result | Evidence |
| --- | ---: | --- | --- |
| A new worker uses one announced contact and runs setup at the current default tip. | 1 | Pass | [live-common.log](live-common.log) |
| A reused slot uses one announced contact and runs setup at the current default tip. | 1 | Pass | [live-reused.log](live-reused.log) |
| A moved remote default selects trunk after one announced contact. | 1 | Pass | [live-moved-on.log](live-moved-on.log) |
| Disabled reflogs require two announced contacts and still select trunk. | 2 | Pass | [live-moved-off.log](live-moved-off.log) |
| A named base selects feature/hub after one announced fetch. | 1 | Pass | [live-named.log](live-named.log) |
| A narrow fetch uses three announced contacts and selects the refreshed default. | 3 | Pass | [live-narrow.log](live-narrow.log) |
| A shared slot from another clone refreshes its repository and launches the default tip. | 2 | Pass | [live-shared-default.log](live-shared-default.log) |
| A shared slot from another clone launches the named base after two announced contacts. | 2 | Pass | [live-shared-named.log](live-shared-named.log) |
| A shared slot with narrow fetches launches the refreshed tip after six announced contacts. | 6 | Pass | [live-shared-narrow.log](live-shared-narrow.log) |
| An unresolved remote default refuses despite a remembered main. | 2 | Pass | [live-unresolved-normal.log](live-unresolved-normal.log) |
| An unresolved remote default refuses when its own reflog is empty and main advances. | 2 | Pass | [live-unresolved-empty.log](live-unresolved-empty.log) |
| A missing named base refuses and leaves no worker record. | 1 | Pass | [live-missing.log](live-missing.log) |
| An unreachable origin refuses after one announced attempt. | 1 | Pass | [live-unreachable.log](live-unreachable.log) |
| A held legacy slot refuses before any origin contact. | 0 | Pass | [live-held.log](live-held.log) |
| Treehouse preserves an existing dirty slot and launches another clean slot. | 1 | Pass | [live-dirty.log](live-dirty.log) |
| A setup hook returning a dirty slot makes spawn refuse before worker launch. | 1 | Pass | [live-dirty-hook.log](live-dirty-hook.log) |
| A project without origin launches its unchanged local commit without origin contact. | 0 | Pass | [live-originless.log](live-originless.log) |

The focused `tests/fm-spawn-pool-base-freshen.test.sh --origin-contacts` regressions also passed.

All Herdr sessions were isolated, named, and deleted. The helper verified the default session remained unchanged.
