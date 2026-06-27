import SwiftUI
import AppKit

// MARK: - 屏幕脚手架（顶留红绿灯 + 内容 + 底部 HelpRow）

let hPad: CGFloat = 22

struct ScreenFrame<Header: View, Body: View>: View {
    let t: Theme
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Body
    var body: some View {
        VStack(spacing: 0) {
            header()
                .padding(.horizontal, hPad).padding(.top, 40).padding(.bottom, 14)
            ScrollView {
                content().padding(.horizontal, hPad).padding(.bottom, 6)
                    .background(OverlayScrollers())
            }
            HelpRow(t: t).padding(.horizontal, hPad).padding(.vertical, 12)
        }
    }
}

// 把 SwiftUI ScrollView 底层的 NSScrollView 强制为 overlay 滚动条样式。
// 鼠标用户在系统「始终显示滚动条」下，默认会拿到常驻、挤占右侧宽度的 legacy 滚动条
//（`.scrollIndicators(.hidden)` 也压不住它）；改 overlay 后与触控板一致——空闲隐藏、
// 滚动/悬停时才细细淡入，且不占布局宽度。挂在内容里靠 enclosingScrollView 反查容器。
// 关键：必须在首帧绘制前同步改样式。若拖到下一个 runloop（DispatchQueue.async）才改，
// 内容超出视口的页（如设置页）会先按 legacy 滚动条占走右侧 ~15px 布一次，下一拍切 overlay
// 再把这 15px 还回去——肉眼即「内容向右撑开」的闪动。故改用视图入树回调即时应用，不延后。
struct OverlayScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ScrollerStyler() }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ScrollerStyler)?.applyOverlay()
    }
}

// 入树即应用：viewDidMoveToSuperview / ToWindow 都在首帧绘制前同步触发，反查 enclosingScrollView
// 并切 overlay；任一时机还拿不到容器，后一个时机补上，全程无 async 延迟。
final class ScrollerStyler: NSView {
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); applyOverlay() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyOverlay() }
    func applyOverlay() {
        guard let scroll = enclosingScrollView else { return }
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
    }
}

// MARK: - 文本编辑弹层（空状态「分享文本」/ 分享屏「编辑文本」共用）

// 离散提交：点「分享 / 更新」才把当前编辑器内容作为新分享广播（state.setSharedText）。
// 初值来自 textDraft（重启可回填上次内容）；清空再提交即撤下文本。
struct TextEntrySheet: View {
    let t: Theme
    let isUpdate: Bool
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(t: Theme, initial: String, isUpdate: Bool) {
        self.t = t; self.isUpdate = isUpdate
        _text = State(initialValue: initial)
    }

    private var blank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        let lang = state.lang
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L.shareTextButton(lang)).font(.display(18, .semibold)).foregroundStyle(t.ink)
                Spacer()
                IconButton(t: t, systemImage: "xmark", help: L.back(lang)) { dismiss() }
            }
            // placeholder 由 NSTextView 自绘：能查 hasMarkedText() 在中文输入法拼音组合时即让位，
            // 且画在文本容器内、与正文同一坐标系，对齐天然成立（不再用 SwiftUI 叠加层）。
            PlainTextEditor(text: $text, placeholder: L.textEditorPlaceholder(lang),
                            placeholderColor: NSColor(t.inkFaint), textColor: NSColor(t.ink),
                            caret: NSColor(t.accent), inset: 8, autoFocus: true)
                .frame(minHeight: 210)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.field))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(t.line, lineWidth: 1))
            PrimaryButton(t: t, title: isUpdate ? L.textUpdateAction(lang) : L.textShareAction(lang),
                          systemImage: "paperplane.fill") {
                state.setSharedText(text)
                dismiss()
            }
            .disabled(blank)
            .opacity(blank ? 0.5 : 1)
        }
        .padding(20)
        .frame(width: 380, height: 380)
        .background(t.bg)
    }
}

