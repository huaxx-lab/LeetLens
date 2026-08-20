#!/bin/zsh

# 打包可发布的原生客户端：.app + zip + dmg。
#
# 和 build-preview-app.sh 的区别只有身份与配置：这里是 release 构建、正式的
# 显示名与 bundle id，并额外产出可直接分发的压缩包与磁盘映像。
# 数据目录不跟 bundle id 走（固定 ~/Library/Application Support/leetcode-ai-helper），
# 所以从 Preview 换到正式版不会丢数据。

set -euo pipefail

SCRIPT_DIR=${0:A:h}
NATIVE_DIR=${SCRIPT_DIR:h}
REPO_DIR=${NATIVE_DIR:h}

APP_NAME=${APP_NAME:-LeetLens}
BUNDLE_ID=${BUNDLE_ID:-io.github.huaxxlab.leetcode-ai-helper.native}
SHORT_VERSION=${SHORT_VERSION:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" ${NATIVE_DIR}/App/Info.plist)}

# 只装了 Command Line Tools 时 xcode-select 给的目录没有 SwiftUI 宏插件，构建会失败。
SELECTED_DEVELOPER_DIR=$(xcode-select -p 2>/dev/null || true)
if [[ -z ${XCODE_PATH:-} ]]; then
    if [[ ${SELECTED_DEVELOPER_DIR} == */Contents/Developer ]]; then
        XCODE_PATH=${SELECTED_DEVELOPER_DIR%/Contents/Developer}
    else
        XCODE_PATH=/Applications/Xcode.app
    fi
fi
DEVELOPER_DIR=${XCODE_PATH}/Contents/Developer

if [[ ! -d ${DEVELOPER_DIR} ]]; then
    print -u2 "找不到 Xcode：${XCODE_PATH}"
    print -u2 "可通过 XCODE_PATH=/path/to/Xcode.app 指定位置。"
    exit 1
fi

DIST_DIR=${NATIVE_DIR}/dist
STAGE_ROOT=${TMPDIR:-/tmp}/leetcode-ai-helper-release-stage
STAGE_APP=${STAGE_ROOT}/${APP_NAME}.app
CONTENTS_PATH=${STAGE_APP}/Contents
# 仓库常放在 iCloud/文件提供程序托管的目录里，资源包会长出扩展属性导致签名失败，
# 所以构建目录一律放到临时区。
SCRATCH_PATH=${TMPDIR:-/tmp}/leetcode-ai-helper-release-build
ICONSET_PATH=${NATIVE_DIR}/IconSources/AppIcon.iconset

cd ${NATIVE_DIR}
DEVELOPER_DIR=${DEVELOPER_DIR} xcrun swift ${NATIVE_DIR}/scripts/generate-app-icon.swift
# macOS 27 只把新的窗口外观（圆角玻璃标题栏 + 系统红绿灯）给「链接到 27 SDK」的 app，
# 判据是 LC_BUILD_VERSION 里的 sdk 字段（dyld_program_sdk_at_least）。SwiftPM 会把它写成
# 部署目标（Package.swift 的 .macOS(.v15)），于是我们拿到的是兼容路径下的老式标题栏——
# 全屏时红绿灯画得出来、悬停有反馈，但点下去没反应。
# 这里只改记录的 SDK 版本，minos 仍是 15.0，不影响可运行的系统下限。
MACOS_SDK_VERSION=$(DEVELOPER_DIR=${DEVELOPER_DIR} xcrun --sdk macosx --show-sdk-version)
MACOS_MIN_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' ${NATIVE_DIR}/App/Info.plist)
COPYFILE_DISABLE=1 DEVELOPER_DIR=${DEVELOPER_DIR} xcrun swift build -c release --scratch-path ${SCRATCH_PATH} \
    -Xlinker -platform_version -Xlinker macos \
    -Xlinker ${MACOS_MIN_VERSION} -Xlinker ${MACOS_SDK_VERSION}

rm -rf ${STAGE_APP}
mkdir -p ${CONTENTS_PATH}/MacOS ${CONTENTS_PATH}/Resources
cp ${SCRATCH_PATH}/release/LeetCodeAssistant ${CONTENTS_PATH}/MacOS/LeetCodeAssistant
cp ${NATIVE_DIR}/App/Info.plist ${CONTENTS_PATH}/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${APP_NAME}" ${CONTENTS_PATH}/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" ${CONTENTS_PATH}/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${SHORT_VERSION}" ${CONTENTS_PATH}/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M%S)" ${CONTENTS_PATH}/Info.plist

for RESOURCE_BUNDLE in ${SCRATCH_PATH}/release/*.bundle; do
    [[ -d ${RESOURCE_BUNDLE} ]] || continue
    cp -R ${RESOURCE_BUNDLE} ${CONTENTS_PATH}/Resources/
done

if [[ ! -d ${ICONSET_PATH} ]]; then
    print -u2 "找不到图标源：${ICONSET_PATH}"
    exit 1
fi
xcrun iconutil --convert icns --output ${CONTENTS_PATH}/Resources/AppIcon.icns ${ICONSET_PATH}

xattr -cr ${STAGE_APP}
# 钥匙串里有 Developer ID 就用它，否则本地 ad-hoc 签名（首次打开需右键「打开」）。
SIGN_IDENTITY=${MAC_CODE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')}
SIGN_IDENTITY=${SIGN_IDENTITY:--}
codesign --force --deep --options runtime --sign ${SIGN_IDENTITY} ${STAGE_APP} 2>/dev/null \
    || codesign --force --deep --sign - ${STAGE_APP}
codesign --verify --deep --strict ${STAGE_APP}

rm -rf ${DIST_DIR}
mkdir -p ${DIST_DIR}
APP_PATH=${DIST_DIR}/${APP_NAME}.app
ditto --norsrc --noextattr ${STAGE_APP} ${APP_PATH}
xattr -cr ${APP_PATH}
codesign --verify --deep --strict ${APP_PATH}

ZIP_PATH=${DIST_DIR}/LeetLens-mac-arm64.zip
ditto -c -k --sequesterRsrc --keepParent ${APP_PATH} ${ZIP_PATH}

# DMG：拖进「应用程序」即可安装。
DMG_STAGE=${STAGE_ROOT}/dmg
DMG_PATH=${DIST_DIR}/LeetLens-mac-arm64.dmg
rm -rf ${DMG_STAGE}
mkdir -p ${DMG_STAGE}
ditto --norsrc --noextattr ${APP_PATH} ${DMG_STAGE}/${APP_NAME}.app
ln -s /Applications ${DMG_STAGE}/Applications
hdiutil create -volname ${APP_NAME} -srcfolder ${DMG_STAGE} -ov -format UDZO ${DMG_PATH} >/dev/null

print ${APP_PATH}
print ${ZIP_PATH}
print ${DMG_PATH}
