#!/usr/bin/env bash
# Copies the openclicky tool that agent tasks run through into the app's
# Contents/Resources/agent-tool, laid out like the repository because the tool finds config/ and
# skills/ from where it sits. Run by the OpenClicky target's "Embed agent tool" build phase; needs
# `npm run build -w agent` first, which release.sh does. A plain Xcode build without it just warns.
set -euo pipefail

project_dir="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
repository="$project_dir/../.."
# Outside a build (run by hand) there is nowhere to copy to.
[[ -n "${TARGET_BUILD_DIR:-}" ]] || exit 0

destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/agent-tool"
# Rebuilt from scratch each time, so a file deleted from the repository leaves the app too.
rm -rf "$destination"
if [[ ! -f "$repository/agent/dist/cli.js" ]]; then
  echo "warning: agent/dist is not built (npm run build -w agent), so this build has no agent tool"
  exit 0
fi
mkdir -p "$destination/agent/dist" "$destination/agent/node_modules" "$destination/config" "$destination/macos/OpenClicky"
find "$repository/agent/dist" -maxdepth 1 -name '*.js' -exec cp {} "$destination/agent/dist/" \;
cp "$repository/agent/package.json" "$destination/agent/"
cp -R "$repository/node_modules/commander" "$destination/agent/node_modules/"
cp "$repository/config/codex-config.toml" "$destination/config/"
cp -R "$repository/skills" "$destination/"
cp "$project_dir/VERSION" "$destination/macos/OpenClicky/"
echo "embedded the agent tool"
