import SwiftUI

struct LiveVoiceView: View {
    @ObservedObject var chat: ChatController
    @ObservedObject var providers: ProviderStore
    @ObservedObject var voice: LiveVoiceController
    let sessionID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var settings = LiveVoiceSettings()
    @State private var problem = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("GPT-Live · gpt-live-1") {
                    Picker("个人 Key 所属服务商", selection: $settings.providerID) {
                        Text("请选择").tag(Optional<UUID>.none)
                        ForEach(providers.providers) { provider in
                            Text(provider.name).tag(Optional(provider.id))
                        }
                    }
                    TextField("完整 HTTPS Live URL", text: $settings.endpoint)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL).accessibilityIdentifier("liveEndpoint")
                    Toggle("切换 App 后继续语音", isOn: $settings.continuesInBackground)
                    Text("使用此服务商本机 Key；兼容文字的服务不一定支持 GPT-Live。开始后配置冻结。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("开始后，音频、字幕及所选手机任务的结果会发送到你选定的 Live 服务，用于对话和播报；任务模型可能属于另一服务商。")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(voice.state.running)
                Section {
                    if voice.state.running {
                        Text(phaseLabel)
                        if voice.state.phase == .active {
                            Button(voice.state.muted ? "开启麦克风" : "静音麦克风") { voice.toggleMicrophone() }
                                .disabled(voice.state.muteCommand != nil).accessibilityIdentifier("liveMute")
                        }
                        Button("结束语音", role: .destructive) { voice.end() }
                            .disabled(voice.state.phase == .closing).accessibilityIdentifier("liveEnd")
                    } else {
                        Button("开始 Live 对话") { start() }
                            .disabled(!chat.storageReady || !chat.foreground || chat.dictation.input.busy)
                            .accessibilityIdentifier("liveStart")
                    }
                    Text("静音仅暂停麦克风上传，仍保留音频会话与计费；结束语音才释放音频并关闭会话。已交给网络的在途音频无法撤回。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("OpenAI 标准参考价 $0.05/分钟；网关以服务商实际计费为准。静音及等待任务也计费，任务模型另计。\(voice.state.finalUsage ? "最终" : "最近")用量：\(voice.state.seconds, specifier: "%.1f") 秒。")
                        .font(.caption).foregroundStyle(.secondary)
                    if chat.jobs[sessionID] != nil {
                        Button("停止手机执行", role: .destructive) { chat.cancel(sessionID) }
                            .accessibilityIdentifier("liveStopPhone")
                        Text("手机任务状态：\(chat.status(for: sessionID)?.phaseLabel ?? "请查看原聊天")")
                            .font(.caption)
                    }
                    if !problem.isEmpty { Text(problem).foregroundStyle(.orange) }
                    if !voice.notice.isEmpty { Text(voice.notice).foregroundStyle(.secondary) }
                }
                if let card = voice.state.card {
                    Section("检查后确认手机任务") {
                        TextEditor(text: Binding(get: { voice.state.card?.text ?? "" }, set: { voice.state.card?.text = String($0.prefix(8192)) }))
                            .frame(minHeight: 100).disabled(card.confirming)
                            .accessibilityIdentifier("liveTaskText")
                        Button("刷新为最近未确认语音") { voice.state.card?.text = String(voice.state.pendingText.prefix(8192)) }
                            .disabled(card.confirming)
                        Button(chat.isPrimary(sessionID) && chat.jobs[sessionID] != nil ? "确认排入下一件事" : "确认发送新任务") { confirm(card.id) }
                            .disabled(card.confirming || !chat.storageReady || voice.state.phase != .active)
                            .accessibilityIdentifier("liveConfirmTask")
                        if voice.state.phase != .active { Text("语音已结束，此卡仅供检查和复制；不会自动提交。请先复制需要保留的文字再开始新会话。") }
                        Text("不会自动追加或改动正在执行的任务。请补齐“它”“好的”等指代；字幕晚到不会改写卡上的文字。原草稿和照片保留。需要追加指令或记忆操作请回原聊天。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("本次临时字幕") {
                    if !voice.state.userCaption.isEmpty { Text("你：" + voice.state.userCaption).textSelection(.enabled) }
                    if !voice.state.assistantCaption.isEmpty { Text("助理：" + voice.state.assistantCaption).textSelection(.enabled) }
                    Text("音频与完整字幕不保存、不同步；结束后不保证恢复。只有你确认的任务、修正与任务结果进入原聊天历史。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Live 语音")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("收起") { dismiss() } } }
            .onAppear { settings = providers.liveVoice }
        }
    }

    private var phaseLabel: String {
        switch voice.state.phase {
        case .idle, .ended: "语音未运行"
        case .preparing: "正在准备麦克风…"
        case .connecting: "正在连接 GPT-Live…"
        case .active:
            if voice.state.muteCommand != nil { "麦克风上传已暂停，等待服务确认…" }
            else { voice.playing ? "正在播放 · 可继续说话" : "Live 已连接" }
        case .closing: "正在关闭语音，等待最终用量…"
        }
    }

    private func start() {
        guard chat.storageReady, chat.foreground else { return }
        problem = ""
        do {
            try providers.setLiveVoice(settings)
            let request = try providers.liveVoiceRequest() // Only a user Start reads Keychain.
            voice.start(in: sessionID, request: request, background: settings.continuesInBackground)
        } catch {
            problem = (error as? LiveVoiceFailure)?.localizedDescription ?? "Live 配置未通过检查，请核对服务商、已确认的主机和本机 Key。"
        }
    }

    private func confirm(_ id: UUID) {
        guard let text = voice.state.beginConfirmation(id), let delegation = voice.state.card?.delegation else { return }
        let accepted = chat.acceptLiveTask(text: text, sessionID: sessionID)
        voice.state.settleConfirmation(id, accepted: accepted != nil)
        if let prompt = accepted {
            problem = ""; voice.taskAccepted(prompt, delegation: delegation)
            // Submission can fail synchronously before the receipt returns.
            if chat.jobs[sessionID] == nil, chat.assistant.pendingNext == nil,
               let session = chat.sessions.first(where: { $0.id == sessionID }),
               session.state == .failed || session.state == .interrupted || session.state == .completed {
                voice.taskFinished(prompt, completed: session.state == .completed, cancelled: session.state == .interrupted,
                                   answer: chat.liveResult(for: prompt, in: sessionID))
            }
        } else { problem = chat.notice.isEmpty ? "任务未接受，文字已保留；请检查原聊天状态后再确认。" : chat.notice }
    }
}
