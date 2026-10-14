import AgentKit
import ImageIO
import SwiftUI
import UIKit

/// Conversation body. Follows streaming output only while the reader is near
/// the bottom; otherwise keeps the reading position and offers a jump button.
struct ChatTranscriptView: View {
    @ObservedObject var chat: ChatController
    let dismissKeyboard: () -> Void
    /// Opens the memory panel prefilled from a message (one explicit save).
    var saveAsMemory: (MemoryDraft) -> Void = { _ in }
    /// Messages rendered per page; long histories show the most recent page
    /// first and load earlier pages on request (no full-history rebuild).
    static let pageSize = 400
    @Environment(\.openURL) private var systemOpenURL
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var nearBottom = true
    @State private var unseen = false
    @State private var pendingLink: URL?

    var body: some View {
        let all = chat.displayedMessages
        let limit = chat.selectedID.flatMap { chat.visibleLimit[$0] } ?? Self.pageSize
        let messages = Self.page(all, limit: limit)
        let hidden = all.count - messages.count
        let items = TranscriptItem.build(messages)
        let running = chat.selectedID.map(chat.isRunning) ?? false
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if all.isEmpty {
                    Text(chat.isPrimary(chat.selectedID)
                         ? "这是你的助理。换话题、换模型或隔天回来都在这里继续；用“记住：…”保存你希望它记住的事。"
                         : "开始一个新话题，也可以让助手打开 App、查找内容或操作手机。")
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 24)
                }
                if hidden > 0, let id = chat.selectedID {
                    Button("显示更早的 \(min(hidden, Self.pageSize)) 条（共 \(all.count) 条）") {
                        chat.visibleLimit[id] = limit + Self.pageSize
                    }
                    .font(.footnote).frame(maxWidth: .infinity).accessibilityIdentifier("loadEarlier")
                }
                ForEach(items) { item in
                    TranscriptRow(chat: chat, item: item, running: running, saveAsMemory: saveAsMemory)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        // On the scroll view itself (a real accessibility container), before
        // the overlay, so the jump button keeps its own identifier.
        .accessibilityIdentifier("chatTranscript")
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollDismissesKeyboard(.interactively)
        .contentShape(Rectangle())
        // Observe taps alongside message controls: links, copy and disclosure
        // actions must still receive the same tap. Keep this on the transcript,
        // rather than the chat root, so the composer retains its focus.
        .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - 72
        } action: { _, near in
            nearBottom = near
            if near { unseen = false }
        }
        .onChange(of: TranscriptProgress(Array(messages.suffix(50)))) { _, _ in
            if nearBottom { position.scrollTo(edge: .bottom) } else { unseen = true }
        }
        .overlay(alignment: .bottomTrailing) {
            if !nearBottom {
                Button {
                    withAnimation { position.scrollTo(edge: .bottom) }
                    unseen = false
                } label: {
                    Label(unseen ? "新内容" : "到底部", systemImage: "arrow.down")
                        .labelStyle(unseen ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .buttonStyle(.plain).background(.regularMaterial, in: Capsule())
                .shadow(radius: 2).padding(12)
                .accessibilityIdentifier("jumpToBottom")
            }
        }
        // Links open only after confirmation and only for http(s)/mailto.
        .environment(\.openURL, OpenURLAction { url in
            if MarkdownInline.isAllowed(url) { pendingLink = url }
            return .handled
        })
        .confirmationDialog("打开链接？", isPresented: Binding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }),
                            titleVisibility: .visible, presenting: pendingLink) { url in
            Button("在浏览器中打开") { systemOpenURL(url) }
            Button("拷贝链接") { UIPasteboard.general.url = url }
        } message: { url in Text(url.absoluteString) }
    }


    /// The most recent `limit` messages, never starting inside a call group.
    static func page(_ messages: [AgentTranscriptMessage], limit: Int) -> [AgentTranscriptMessage] {
        guard messages.count > limit else { return messages }
        var start = messages.count - limit
        while start > 0, messages[start].role == .tool { start -= 1 }
        return Array(messages[start...])
    }
}

private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

private struct TranscriptRow: View {
    @ObservedObject var chat: ChatController
    let item: TranscriptItem
    let running: Bool
    let saveAsMemory: (MemoryDraft) -> Void

