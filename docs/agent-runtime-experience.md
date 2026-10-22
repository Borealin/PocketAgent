# Agent 运行与交互优化技术方案

> 状态：实现完成，验收与剩余边界见仓库外本地交付记录
> 最后核对：2026-10-22  
> 范围：保留 AgentKit，优化流式展示、提前摘要与持久化确认。

## 1. 需求与关联资料

用户在 PR #1、#2 合入后要求借鉴 PiDurable 改善现有 AgentKit 实现，并授权开始落地。目标是降低长历史流式展示的工作量、减少下一轮发送前的摘要等待，并明确 SDK 持久化失败和提交确认。现有主线、记忆/遗忘、配置冻结、单一历史 owner、串行手机动作和不重放语义继续作为约束。

| 类型 | 链接 | 说明 |
|---|---|---|
| 需求真源 | 用户于 2026-10-22 在本次会话中的授权 | 无另行飞书需求 |
| 前置 | https://github.com/Borealin/PocketAgent/pull/1 | DDI 默认、WDA 可选 |
| 前置 | https://github.com/Borealin/PocketAgent/pull/2 | assistant-v1、记忆与提交屏障 |
| 既有架构 | https://github.com/Borealin/PocketAgent/blob/2025fce2f42a8fbb28ae82addb073c36f9de2e62/docs/engineering.md | 合并基线 |
| 参考机制 | https://github.com/finnvoor/PiDurableKit/blob/7288c6928df2040492901f5043ec15f87e05fc1e/Sources/PiDurableKit/Resources/Documentation/pi-durable/README.md | 快照投影、并行摘要、提交后继续执行 |
| Figma | 不涉及 | 保持当前原生界面结构 |

本期不引入 PiDurable/JavaScriptCore、不更换历史格式、不自动恢复已执行手机动作。存储后端替换与通用跨进程任务检查点后置；仅在量测出现必要性时扩展存储优化。

## 2. 技术调研结论

当前 App 在文本 delta 上反复发布 live 状态，展示先准备完整历史再分页。SDK 已有 pacing，但展示节流应与执行/提交路径分离。摘要虽在预算 70% 触发，仍在新轮首个请求前等待；可提前处理已稳定的历史前缀。AgentKit 的事件/快照保存目前吞掉存储错误，App 另有真实落盘屏障；SDK 应提供明确的等待与失败传播，同时保留宿主的业务校验。

2026-10-22 再次核对上游 4.0.0（`3481866cd47e83f6bf56b80c432c7824f61130b9`），fork main 已按该提交快进同步；SDK PR #1 改为直接对 main 审阅，包含 App 原先依赖的有界消费 API。

| 能力 | 上游覆盖与本项目处理 |
|---|---|
| 裸 SSE 错误 | 上游已识别 root error；不叠加第二套识别，只细化 null/空 error 与正常数据共存，以及保留字符串错误原因 |
| 取消与终态结构 | 复用上游统一 finish、未开始调用收束和同批次授权证据；在统一结构内加入提交等待与未取消的终态保存 |
| 秘密与工具输出 | 沿用上游调用方拥有 secret storage、统一截断与共享捕获，不恢复旧的每轮清理，也不另建输出处理机制 |
| App 工具与结果边界 | 上游默认新增共享 scratch、统一截断；SDK 保留默认并提供显式 registry 选择，App 关闭自动加入并冻结原有已限长且脱敏的 modelContent，避免重截断丢失续读字段 |
| 有界消费与提交屏障 | 上游仍无带体积/行/事件上限的 callback consume，事件/快照写入仍吞错；保留这两项宿主必需增量 |

<details><summary>选型与拒绝方案</summary>

- 保留 AgentKit 与 HistoryOwner，分别改进展示投影、摘要时机与 SDK 的提交边界。
- 不整体迁移 PiDurable：现有记忆/遗忘和设备约束仍需适配，当前增益不要求替换运行时。
- 不限流或丢弃工具结果/终态：只合并可替换的 UI 临时快照。
- 不引入后台常驻与手机动作重放：提前摘要受当前轮次、冻结配置及现有期限约束。

