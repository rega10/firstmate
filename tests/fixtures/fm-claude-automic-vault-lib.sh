#!/usr/bin/env bash
set -u
: "${FM_CLAUDE_AV_TEST_PRODUCTION_ROOT:?}"
: "${FM_CLAUDE_AV_TEST_CURL_BIN:?}"
: "${FM_CLAUDE_AV_TEST_MANIFEST_CHECKSUMS:?}"
# shellcheck disable=SC1090
. "$FM_CLAUDE_AV_TEST_PRODUCTION_ROOT/bin/fm-claude-automic-vault-lib.sh"
FM_CLAUDE_AV_CURL_BIN=$FM_CLAUDE_AV_TEST_CURL_BIN
FM_CLAUDE_AV_MANIFEST_CHECKSUMS=$FM_CLAUDE_AV_TEST_MANIFEST_CHECKSUMS
eval "$(declare -f fm_claude_av_launch_environment_names | sed '1s/fm_claude_av_launch_environment_names/fm_claude_av_production_launch_environment_names/')"
fm_claude_av_launch_environment_names() {
  fm_claude_av_production_launch_environment_names
  printf '%s\n' \
    FM_FAKE_AV_BLOCK_FILE FM_FAKE_AV_FAIL_AT FM_FAKE_AV_HELP_MODE FM_FAKE_AV_MODE \
    FM_FAKE_AV_SWAP_SOURCE FM_FAKE_AV_SWAP_TARGET FM_FAKE_CLAUDE_HELP_MODE \
    FM_FAKE_CLAUDE_MODE FM_FAKE_SETUP_MODE FM_FAKE_STATE \
    FM_FAKE_SWAP_MARKER FM_HOSTILE_LEAK
}
