#!/bin/bash
# The main ruleset requires the check names "Build & test", "Package Toolbox.app" and "Lint & format". The jobs that do that
# work need a macOS runner and are skipped when a PR cannot affect the app. GitHub counts a skipped job as a passed required
# check whatever the reason it was skipped, so the required names belong to ubuntu jobs that run this and pass only for the
# two results that are safe to merge.
set -euo pipefail

if [ "$JOB_RESULT" = "success" ]; then
  echo "$JOB_NAME passed."
  exit 0
fi

if [ "$JOB_RESULT" = "skipped" ] && [ "$CHANGES_RESULT" = "success" ] && [ "$APP_AFFECTED" = "false" ]; then
  echo "No app changes; $JOB_NAME had nothing to check and was skipped."
  exit 0
fi

echo "::error::$JOB_NAME did not pass: its result is '$JOB_RESULT' (changed-paths job: '$CHANGES_RESULT', app affected: '$APP_AFFECTED')."
exit 1
