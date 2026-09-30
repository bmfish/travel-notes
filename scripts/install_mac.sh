#!/bin/bash
# 构建 Mac Catalyst 版并安装到 /Applications(Spotlight/Launchpad 可搜「高铁笔记」或 TravelNotes)
# 用法:scripts/install_mac.sh
set -euo pipefail
cd "$(dirname "$0")/.."

xcodebuild -project TravelNotes.xcodeproj -scheme TravelNotes \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /tmp/tn_dd build -quiet

# 覆盖安装:同 bundle id,App 沙盒数据(数据库/照片)不受影响
rm -rf /Applications/TravelNotes.app
cp -R /tmp/tn_dd/Build/Products/Debug-maccatalyst/TravelNotes.app /Applications/
echo "已安装到 /Applications/TravelNotes.app(Spotlight 搜「高铁笔记」)"
