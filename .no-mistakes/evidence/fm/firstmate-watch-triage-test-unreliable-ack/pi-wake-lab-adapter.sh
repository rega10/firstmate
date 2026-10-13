#!/usr/bin/env bash
set -eu
[ "$FM_HOME" = "$FM_VALIDATION_LAB" ]
[ "$(cat "$FM_HOME/.fm-lab-home")" = 'fm-lab-home v1' ]
exec env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE "$FM_VALIDATION_CODE/bin/fm-watch-arm.sh" "$@"
