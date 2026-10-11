#!/bin/bash
# Download the upstream GUI only. Pairing and file export remain user actions.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077

VERSION=1.1.0
URL="https://github.com/jkcoxson/idevice_pair/releases/download/v${VERSION}/idevice_pair--macos-universal.dmg"
SHA256=9ff54171dccdb0a9b0e72ec89e43a479823c53ee54c2121fe9f053cc2cb940ce
PARTIAL=''
MODE=open

usage() {
    cat <<'TEXT'
PocketAgent：下载官方 Mac 配对工具（Apple Silicon / Intel 通用）

用法：bash Scripts/download_pairing_tool.command [--download-only]
      bash Scripts/download_pairing_tool.command --verify 下载的工具.dmg

默认：下载固定版本、校验 SHA-256，然后打开磁盘映像。
--download-only：只下载并校验，不打开界面。
--verify：只校验指定文件，不下载、不修改文件。
此脚本不会生成/读取配对文件，也不会修改手机或安装软件。
TEXT
}

fail() { printf '%s\n' "$*" >&2; exit 1; }
verify() {
    [[ -f "$1" && ! -L "$1" ]] || fail '校验失败：请选择普通 DMG 文件。'
    local actual
    actual=$(shasum -a 256 -- "$1")
    actual=${actual%% *}
    [[ "$actual" == "$SHA256" ]] || fail 'SHA-256 不匹配。没有打开或安装这个文件，请重新从官方地址下载。'
}

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h) [[ $# == 1 ]] || fail '参数不正确。'; usage; exit 0 ;;
        --download-only) [[ $# == 1 ]] || fail '参数不正确。'; MODE=download ;;
        --verify) [[ $# == 2 ]] || fail '请提供要校验的 DMG 文件。'; verify "$2"; printf 'SHA-256 校验通过。\n'; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
fi

[[ $(uname -s) == Darwin ]] || fail '此下载脚本适用于 macOS。其他平台请查看 idevice_pair 官方项目。'
[[ -d "$HOME/Downloads" ]] || fail '没有找到“下载”文件夹，请使用教程中的官方 DMG 下载链接。'
DIR=$(mktemp -d "$HOME/Downloads/PocketAgent-Setup.XXXXXX")
PARTIAL="$DIR/tool.download"
trap 'if [[ -n "$PARTIAL" ]]; then rm -f -- "$PARTIAL"; fi' EXIT
printf '正在下载 idevice_pair %s（官方通用版）…\n' "$VERSION"
curl --disable --fail --location --retry 2 --connect-timeout 20 --max-time 300 \
    --proto '=https' --proto-redir '=https' --output "$PARTIAL" "$URL" \
    || fail '下载失败。请检查网络，或使用教程中的官方 DMG 下载链接。'
verify "$PARTIAL"
DMG="$DIR/idevice_pair-v${VERSION}.dmg"
mv -- "$PARTIAL" "$DMG"
PARTIAL=''
mkdir "$DIR/Pairing"
printf '\nSHA-256 校验通过。文件：%s\n' "$DMG"
printf '配对文件可另存到这个新建的私有文件夹：%s\n\n' "$DIR/Pairing"
cat <<'TEXT'
下一步：
1. 打开 DMG，把 idevice_pair 拖到 Applications，再打开它。
2. USB 连接目标 iPhone，解锁，并在手机上点“信任”。
3. 选中目标手机，选择 Remote pairing，点 Create，再点 Validate。
4. 点 Save to file…，另存为新的 pairingFile.plist 或 rp_pairing_file.plist。
5. AirDrop 到手机 → 存储到“文件” → 在 PocketAgent 设置中导入。

要选择 Remote pairing；Lockdown / SideStore 配对文件不适用于 PocketAgent。
此 GUI 会检查开发者模式、准备开发者镜像，并启用该手机的无线调试。
配对文件含私钥，请勿上传 GitHub 或分享。不要覆盖之前保留的有效文件。
教程：https://github.com/Borealin/PocketAgent/blob/main/docs/pairing-zh.md
TEXT
if [[ "$MODE" == open ]]; then
    open "$DMG" || fail '下载和校验已完成；系统未能打开 DMG，请在 Finder 中手动打开上面的文件。'
fi