    var body: some View {
        switch item {
        case .message(let message):
            switch message.role {
            case .user:
                VStack(alignment: .trailing, spacing: 4) {
                    UserBubble(message: message, attachments: chat.selected?.attachments(of: message) ?? [])
                    if let note = contextNote(message) {
                        Text(note).font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("contextExclusion")
                    }
                    if chat.isPrimary(chat.selectedID), MemoryCommand.parse(message.text) == nil,
                       message.text.contains("记住") || message.text.lowercased().contains("remember") {
                        Button { saveAsMemory(draft(from: message)) } label: { Label("存为记忆", systemImage: "brain") }
                            .font(.caption).buttonStyle(.bordered).controlSize(.mini)
                            .accessibilityIdentifier("saveAsMemoryChip")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contextMenu { actions(message) }
            case .assistant:
                AssistantBody(message: message, author: chat.author(of: message), streaming: chat.isStreaming(message.id))
                    .contextMenu { actions(message) }
            case .tool: ToolResultRow(message: message)
            }
        case .tools(_, let steps): ToolTimeline(steps: steps, running: running)
        case .orphanResult(let message): ToolResultRow(message: message)
        }
    }

    @ViewBuilder private func actions(_ message: AgentTranscriptMessage) -> some View {
        if !message.text.isEmpty {
            Button("拷贝", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
        }
        if chat.isPrimary(chat.selectedID), !message.text.isEmpty {
            Button("存为记忆…", systemImage: "brain") { saveAsMemory(draft(from: message)) }
        }
        if let id = chat.selectedID, !chat.isPrimary(id) {
            Button("引用到你的助理", systemImage: "quote.opening") { chat.referenceForAssistant(sessionID: id, messageID: message.id) }
        }
    }

    /// The user's own text prefills the panel; saving is one explicit edit.
    private func draft(from message: AgentTranscriptMessage) -> MemoryDraft {
        let root = chat.file.assistant.scopeIndex.root(of: message.id)
        return MemoryDraft(scope: chat.defaultMemoryScope, content: message.text, origin: .chatChip,
                           roots: root.map { [$0] } ?? [], messages: [message.id])
    }

    /// Context status of a primary-line request; originals always stay visible.
    private func contextNote(_ message: AgentTranscriptMessage) -> String? {
        guard chat.isPrimary(chat.selectedID) else { return nil }
        let index = chat.file.assistant.scopeIndex
        guard let root = index.root(of: message.id), root == message.id, let scoped = index.scopedRoot(root) else { return nil }
        if index.isMasked(root: root) { return "已排除出助理上下文（遗忘）" }
        if scoped.abandonedUnstarted { return "未启动，已放弃" }
        if !scoped.dispatchAuthorized, !chat.isAwaitingStart(root) { return "未开始执行，不用作助理上下文" }
        if !scoped.verified { return "来源已变化，不再自动用作上下文" }
        return nil
    }
}

// MARK: Messages

private struct UserBubble: View {
    let message: AgentTranscriptMessage
    let attachments: [ChatAttachment]

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                if !attachments.isEmpty || !message.images.isEmpty {
                    AttachmentStrip(attachments: attachments, inline: message.images)
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
        // A container element: children keep their own content and identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("message-\(message.id.uuidString)")
    }
}

private struct AssistantBody: View {
    let message: AgentTranscriptMessage
    let author: String
    let streaming: Bool
    @State private var showReasoning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(author).font(.caption2).foregroundStyle(.tertiary)
            let reasoning = message.reasoning.map(\.text).joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !reasoning.isEmpty {
                // Shown only when the provider actually supplied reasoning text.
                DisclosureGroup(isExpanded: $showReasoning) {
                    Text(reasoning).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label(streaming && message.text.isEmpty ? "模型提供的思考摘要…" : "模型提供的思考摘要", systemImage: "text.bubble")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !message.text.isEmpty {
                MarkdownView(text: message.text)
            } else if streaming {
                ProgressView().controlSize(.small)
            } else if message.toolCalls.isEmpty && reasoning.isEmpty {
                Text("本轮没有文本回复。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A container element: copy/load buttons keep their own identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("message-\(message.id.uuidString)")
    }
}

// MARK: Tool timeline

private struct ToolTimeline: View {
    let steps: [ToolStep]
    let running: Bool
    @State private var expanded = false

    var body: some View {
        let statuses = steps.map { $0.status(running: running) }
        let failed = statuses.filter { $0 == .failed }.count
        let latest = steps.last
        // Phone actions (including those a script performed) are counted
        // separately from file, network and script steps.
        let phone = steps.filter { ExecutionStatus.phase(for: $0.call.name) == .phoneAction }.count
            + steps.reduce(0) { $0 + $1.children.count }
        let other = steps.filter { ExecutionStatus.phase(for: $0.call.name) != .phoneAction }.count
        let title = other == 0 ? "手机操作 · \(phone) 步" : (phone == 0 ? "工具 · \(other) 步" : "工具 · \(other) 步，手机操作 \(phone) 步")
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    StepIcon(status: statuses.last ?? .noResult)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title + (failed > 0 ? "，\(failed) 步失败" : ""))
                            .font(.footnote.weight(.medium)).foregroundStyle(.primary)
                        if !expanded, let latest {
                            Text(latest.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("toolTimeline")
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(zip(steps, statuses)), id: \.0.id) { step, status in
                        ToolStepRow(step: step, status: status)
                    }
                }.padding(.top, 8).padding(.leading, 4)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct StepIcon: View {
    let status: ToolStep.Status
    var body: some View {
        switch status {
        case .pending: ProgressView().controlSize(.mini).frame(width: 16)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 16)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).frame(width: 16)
        case .noResult: Image(systemName: "questionmark.circle").foregroundStyle(.secondary).frame(width: 16)
        }
    }
}

private struct ToolStepRow: View {
    let step: ToolStep
    let status: ToolStep.Status
    @State private var details = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { details.toggle() } label: {
                HStack(spacing: 8) {
                    StepIcon(status: status)
                    Text(step.label).font(.footnote).foregroundStyle(.primary).lineLimit(2)
                    Spacer(minLength: 0)
                    if status == .noResult { Text("未返回结果").font(.caption2).foregroundStyle(.secondary) }
                    Image(systemName: details ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if details {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(step.call.name) · \(step.call.id)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                    RawText(title: "参数", text: step.call.arguments.prettyJSON)
                    if let result = step.result { RawText(title: result.isError ? "错误" : "结果", text: result.text) }
                }.padding(.leading, 24)
            }
            // A script's phone actions stay nested under its run_script step.
            if !step.children.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(step.children.enumerated()), id: \.offset) { _, child in
                        HStack(spacing: 6) {
                            StepIcon(status: child.ok ? .succeeded : .failed).scaleEffect(0.8)
                            Text(child.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }.padding(.leading, 24).accessibilityIdentifier("scriptPhoneActions")
            }
        }
    }
}

private struct ToolResultRow: View {
    let message: AgentTranscriptMessage
    @State private var details = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { details.toggle() } label: {
                HStack(spacing: 8) {
                    StepIcon(status: message.isError ? .failed : .succeeded)
                    Text("工具结果 · \(ToolLabels.name(message.toolName ?? ""))").font(.footnote)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if details { RawText(title: message.isError ? "错误" : "结果", text: message.text) }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct RawText: View {
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                Text(text.count > 6000 ? String(text.prefix(6000)) + "\n…（已截断显示）" : text)
                    .font(.caption2.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 900, alignment: .leading)
            }
        }
    }
}

private extension AgentJSONValue {
    var prettyJSON: String {
        guard let data = try? JSONEncoder.pretty.encode(self) else { return String(describing: self) }
        return String(decoding: data, as: UTF8.self)
    }
}

private extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

// MARK: Markdown

/// Native block Markdown: headings, lists, quotes, code with copy, tables
/// that scroll horizontally, rules and tap-to-load images.
struct MarkdownView: View {
    let text: String
    var body: some View {
        MarkdownBlocks(blocks: MarkdownParser.parse(text))
    }
}

private struct MarkdownBlocks: View {
    let blocks: [MarkdownBlock]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownInline.attributed(text))
                .font(level == 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .textSelection(.enabled).padding(.top, 2)
        case .paragraph(let text):
            VStack(alignment: .leading, spacing: 8) {
                Text(MarkdownInline.attributed(text)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(MarkdownInline.images(in: text).enumerated()), id: \.offset) { _, image in
                    MarkdownImageView(reference: image)
                }
            }
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Group {
                            if let checked = item.checked {
                                Image(systemName: checked ? "checkmark.square" : "square")
                            } else {
                                Text(ordered ? "\(start + index)." : "•").monospacedDigit()
                            }
                        }.foregroundStyle(.secondary).frame(minWidth: 16, alignment: .trailing)
                        MarkdownBlocks(blocks: item.blocks)
                    }
                }
            }
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(.tertiary).frame(width: 3)
                MarkdownBlocks(blocks: blocks).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
        case .code(let language, let text, let closed):
            CodeBlockView(language: language, text: text, closed: closed)
        case .table(let table):
            TableView(table: table)
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }
}

private struct CodeBlockView: View {
    let language: String?
    let text: String
    let closed: Bool
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "代码").font(.caption2.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "已拷贝" : "拷贝", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption2)
                }
                .buttonStyle(.borderless).disabled(!closed && text.isEmpty)
                .accessibilityIdentifier("copyCode")
            }.padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            ScrollView(.horizontal) {
                Text(text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    .fixedSize().padding(10)
            }
        }
        .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct TableView: View {
    let table: MarkdownTable
    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { index, cell in
                        cellView(cell, index: index).font(.footnote.weight(.semibold))
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                            cellView(cell, index: index).font(.footnote)
                        }
                    }
                }
            }.padding(10)
        }
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func cellView(_ text: String, index: Int) -> some View {
        let alignment = index < table.alignments.count ? table.alignments[index] : .leading
        return Text(MarkdownInline.attributed(text)).textSelection(.enabled)
            .frame(maxWidth: 260, alignment: alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
            .gridColumnAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
    }
}

