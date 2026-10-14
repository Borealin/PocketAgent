import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Semantic status of the selected conversation's turn, with Stop kept apart
/// from the composer so a running turn can still receive steering.
struct ExecutionStrip: View {
    @ObservedObject var chat: ChatController
    let session: ChatSession

    var body: some View {
        let status = chat.status(for: session.id)
        let running = chat.isRunning(session.id)
        if status != nil || !session.detail.isEmpty || session.state != .idle {
            VStack(alignment: .leading, spacing: 4) {
                if status == nil, session.state != .idle {
                    // Earlier launch's outcome (completed, interrupted, failed).
                    Text(session.state.label).font(.footnote.weight(.semibold)).accessibilityIdentifier("chatStatus")
                }
                if let status {
                    HStack(spacing: 10) {
                        icon(status.phase)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(status.phaseLabel).font(.footnote.weight(.semibold)).lineLimit(1)
                                .accessibilityIdentifier("chatStatus")
                            facts(status)
                        }
                        Spacer(minLength: 4)
                        if running {
                            Button(role: .destructive) { chat.cancel(session.id) } label: {
                                Label("停止", systemImage: "stop.fill").font(.footnote.weight(.semibold))
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(session.state == .cancelling)
                            .accessibilityIdentifier("chatCancel")
                        }
                    }
                }
                if let context = status?.contextLabel {
                    Text(context).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("contextBudget")
                }
                if let note = status?.contextNote {
                    Text(note).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("contextNote")
                }
                if !session.detail.isEmpty {
                    Text(session.detail).font(.caption).foregroundStyle(session.state == .failed ? Color.red : Color.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(status == nil && session.state == .idle ? "chatStatus" : "chatDetail")
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func icon(_ phase: ExecutionPhase) -> some View {
        switch phase {
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
        case .needsUser: Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .retrying: Image(systemName: "arrow.clockwise").foregroundStyle(.orange)
        default: ProgressView().controlSize(.small)
        }
    }

    /// Current app/action, completed steps and elapsed time; no percentage.
    @ViewBuilder private func facts(_ status: ExecutionStatus) -> some View {
        let parts = [status.activity, status.stepsLabel].filter { !$0.isEmpty }
        if let started = status.startedAt {
            if status.phase.isTerminal {
                line(parts + [elapsed(from: started, to: status.finishedAt ?? Date())])
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    line(parts + [elapsed(from: started, to: context.date)])
                }
            }
        } else if !parts.isEmpty {
            line(parts)
        }
    }

    private func line(_ parts: [String]) -> some View {
        Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            .monospacedDigit()
    }

    private func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return seconds >= 60 ? "\(seconds / 60) 分 \(seconds % 60) 秒" : "\(seconds) 秒"
    }
}

/// Native adaptive composer: 1–6 lines, photo library, camera, system paste
/// button (no spontaneous clipboard reads), removable thumbnails and the
/// per-conversation model chip.
struct ChatComposer: View {
    @ObservedObject var chat: ChatController
    @ObservedObject var providers: ProviderStore
    @ObservedObject var workspaces: WorkspaceStore
    let session: ChatSession
    var inputFocused: FocusState<Bool>.Binding
    let chooseModel: () -> Void
    let chooseWorkspace: () -> Void
    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCamera = false

    private var running: Bool { chat.isRunning(session.id) }
    private var primary: Bool { chat.isPrimary(session.id) }
    private var target: InputTarget { chat.inputTarget(session.id) }
    private var remembering: Bool { primary && chat.rememberMode }
    private var placeholder: String {
        if remembering { return "输入要记住的内容，确认后才保存…" }
        return switch target {
        case .steer: "追加到本轮…"
        case .next: "下一件事（本轮结束后开始）…"
        case .send: primary ? "输入消息，或“记住：…”保存记忆" : "输入消息"
        }
    }
    /// Room left after committed images and imports still being prepared.
    private var remaining: Int { chat.importRoom(session.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PendingCard(chat: chat)
            if primary, running {
                Picker("输入目标", selection: $chat.steerPrimary) {
                    Text("下一件事").tag(false)
                    Text("追加到本轮").tag(true)
                }
                .pickerStyle(.segmented).controlSize(.small)
                .accessibilityIdentifier("inputTarget")
            }
            ReferenceChips(chat: chat)
            if primary, !chat.memoryNotice.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "brain").foregroundStyle(Color.accentColor)
                    Text(chat.memoryNotice).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { chat.memoryNotice = "" } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }.font(.caption).accessibilityIdentifier("memoryCommandReceipt")
            }
            if !chat.notice.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(chat.notice).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { chat.notice = "" } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }.font(.caption).accessibilityIdentifier("composerNotice")
            }
            if !session.draftAttachments.isEmpty, chat.acceptsImages(session.id) == false {
                Label(running ? "本轮模型不接收图片，图片不能追加到本轮。" : "当前模型不接收图片；发送前会提示你选择。",
                      systemImage: "photo.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
            }
            if remembering {
                Label("记住模式：发送会打开记忆编辑，确认后才保存；不会发给模型，也不会操作手机。", systemImage: "bookmark")
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("rememberModeHint")
            }
            if !session.draftAttachments.isEmpty || chat.isImporting(session.id) { draftImages }
            HStack(spacing: 8) {
                // Model first. On a narrow row the provider name goes, then the
                // project name becomes its icon; neither is clipped mid-word.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { modelChip(provider: true); workspaceChip(title: true) }
                    HStack(spacing: 8) { modelChip(provider: false); workspaceChip(title: true) }
                    HStack(spacing: 8) { modelChip(provider: false); workspaceChip(title: false) }
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                if primary {
                    Button { chat.rememberMode.toggle() } label: {
                        Image(systemName: chat.rememberMode ? "bookmark.fill" : "bookmark")
                    }
                    .accessibilityLabel(chat.rememberMode ? "记住模式：开" : "记住模式")
                    .accessibilityIdentifier("rememberMode")
                }
                Button { showPhotos = true } label: { Image(systemName: "photo.on.rectangle") }
                    .disabled(remaining == 0).accessibilityLabel("照片图库").accessibilityIdentifier("addPhoto")
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { showCamera = true } label: { Image(systemName: "camera") }
                        .disabled(remaining == 0).accessibilityLabel("拍照").accessibilityIdentifier("takePhoto")
                }
                PasteButton(supportedContentTypes: [.image]) { providers in paste(providers) }
                    .labelStyle(.iconOnly).buttonBorderShape(.circle).controlSize(.mini)
                    .disabled(remaining == 0).accessibilityIdentifier("pasteImage")
            }
            .font(.body).buttonStyle(.borderless)
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: Binding(get: { chat.selected?.draft ?? "" }, set: chat.setDraft),
                          axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .focused(inputFocused)
                    .accessibilityIdentifier("chatInput")
                if remembering {
                    Button { chat.beginRemember() } label: {
                        Image(systemName: "bookmark").font(.body.weight(.bold)).frame(width: 36, height: 36)
                            .background(chat.canRemember ? Color.accentColor : Color.secondary.opacity(0.3), in: Circle())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain).disabled(!chat.canRemember)
                    .accessibilityLabel("保存为记忆…").accessibilityIdentifier("rememberMessage")
                } else {
                    Button { chat.send() } label: {
                        Image(systemName: target == .steer ? "arrow.turn.down.right" : (target == .next ? "text.badge.plus" : "arrow.up"))
                            .font(.body.weight(.bold)).frame(width: 36, height: 36)
                            .background(chat.canSend ? Color.accentColor : Color.secondary.opacity(0.3), in: Circle())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain).disabled(!chat.canSend)
                    .accessibilityLabel(target == .steer ? "追加指令" : (target == .next ? "加入下一件事" : "发送")).accessibilityIdentifier("sendMessage")
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
        .sheet(item: $chat.memoryIntent) { request in
            // Dismissing the sheet sets the request to nil: 取消, the draft stays.
            MemoryIntentSheet(chat: chat, workspaces: workspaces, request: request)
        }
        .sheet(item: $chat.rememberRequest) { request in
            MemoryEditorView(chat: chat, workspaces: workspaces,
                             draft: MemoryDraft(scope: chat.defaultMemoryScope,
                                                content: request.text.trimmingCharacters(in: .whitespacesAndNewlines)),
                             commit: { chat.saveRemember($0, request: request) },
                             done: { chat.rememberRequest = nil })
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: max(1, remaining),
                      selectionBehavior: .ordered, matching: .images)
        .onChange(of: photoItems) { _, items in loadPhotos(items) }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                showCamera = false
                guard let image else { return }
                if let data = image.jpegData(compressionQuality: 0.92) { chat.importImages([data], into: session.id) }
                else { chat.reportImportFailure(AttachmentError.unreadableImage.localizedDescription) }
            }.ignoresSafeArea()
        }
    }

    private func modelChip(provider showProvider: Bool) -> some View {
        let state = providers.describe(session.selection)
        return Button(action: chooseModel) {
            HStack(spacing: 4) {
                Image(systemName: state.problem == nil ? "cpu" : "exclamationmark.triangle")
                if let selection = session.selection, let provider = providers.provider(selection.providerID) {
                    Text(selection.modelID).lineLimit(1).layoutPriority(1)
                    if showProvider { Text(provider.name).foregroundStyle(.tertiary).lineLimit(1).fixedSize() }
                } else {
                    Text(state.label).lineLimit(1)
                }
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.secondary.opacity(0.1), in: Capsule())
            .foregroundStyle(state.problem == nil ? Color.secondary : Color.orange)
        }
        .buttonStyle(.plain).layoutPriority(1).accessibilityIdentifier("modelSelection")
    }

    /// The conversation's project; a missing project is shown, never replaced.
    /// The name is shown whole or not at all (icon only, with the full name
    /// as its accessibility label); without a project the chip is an icon.
    private func workspaceChip(title showTitle: Bool) -> some View {
        let record = workspaces.record(session.workspaceID)
        let missing = session.workspaceID != nil && record == nil
        let title = missing ? "项目已删除" : record?.name
        return Button(action: chooseWorkspace) {
            HStack(spacing: 4) {
                Image(systemName: missing ? "exclamationmark.triangle" : record == nil ? "folder.badge.plus" : "folder")
                if let title, showTitle { Text(title).lineLimit(1).fixedSize() }
            }
            .font(.caption).padding(.horizontal, title == nil || !showTitle ? 8 : 10).padding(.vertical, 5)
            .fixedSize()
            .background(Color.secondary.opacity(0.1), in: Capsule())
            .foregroundStyle(missing ? Color.orange : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title.map { "项目：\($0)" } ?? "选择项目")
        .accessibilityIdentifier("workspaceSelection")
    }

    private var draftImages: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(session.draftAttachments) { attachment in
                    AttachmentThumbnail(source: .file(attachment), size: 64)
                        .overlay(alignment: .topTrailing) {
                            Button { chat.removeDraftAttachment(attachment.id) } label: {
                                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6)).font(.body)
                            }
                            .buttonStyle(.plain).padding(2)
                            .accessibilityLabel("移除图片").accessibilityIdentifier("removeAttachment")
                        }
                }
                if chat.isImporting(session.id) {
                    // Send waits for chosen images; cancelling keeps text and existing images.
                    Button { chat.cancelImports(for: session.id) } label: {
                        VStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("取消").font(.caption2)
                        }.frame(width: 64, height: 64)
                    }
                    .buttonStyle(.plain)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("取消添加图片").accessibilityIdentifier("cancelImageImport")
                }
            }.padding(.top, 2)
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoItems = []
        // Reserve before the first await: send is disabled while photos load.
        guard let ticket = chat.reserveImport(items.count, into: session.id) else { return }
        Task {
            var loaded: [Data] = []
            var failed = 0
            for item in items.prefix(ticket.slots) {
                if let data = try? await item.loadTransferable(type: Data.self) { loaded.append(data) } else { failed += 1 }
            }
            let failure = failed > 0 ? "\(failed) 张照片无法读取（可能尚未从 iCloud 下载），未添加。" : nil
            chat.completeImport(ticket, inputs: loaded, failures: failure.map { [$0] } ?? [])
        }
    }

    /// Runs only from the system paste button, which grants the read.
    private func paste(_ providers: [NSItemProvider]) {
        let images = providers.filter { $0.registeredContentTypes.contains { $0.conforms(to: .image) } }
        guard !images.isEmpty else { chat.reportImportFailure("剪贴板中没有可用的图片。"); return }
        guard let ticket = chat.reserveImport(images.count, into: session.id) else { return }
        Task {
            var loaded: [Data] = []
            for provider in images.prefix(ticket.slots) {
                guard let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .image) }) else { continue }
                if let data = await withCheckedContinuation({ (continuation: CheckedContinuation<Data?, Never>) in
                    _ = provider.loadDataRepresentation(for: type) { data, _ in continuation.resume(returning: data) }
                }) { loaded.append(data) }
            }
            chat.completeImport(ticket, inputs: loaded, failures: loaded.isEmpty ? ["剪贴板中的图片无法读取。"] : [])
        }
    }
}

/// System camera capture; returns nil when cancelled.
struct CameraPicker: UIViewControllerRepresentable {
    let onFinish: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void
        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }
    }
}
