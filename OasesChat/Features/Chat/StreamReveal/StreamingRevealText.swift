import SwiftUI
import UIKit

/// The assistant's reply while it streams in the regular chat: an append-only text view that
/// reveals new words with the colour trail (`TextFadeAnimator`). Each refresh only lays out the
/// new tail instead of re-typesetting the whole reply.
struct StreamingRevealText: UIViewRepresentable {
    let text: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: false)
        view.isEditable = false
        // The bubble's context menu (copy, retry…) owns long-press while streaming.
        view.isSelectable = false
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.isAccessibilityElement = true
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.update(text: text, in: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0, width.isFinite else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        coordinator.animator?.cancelAll()
    }

    @MainActor
    final class Coordinator {
        private weak var view: UITextView?
        private(set) var animator: TextFadeAnimator?
        private var shown = ""

        func attach(_ view: UITextView) {
            self.view = view
            animator = TextFadeAnimator(
                traits: { [weak view] in view?.traitCollection },
                requestRedraw: { [weak view] in view?.setNeedsDisplay() }
            )
        }

        func update(text: String, in view: UITextView) {
            guard text != shown else { return }
            let storage = view.textStorage
            if !shown.isEmpty, text.hasPrefix(shown), storage.length == (shown as NSString).length {
                let delta = String(text.dropFirst(shown.count))
                let start = storage.length
                storage.beginEditing()
                storage.append(NSAttributedString(string: delta, attributes: Self.attributes))
                storage.endEditing()
                animator?.scheduleAnimation(for: NSRange(location: start, length: storage.length - start), in: storage)
            } else {
                animator?.cancelAll()
                storage.setAttributedString(NSAttributedString(string: text, attributes: Self.attributes))
                if shown.isEmpty, !text.isEmpty {
                    animator?.scheduleAnimation(for: NSRange(location: 0, length: storage.length), in: storage)
                }
            }
            shown = text
            view.accessibilityValue = text
            view.invalidateIntrinsicContentSize()
        }

        /// Matches `Font.oasesBody()` with `.lineSpacing(4)` and the foreground colour, so the
        /// swap to the Markdown view at the end does not shift the text.
        static var attributes: [NSAttributedString.Key: Any] {
            let base = UIFont(name: OasesTypography.serif, size: 16) ?? .systemFont(ofSize: 16)
            let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            return [
                .font: font,
                .foregroundColor: UIColor(named: "Foreground") ?? .label,
                .paragraphStyle: paragraph,
            ]
        }
    }
}

/// The assistant's text: the streaming reveal while it arrives, then (once the trail has
/// settled) the full Markdown rendering, cross-faded.
struct AssistantStreamingBody<Menu: View>: View {
    let text: String
    let isStreaming: Bool
    @ViewBuilder var menu: () -> Menu

    /// Shows the Markdown view; flips a moment after streaming ends.
    @State private var settled: Bool
    @State private var settleTask: Task<Void, Never>?

    init(text: String, isStreaming: Bool, @ViewBuilder menu: @escaping () -> Menu) {
        self.text = text
        self.isStreaming = isStreaming
        self.menu = menu
        _settled = State(initialValue: !isStreaming)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if settled {
                MarkdownMessageView(text: text)
                    .transition(.opacity)
            } else {
                StreamingRevealText(text: text)
                    .transition(.opacity)
            }
        }
        .padding(.trailing, OasesSpacing.lg)
        .contextMenu { menu() }
        .onChange(of: isStreaming) { _, streaming in
            settleTask?.cancel()
            if streaming {
                settled = false
            } else {
                // Let the last words finish their trail before re-rendering as Markdown.
                settleTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.6))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { settled = true }
                }
            }
        }
        .onDisappear { settleTask?.cancel() }
    }
}