/// Remote Markdown images never load by themselves. Allowed images load after
/// an explicit tap through `RemoteImageLoader`; others are listed, not fetched.
private struct MarkdownImageView: View {
    let reference: MarkdownImageReference
    @State private var image: UIImage?
    @State private var loading = false
    @State private var failure: String?
    @State private var preview = false


    var body: some View {
        if let image {
            Button { preview = true } label: {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain).accessibilityLabel(reference.alt.isEmpty ? "图片" : reference.alt)
            .fullScreenCover(isPresented: $preview) { ImagePreview(image: image) }
        } else {
            HStack(spacing: 10) {
                Image(systemName: reference.isLoadable ? "photo" : "photo.badge.exclamationmark").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(reference.alt.isEmpty ? "图片" : reference.alt).font(.footnote).lineLimit(1)
                    Text(failure ?? (reference.isLoadable ? (reference.url?.host ?? "") : "仅支持 HTTPS 图片，未加载"))
                        .font(.caption2).foregroundStyle(failure == nil ? Color.secondary : Color.orange).lineLimit(2)
                }
                Spacer(minLength: 0)
                if reference.isLoadable {
                    if loading { ProgressView().controlSize(.small) }
                    else { Button("加载") { load() }.buttonStyle(.bordered).controlSize(.small) }
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func load() {
        guard let url = reference.url, reference.isLoadable else { return }
        loading = true; failure = nil
        Task {
            defer { loading = false }
            do {
                let data = try await RemoteImageLoader.load(url)
                guard let decoded = downsampled(data, maxPixel: 2048) else { failure = "图片无法解码"; return }
                image = decoded
            } catch { failure = "图片无法加载：\(error.localizedDescription)" }
        }
    }
}

// MARK: Attachments

/// Decodes a bounded-size bitmap from encoded image bytes.
func downsampled(_ data: Data, maxPixel: Int) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
          ] as CFDictionary) else { return nil }
    return UIImage(cgImage: image)
}

