#!/usr/bin/env bash
# CPE Monitor 分发打包：产出可以直接发给别人的 DMG + ZIP
#
#   ./package.sh                                    # 打包（ad-hoc 签名）
#   ./package.sh --sign "Developer ID Application: 张三 (ABCDE12345)"
#   ./package.sh --sign "..." --notarize cpe-monitor  # 公证（需先存好 notarytool 凭据）
#   ./package.sh --no-build                         # 复用现有 dist/ 不重新编译
#
# 未签名/未公证的版本对方双击会被 Gatekeeper 拦一次，
# DMG 里附了《使用说明.txt》，照着一行 xattr 命令放行即可。

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="CPE Monitor"
EXEC_NAME="CPEMonitor"
DIST_DIR="dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
STAGE_DIR="${DIST_DIR}/dmg-stage"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
VOL_NAME="${APP_NAME} ${VERSION}"

SIGN_ID=""
NOTARY_PROFILE=""
DO_BUILD=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign) SIGN_ID="${2:-}"; shift 2 ;;
    --notarize) NOTARY_PROFILE="${2:-}"; shift 2 ;;
    --no-build) DO_BUILD=0; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

# ---------- 1. 构建 ----------
if [[ "${DO_BUILD}" == "1" ]]; then
  # 必须用 --universal：单架构 arm64 在 Intel Mac 上打不开（Rosetta 不反向翻译）
  echo "==> 1/6 构建 ${VERSION}（arm64 + x86_64）"
  ./build.sh --universal >/dev/null
else
  echo "==> 1/6 跳过构建（沿用现有 ${APP_DIR}）"
fi

if [[ ! -d "${APP_DIR}" ]]; then
  echo "!! 找不到 ${APP_DIR}，请先 ./build.sh --universal" >&2
  exit 1
fi

if ! lipo -info "${APP_DIR}/Contents/MacOS/${EXEC_NAME}" 2>/dev/null | grep -q "x86_64"; then
  echo "⚠️  当前是单架构二进制，Intel Mac 用不了。建议 ./package.sh（会带 --universal）"
fi

# ---------- 2. 签名 ----------
if [[ -n "${SIGN_ID}" ]]; then
  echo "==> 2/6 用 Developer ID 签名（含 hardened runtime，可公证）"
  # 证书不需要 --deep；App 里没有嵌套的可执行代码
  codesign --force --options runtime --timestamp \
           --sign "${SIGN_ID}" "${APP_DIR}"
  codesign --verify --strict --verbose=2 "${APP_DIR}"
else
  echo "==> 2/6 使用 ad-hoc 签名（build.sh 已完成）"
  echo "    提示：想免去对方手动放行，需要 Apple 开发者账号："
  echo "    ./package.sh --sign \"Developer ID Application: 你的名字 (TEAMID)\" --notarize <profile>"
fi

# ---------- 3. 公证（可选） ----------
if [[ -n "${NOTARY_PROFILE}" ]]; then
  echo "==> 3/6 公证 App（notarytool，可能要等几分钟）"
  ZIP_FOR_NOTARY="${DIST_DIR}/${EXEC_NAME}-notary.zip"
  rm -f "${ZIP_FOR_NOTARY}"
  ditto -c -k --keepParent "${APP_DIR}" "${ZIP_FOR_NOTARY}"
  xcrun notarytool submit "${ZIP_FOR_NOTARY}" \
        --keychain-profile "${NOTARY_PROFILE}" --wait
  xcrun stapler staple "${APP_DIR}"
  xcrun stapler validate "${APP_DIR}"
  rm -f "${ZIP_FOR_NOTARY}"
  echo "    App 已装订公证票据，离线也能通过 Gatekeeper"
else
  echo "==> 3/6 跳过公证"
fi

# ---------- 4. 打包 ZIP ----------
echo "==> 4/6 打包 ZIP"
ZIP_PATH="${DIST_DIR}/${APP_NAME} ${VERSION}.zip"
rm -f "${ZIP_PATH}"
ditto -c -k --sequesterRsrc --keepParent "${APP_DIR}" "${ZIP_PATH}"

# ---------- 5. 打包 DMG ----------
echo "==> 5/6 打包 DMG"
rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}"
cp -R "${APP_DIR}" "${STAGE_DIR}/"
ln -s /Applications "${STAGE_DIR}/Applications"
cp tools/使用说明.txt "${STAGE_DIR}/使用说明.txt" 2>/dev/null || true

DMG_PATH="${DIST_DIR}/${APP_NAME} ${VERSION}.dmg"
rm -f "${DMG_PATH}"
hdiutil create \
  -volname "${VOL_NAME}" \
  -srcfolder "${STAGE_DIR}" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "${DMG_PATH}" >/dev/null

if [[ -n "${SIGN_ID}" ]]; then
  codesign --force --timestamp --sign "${SIGN_ID}" "${DMG_PATH}"
fi

if [[ -n "${NOTARY_PROFILE}" ]]; then
  echo "    公证 DMG…"
  xcrun notarytool submit "${DMG_PATH}" \
        --keychain-profile "${NOTARY_PROFILE}" --wait
  xcrun stapler staple "${DMG_PATH}"
fi

rm -rf "${STAGE_DIR}"

# ---------- 6. 校验信息 ----------
echo "==> 6/6 产出"
shasum -a 256 "${DMG_PATH}" "${ZIP_PATH}" | tee "${DIST_DIR}/SHA256.txt"
echo ""
ls -lh "${DMG_PATH}" "${ZIP_PATH}" | awk '{print "   " $9 "  " $5}'
echo ""
echo "分发件已就绪："
echo "  ${DMG_PATH}   ← 推荐发给别人（双击挂载后把 App 拖进 Applications）"
echo "  ${ZIP_PATH}   ← 备用，对方网络环境丢包时更好传"
echo ""
if [[ -z "${SIGN_ID}" ]]; then
  echo "⚠️  当前是 ad-hoc 签名，对方第一次打开需要在"
  echo "   系统设置 → 隐私与安全性 → 「仍要打开」，"
  echo "   或在终端执行：xattr -dr com.apple.quarantine \"/Applications/${APP_NAME}.app\""
fi
