#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
NATIVE_DIR=${SCRIPT_DIR:h}
# 默认用系统当前选中的 Xcode；只装了 Command Line Tools 时它给的是
# /Library/Developer/CommandLineTools，那里没有 SwiftUI 的宏插件，构建会失败，
# 所以回退到标准安装位置。Xcode 装在别处（比如并存的 beta）就用 XCODE_PATH 指过去。
SELECTED_DEVELOPER_DIR=$(xcode-select -p 2>/dev/null || true)
if [[ -z ${XCODE_PATH:-} ]]; then
    if [[ ${SELECTED_DEVELOPER_DIR} == */Contents/Developer ]]; then
        XCODE_PATH=${SELECTED_DEVELOPER_DIR%/Contents/Developer}
    else
        XCODE_PATH=/Applications/Xcode.app
    fi
fi
DEVELOPER_DIR=${XCODE_PATH}/Contents/Developer
APP_PATH=${NATIVE_DIR}/.build/LeetCode\ AI\ 助手\ Preview.app
STAGE_ROOT=${TMPDIR:-/tmp}/leetcode-ai-helper-preview-stage
STAGE_APP=${STAGE_ROOT}/LeetCode\ AI\ 助手\ Preview.app
CONTENTS_PATH=${STAGE_APP}/Contents
SCRATCH_PATH=${TMPDIR:-/tmp}/leetcode-ai-helper-native-build
ICONSET_PATH=${NATIVE_DIR}/IconSources/AppIcon.iconset

if [[ ! -d ${DEVELOPER_DIR} ]]; then
    print -u2 "找不到 Xcode：${XCODE_PATH}"
    print -u2 "可通过 XCODE_PATH=/path/to/Xcode.app 指定位置。"
    exit 1
fi

cd ${NATIVE_DIR}
DEVELOPER_DIR=${DEVELOPER_DIR} xcrun swift ${NATIVE_DIR}/scripts/generate-app-icon.swift
COPYFILE_DISABLE=1 DEVELOPER_DIR=${DEVELOPER_DIR} xcrun swift build -c debug --scratch-path ${SCRATCH_PATH}

rm -rf ${STAGE_APP}
mkdir -p ${CONTENTS_PATH}/MacOS ${CONTENTS_PATH}/Resources
cp ${SCRATCH_PATH}/out/Products/Debug/LeetCodeAssistant ${CONTENTS_PATH}/MacOS/LeetCodeAssistant
cp ${NATIVE_DIR}/App/Info.plist ${CONTENTS_PATH}/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M%S)" ${CONTENTS_PATH}/Info.plist

for RESOURCE_BUNDLE in ${SCRATCH_PATH}/out/Products/Debug/*.bundle; do
    [[ -d ${RESOURCE_BUNDLE} ]] || continue
    cp -R ${RESOURCE_BUNDLE} ${CONTENTS_PATH}/Resources/
done

if [[ ! -d ${ICONSET_PATH} ]]; then
    print -u2 "找不到 LeetCode 助手图标源：${ICONSET_PATH}"
    exit 1
fi
xcrun iconutil --convert icns --output ${CONTENTS_PATH}/Resources/AppIcon.icns ${ICONSET_PATH}

xattr -cr ${STAGE_APP}
codesign --force --deep --sign - ${STAGE_APP}
codesign --verify --deep --strict ${STAGE_APP}
rm -rf ${APP_PATH}
ditto --norsrc --noextattr ${STAGE_APP} ${APP_PATH}
xattr -cr ${APP_PATH}
codesign --verify --deep --strict ${APP_PATH}
print ${APP_PATH}
