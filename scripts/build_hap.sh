#!/bin/bash
set -euo pipefail
project="${1:-.work/client}"
studio="${DEVECO_STUDIO_HOME:-/Applications/DevEco-Studio.app/Contents}"
export PATH="$studio/tools/node/bin:$studio/tools/ohpm/bin:$PATH"
export DEVECO_SDK_HOME="$studio/sdk"
export JAVA_HOME="$studio/jbr/Contents/Home"
if [ ! -x "$JAVA_HOME/bin/java" ]; then export JAVA_HOME="$studio/jbr"; fi
cd "$project"
ohpm install
node "$studio/tools/hvigor/bin/hvigorw.js" --mode module -p module=entry -p product=default assembleHap --no-daemon
