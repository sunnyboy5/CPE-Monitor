#!/usr/bin/env bash
# CPE Monitor 打包脚本
# 仅依赖 CommandLineTools，无需完整 Xcode。
#
#   ./build.sh                       构建并打包到 dist/CPE Monitor.app
#   ./build.sh --universal           构建 arm64 + x86_64 通用二进制（发给别人用）
#   ./build.sh --install             构建后安装到 /Applications
#   ./build.sh --run                 构建后直接运行
#   ./build.sh --demo                独立窗口 + 演示数据启动（无需设备）
#   ./build.sh --universal --install 组合使用

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="CPE Monitor"
EXEC_NAME="CPEMonitor"
BUNDLE_ID="com.udx710.cpemonitor"
CONFIG="release"
DIST_DIR="dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"

UNIVERSAL=0
ACTION=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --universal) UNIVERSAL=1; shift ;;
    --install|--run|--demo) ACTION="$1"; shift ;;
    *) EXTRA_ARGS+=("$1"); shift ;;
  esac
done

# ---------- 编译 ----------
BIN_PATH=""
if [[ "${UNIVERSAL}" == "1" ]]; then
  # 别人可能用 Intel Mac：单架构 arm64 在 Intel 机器上直接打不开（Rosetta 不反向翻译）
  echo "==> 编译 (${CONFIG}, arm64 + x86_64 通用二进制)"
  swift build -c "${CONFIG}" --arch arm64 --disable-sandbox
  swift build -c "${CONFIG}" --arch x86_64 --disable-sandbox

  ARM_BIN=".build/arm64-apple-macosx/${CONFIG}/${EXEC_NAME}"
  X86_BIN=".build/x86_64-apple-macosx/${CONFIG}/${EXEC_NAME}"
  for f in "${ARM_BIN}" "${X86_BIN}"; do
    if [[ ! -f "${f}" ]]; then
      echo "!! 缺少 ${f}（x86_64 交叉编译需要 CommandLineTools 里带 x86_64 SDK）" >&2
      exit 1
    fi
  done

  BIN_PATH="${DIST_DIR}/universal/${EXEC_NAME}"
  mkdir -p "$(dirname "${BIN_PATH}")"
  lipo -create "${ARM_BIN}" "${X86_BIN}" -output "${BIN_PATH}"
  lipo -info "${BIN_PATH}"
else
  echo "==> 编译 (${CONFIG})"
  # --disable-sandbox: 部分受限环境下 SwiftPM 的 manifest 沙箱会被系统拦截
  swift build -c "${CONFIG}" --disable-sandbox
  BIN_PATH="$(swift build -c "${CONFIG}" --disable-sandbox --show-bin-path)/${EXEC_NAME}"
fi

if [[ ! -f "${BIN_PATH}" ]]; then
  echo "!! 未找到可执行文件: ${BIN_PATH}" >&2
  exit 1
fi

# ---------- 组装 .app ----------
echo "==> 组装 .app"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${EXEC_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${EXEC_NAME}"
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"

# 应用图标
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi

# 运营商真图标：运行时按 Bundle.main → Resources/Carriers/<name>.png 读取
if [[ -d Resources/Carriers ]]; then
  cp -R Resources/Carriers "${APP_DIR}/Contents/Resources/Carriers"
fi

echo "==> 去除隔离属性并进行 ad-hoc 签名"
xattr -cr "${APP_DIR}" 2>/dev/null || true
codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null || \
  echo "   (跳过签名，未签名也能本机运行)"

echo "==> 完成: ${APP_DIR}"

case "${ACTION}" in
  --install)
    echo "==> 安装到 /Applications"
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${APP_DIR}" "/Applications/"
    open "/Applications/${APP_NAME}.app" --args "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
    ;;
  --run)
    echo "==> 启动"
    open "${APP_DIR}" --args "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
    ;;
  --demo)
    echo "==> 以独立窗口 + 演示数据启动（无需设备）"
    open "${APP_DIR}" --args --window --mock
    ;;
esac