// 自带 NSTextView 的纯文本编辑器。两个问题一并根治：
//  ① 对齐：SwiftUI 的 TextEditor 底层 NSTextView 有一层 .padding() 控不到的内部内边距
//    （textContainerInset + textContainer.lineFragmentPadding 默认 5）；这里把 lineFragmentPadding 归零、
//     textContainerInset 显式设成 (inset,inset)，文字起点完全由 inset 决定。
//  ② 中文输入法：placeholder 交给 NSTextView 自绘（PlaceholderTextView），它能查 hasMarkedText()——
//     拼音组合上屏的瞬间就让位，不与未确认的拼音串重叠。
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var placeholderColor: NSColor
    var textColor: NSColor
    var caret: NSColor
    var inset: CGFloat
    var autoFocus: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let tv = PlaceholderTextView()
        tv.delegate = context.coordinator
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textColor = textColor
        tv.insertionPointColor = caret
        tv.placeholder = placeholder
        tv.placeholderColor = placeholderColor
        tv.drawsBackground = false
        tv.isRichText = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: inset, height: inset)
        tv.textContainer?.lineFragmentPadding = 0
        // 在 NSScrollView 里随宽变行、随内容长高（标准配方）。
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.string = text

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        if autoFocus {
            DispatchQueue.main.async { [weak tv] in tv?.window?.makeFirstResponder(tv) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self   // 让回调里的 binding 始终指向最新的
        guard let tv = scroll.documentView as? PlaceholderTextView else { return }
        // 输入法组合态（中文拼音未上屏）期间一律不碰文本视图直接返回——SwiftUI 因别处 @Published 变更
        // （如服务运行时每 2s 的在线人数轮询）触发的周期性 updateNSView，若在此刻回写 string 或重设 typing
        // 属性，会打断 marked text 造成吞字。组合结束（unmarkText）后的下一拍再补同步颜色等即可。
        if tv.hasMarkedText() { return }
        if tv.string != text { tv.string = text }   // 仅在外部值变化时回写，避免打断输入光标
        tv.textColor = textColor
        tv.insertionPointColor = caret
        tv.placeholderColor = placeholderColor
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        init(_ parent: PlainTextEditor) { self.parent = parent }
        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            parent.text = tv.string   // 含组合中的 marked text；committed 后即为最终文本
        }
    }
}

// 自绘 placeholder 的 NSTextView：仅当无内容且不在输入法组合态时才画占位文字——
// 中文输入法拼音上屏（hasMarkedText() 为真）即让位，不与拼音串重叠；画在文本容器内，与正文同坐标系。
final class PlaceholderTextView: NSTextView {
    var placeholder = ""
    var placeholderColor: NSColor = .placeholderTextColor

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: placeholderColor,
            .font: font ?? .monospacedSystemFont(ofSize: 13, weight: .regular),
        ]
        // lineFragmentPadding 已归零，文字起点即 textContainerInset，占位文字画在同一处。
        placeholder.draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: attrs)
    }
    // 文本变化（含 marked text 的增删）后重绘，让占位文字及时显隐。
    override func didChangeText() { super.didChangeText(); needsDisplay = true }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        needsDisplay = true
    }
    override func unmarkText() { super.unmarkText(); needsDisplay = true }
}
// 缓慢呼吸（淡入淡出）的小圆点：表「实时进行中」的状态，用动效与静态未读角标区分，避免红点冒充未读。
struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 6
    @State private var lit = false
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .opacity(lit ? 1 : 0.25)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: lit)
            .onAppear { lit = true }
    }
}
// MARK: - 底部帮助行

struct HelpRow: View {
    let t: Theme
    @EnvironmentObject var state: AppState
    @State private var show = false
    var body: some View {
        let lang = state.lang
        return HStack {
            Button { show.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "questionmark.circle").font(.system(size: 12))
                    Text(L.cantConnect(lang)).font(.sans(12.5, .medium))
                }
                .foregroundStyle(t.inkMute)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $show, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 11) {
                    Text(L.cantConnectTitle(lang)).font(.sans(12, .semibold)).foregroundStyle(t.ink)
                    row("1", L.help1(lang))
                    row("2", L.help2(lang))
                    row("3", L.help3(lang))
                    Rectangle().fill(t.line).frame(height: 1).padding(.vertical, 1)
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "lock.open").font(.system(size: 11)).foregroundStyle(t.inkMute).frame(width: 16)
                        Text(L.helpPlaintext(lang))
                            .font(.sans(11.5)).foregroundStyle(t.inkMute).lineSpacing(2)
                        Spacer(minLength: 0)
                    }
                }
                .padding(16).frame(width: 312)
            }
            Spacer()
            Text(appVersion).font(.mono(10)).foregroundStyle(t.inkFaint).textSelection(.enabled)
        }
    }
    private func row(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(n).font(.mono(10, .semibold)).foregroundStyle(t.accent)
                .frame(width: 16, height: 16)
                .background(Circle().strokeBorder(t.accent.opacity(0.4), lineWidth: 1))
            Text(text).font(.sans(11.5)).foregroundStyle(t.inkMute).lineSpacing(2)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 工具

// 版本号取自 bundle；裸二进制无 bundle 回退 dev。
var appVersion: String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "v\($0)" } ?? "dev"
}
