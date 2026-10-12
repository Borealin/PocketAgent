# 在 Mac 上生成并导入 PocketAgent 配对文件

可以使用另一台 Mac，不必是安装 IPA 的那台，也不需要相同的 Apple ID、
开发者账号或签名证书。配对通过这台 iPhone 信任的 USB 连接建立，文件属于
这台 iPhone。生成并导入后，手机操作不需要 Mac 持续连接。

Mac 需要能正常识别、信任目标 iPhone。下面的官方工具是 Apple Silicon / Intel
通用版；建议使用仍在维护的 macOS。通用二进制不代表所有旧 macOS 和所有
iOS 版本组合都经过 PocketAgent 验证。手机需设置解锁密码；使用 PocketAgent
手机操作还需打开开发者模式、安装同版本 Automation，并连接 LocalDevVPN。

## 1. 下载 Mac 图形化工具

[下载 idevice_pair v1.1.0 通用版 DMG](https://github.com/jkcoxson/idevice_pair/releases/download/v1.1.0/idevice_pair--macos-universal.dmg)
· [官方发布页](https://github.com/jkcoxson/idevice_pair/releases/tag/v1.1.0)

打开 DMG，把 `idevice_pair` 拖到 Applications，再打开。使用发布包不需要
安装 Rust、Python 或 Xcode。若 macOS 阻止打开，先确认下载来自上述官方
发布页，然后按系统的“隐私与安全性”提示处理；不要关闭 Gatekeeper。

仓库也提供 [下载脚本](../Scripts/download_pairing_tool.command)：只用 macOS 自带
工具下载固定版本、核对 SHA-256，并打开 DMG。不自动安装软件、不生成配对、
不改手机配置。下载仓库 ZIP 并解压后，可在终端运行：

```sh
bash Scripts/download_pairing_tool.command
```

不在仓库目录时，把脚本文件拖入终端，在其路径前加 `bash ` 即可。
`--download-only` 只下载并校验；`--verify 文件路径` 只校验已下载的 DMG。
脚本会在“下载”里新建独立文件夹，并提供一个权限为 0700 的 `Pairing` 子目录
供另存文件；它不会覆盖已有配对文件。

固定发布包的 SHA-256：

```text
9ff54171dccdb0a9b0e72ec89e43a479823c53ee54c2121fe9f053cc2cb940ce
```

## 2. 用 USB 为目标 iPhone 创建 Remote pairing

1. 用支持数据传输的 USB 线连接 iPhone，保持解锁、停在主屏幕。
2. 如果出现“信任此电脑”，在手机上点“信任”，并在手机上输入解锁密码。
3. 在 `idevice_pair` 的设备下拉列表中选中这台手机，确认选择 USB 连接。
   多台手机连接时要核对目标；初次操作可只连接这一台。
4. 选择 **Remote pairing**，点 **Create**。手机可能再次显示
   **Trust This Computer?**，请求方类似 `idevice_pair-xxxxxx`。这是新的 RP
   配对身份，即使刚才已经信任 USB 连接，也可能需要在手机上再次点 **Trust**，
   并按系统要求输入解锁密码；密码只在手机上输入。
5. 完成手机上的信任步骤，等待成功，再点 **Validate** 验证这个记录能连接本机。
6. 点 **Save to file…**，另存到一个新文件，例如 `pairingFile.plist`。
   也可以命名为 `rp_pairing_file.plist`；导入时校验内容，不限制文件名。

这里必须选择 **Remote pairing**。**Lockdown** 是 SideStore 等使用的 USB
配对格式，不能直接导入 PocketAgent；改文件名也不能转换格式。

该 GUI 的 v1.1.0 会在检查 USB 设备时检查开发者模式、按需个性化挂载自带的
开发者镜像，并启用该手机的无线调试。镜像个性化可能需要联网，让它完成后
再 Create。本教程使用 USB 流程；工具的 iOS 27 Wi-Fi 配对入口未在本项目验证。

配对文件包含私钥。只保存在自己的设备，不上传 GitHub，不发送给他人。
GUI 的“Save to file”可能覆盖所选文件，务必选新文件；重新创建时可先退出
再打开工具，不要覆盖之前保存的有效记录。不要分享显示文件内容的截图或日志。

## 3. 传到手机并导入

1. 在 Mac 的 Finder 选中生成的 plist，通过 AirDrop 发给目标 iPhone。
2. 在 iPhone 上选择“存储到文件”。其他传输方式也可以，最终让它出现在
   “文件”App 中。
3. 打开 PocketAgent → 左上角列表 → **设置**。
   - 已发布的 **0.3.1**：**设备配对 → 导入配对文件…**。
   - **0.3.2**（目前待发布，测试设备已安装）：**手机操作配置 → 从“文件”导入配对文件…**。
4. 选择刚传来的 plist，确认导入成功。
5. 连接 LocalDevVPN，保持手机解锁。0.3.2 可点 **检查连接**，检查已保存的
   配对和 VPN；这一步不会启动 Automation 或打开其他 App。

同一文件只能用于它配对的那台 iPhone。更换手机要为新手机生成文件。
已有正常工作的配对不需要因换 Mac 或升级 PocketAgent 而重新生成。
导入后的记录只保存在 PocketAgent 本机受保护的存储中，不参与 iCloud 同步
或备份；Mac 上导出的原文件由你保管。

首次运行手机操作时，iOS 可能显示 **Enable UI Automation / XCTest**，需要
在手机的系统页面输入解锁密码。它与本节的文件导入是两个步骤。

## 常见问题

| 现象 | 处理 |
|---|---|
| Mac 不显示手机 | 换数据线或 USB 口，解锁手机，在 Finder 中确认能识别，并完成“信任此电脑”。 |
| Create 失败或开发者镜像未准备好 | 检查手机开发者模式，保持解锁和网络连接，等待自带镜像个性化挂载完成；重新连接再试。 |
| Create 一直显示 Trust this computer on your device | 查看手机上的第二个 RP 信任弹窗，核对请求方为本次 idevice_pair，点 Trust 并完成系统密码步骤。USB 信任和 RP 信任是两个阶段。 |
| 导入提示 SideStore / Lockdown 格式 | 回到工具选择 Remote pairing，重新 Create、Validate、Save；不是更改扩展名。 |
| 导入成功但连接失败 | 核对文件属于这台手机，LocalDevVPN 显示 Connected，手机未锁屏。0.3.1 需在运行手机工具时检查；0.3.2 有独立检查按钮。 |
| 配对/VPN 检查成功，但手机操作失败 | 检查 Automation 是否同版本且未过签名有效期，安装后的 Bundle ID 是否与设置一致，以及 XCTest 系统授权。 |

## 命令行方式（可选）

有现成 `idevice-tools` 时，也可以使用已包含 `remotepairing_lockdown` 的版本。
上游 [v0.1.68 发布页](https://github.com/jkcoxson/idevice/releases/tag/v0.1.68)
提供 Apple Silicon 和 Intel 的独立工具压缩包。先完成 USB 信任，再在终端运行：

```sh
umask 077
pairing_dir=$(mktemp -d "$HOME/Downloads/PocketAgent-Pairing.XXXXXX")
pairing_host="PocketAgent-$(uuidgen)"
RUST_LOG=warn idevice-tools --udid '<目标 iPhone 的 UDID>' remotepairing_lockdown pair "$pairing_host" "$pairing_dir/rp_pairing_file.plist"
```

把占位符替换为目标设备的 UDID，不要原样执行。GUI 不需要手工输入 UDID，
因此更适合第一次配置。独立输出目录避免覆盖旧文件；每次使用新的 host 名，
避免重新生成密钥时重用已配对的身份。CLI 的部分失败路径可能返回退出码 0，
必须确认实际生成了文件，导入后再验证连接。

## 依据与验证范围

本教程按实际 v1.1.0 发布包及其
[标签源码](https://github.com/jkcoxson/idevice_pair/tree/v1.1.0)编写。
[Remote 导出逻辑](https://github.com/jkcoxson/idevice_pair/blob/v1.1.0/src/backend/pairing.rs)
使用 RP plist，字段与 PocketAgent 原生导入匹配。
[设备准备逻辑](https://github.com/jkcoxson/idevice_pair/blob/v1.1.0/src/backend/worker.rs)
描述了开发者镜像和无线调试的准备步骤。本教程使用 USB 流程；Validate 检查
配对记录与选中手机的连接，不代表 Automation 或 XCTest 已获授权。将文件
导入 PocketAgent 后，仍需核对本机连接和 Automation 设置。