</details>

## 3. 技术方案总括

HistoryOwner 继续是唯一权威历史 owner。流式原始事件完整消费，最终消息及工具结果保持原有顺序和 ACK；UI 单独发布最新临时快照并缓存可见历史窗口。提前摘要只读当前轮次之前的已结束历史，在当前轮次内最多启动一次，使用相同冻结 provider/model/凭证和预算；CAS 提交供下一轮使用，不替换当前运行时已装配的请求投影。达到阈值的工具轮次可能增加一次摘要请求；即使本轮结束取消整理，也可能已产生服务侧用量，换取下一轮较少的阻塞整理。SDK 关键边界等待已接受的持久化工作，保存失败明确停止后续模型/工具分派。

<details><summary>落点、约束与验收</summary>

| 模块 | 改造 |
|---|---|
| ChatSessions / ChatTranscriptView | 缓存按历史版本、会话、分页与 live 身份定位的可见窗口和已分组时间线，保留工具调用组和 steering 顺序 |
| ChatTurns | 原始 partial 立即累积；只合并展示发布；终态、重试和会话结束撤销待发布快照 |
| AssistantContext / AssistantTurnSupport | 较低水位计划一次可选的提前摘要；保留已有强制准备路径、来源登记、预算与 CAS |
| PhoneAgent | 首个工具开始后启动维护；可选维护限 30 秒、一次一折；轮次结束前收束维护，不延长系统后台任务生命周期 |
| AgentKit EventChannel / Runtime / ToolExecutor | 明确持久化等待与失败契约；保持非持久 delta 独立，拒绝保存失败之后的新分派 |

兼容性：assistant-v1 的字段、消息 ID、记忆与删除记录、provider 设置和 Keychain 不变。Android、蓝牙/ISP/Wi-Fi 固件、schema/rpc、lt-vad 不受影响：本期只修改 iOS 宿主和 Swift agent SDK，无 App↔设备协议或音频变化。

集成顺序：展示优化 → 提前摘要 → AgentKit 独立提交与发布固定 ref → App 依赖更新与集成回归。SDK 固定提交为 `e382e5e5c4412e997ba42daa1230930800f88c44`，审阅见 https://github.com/Borealin/AgentKit/pull/1 。SDK 的等待接口不替代遗忘撤销、来源/预算验证与现有手机动作授权。取消收束由独立的未取消任务保存终态，避免取消等待误报为存储失败。提前摘要保存/来源撤销等终止类错误停止轮次（存储错先关闭提交屏障）；自身可选时限或普通服务失败只留下未完成说明。

验收覆盖：可见窗口与原分页等价、连续 delta/终态/重试/切换会话、摘要 Stop/过期/遗忘/来源改写与链变化、持久化故障时零后续模型或工具分派，以及完整 Core、iOS archive、IPA 检查和选定设备的实际使用。性能结论需标明设备、规模与统计口径。成功日志和产物引用仅存仓库外。

</details>

## 4. 资源与交付计划

| 模块 | 仓库/端 | 负责人 | 人日 | 开发分支 | 跟车版本 | 提测时间 | 状态/核对 | 依赖 |
|---|---|---|---|---|---|---|---|---|
| 流式展示 | PocketAgent/iOS | 待确认 | 待确认 | codex/agent-runtime-experience | 待确认 | 待确认 | 实现完成；2026-10-22 | main@2025fce |
| 提前摘要 | PocketAgent/iOS | 待确认 | 待确认 | codex/agent-runtime-experience | 待确认 | 待确认 | 实现完成；2026-10-22 | 现有 CAS/forget/期限 |
| 提交确认 | AgentKit/Swift | 待确认 | 待确认 | codex/durable-event-commits | 待确认 | 待确认 | 已适配上游 4.0.0；2026-10-22 | upstream@3481866 |
| 集成与验收 | PocketAgent/iOS | 待确认 | 待确认 | codex/agent-runtime-experience | 待确认 | 待确认 | 固定 ref 集成；验收记录留本地 | SDK e382e5e、同签名更新、用户指定 iPhone 12 mini |