/// Thumbnails of a message's images: file-backed attachments (shown as
/// unavailable when this device has no file, e.g. synced from another
/// device) and images stored inline by earlier builds.
struct AttachmentStrip: View {
    let attachments: [ChatAttachment]
    var inline: [AgentImageAttachment] = []
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in AttachmentThumbnail(source: .file(attachment), size: 96) }
                ForEach(inline) { image in AttachmentThumbnail(source: .inline(image.data), size: 96) }
            }
        }
        .frame(maxWidth: 300).fixedSize(horizontal: false, vertical: true)
        .flipsForRightToLeftLayoutDirection(false)
    }
}

struct AttachmentThumbnail: View {
    enum Source: Equatable {
        case file(ChatAttachment)
        case inline(Data)
    }
    let source: Source
    let size: CGFloat
    @State private var image: UIImage?
    @State private var missing = false
    @State private var preview: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if missing {
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.exclamationmark")
                    Text("图片不可用").font(.caption2)
                }.foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size, height: size)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if image != nil { preview = fullImage() } }
        .accessibilityLabel(missing ? "图片不可用" : "图片")
        .accessibilityAddTraits(.isImage)
        .task(id: sourceKey) { await load() }
        .fullScreenCover(item: Binding(get: { preview.map(PreviewImage.init) }, set: { if $0 == nil { preview = nil } })) {
            ImagePreview(image: $0.image)
        }
    }

    private var sourceKey: String {
        switch source {
        case .file(let attachment): attachment.id.uuidString
        case .inline(let data): "inline-\(data.count)-\(data.hashValue)"
        }
    }

    private func bytes() -> Data? {
        switch source {
        case .file(let attachment): attachmentFiles.data(for: attachment)
        case .inline(let data): data
        }
    }

    private func load() async {
        let source = source
        let thumbnail = await Task.detached(priority: .utility) { () -> UIImage? in
            let data: Data?
            switch source {
            case .file(let attachment): data = attachmentFiles.data(for: attachment)
            case .inline(let inline): data = inline
            }
            return data.flatMap { downsampled($0, maxPixel: 300) }
        }.value
        image = thumbnail
        missing = thumbnail == nil
    }

    private func fullImage() -> UIImage? { bytes().flatMap { downsampled($0, maxPixel: 3000) } }
}

private struct PreviewImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ImagePreview: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    var body: some View {
        NavigationStack {
            Image(uiImage: image).resizable().scaledToFit()
                .scaleEffect(scale)
                .gesture(MagnifyGesture().onChanged { scale = max(1, min(5, $0.magnification)) }
                    .onEnded { _ in withAnimation { if scale < 1.1 { scale = 1 } } })
                .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5 } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭") { dismiss() }.accessibilityIdentifier("closeImagePreview")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("图片", image: Image(uiImage: image)))
                    }
                }
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}
