import XCTest
@testable import Oases_Chat

/// What later turns send for an earlier turn, and what "Copy Markdown" puts on the pasteboard.
final class ChatHistoryFidelityTests: XCTestCase {
    private func text(_ message: ChatAPIMessage) -> String? {
        if case .text(let value) = message.content { return value }
        return nil
    }

    private let pdf = Attachment(name: "report.pdf", mimeType: "application/pdf", kind: .text, textContent: "Chapter 3 is about tides.")

    /// A live user turn shows only the prompt; its document text still goes out in the
    /// history of the next turns (it used to be dropped until the app was restarted).
    func testAnEarlierTurnsDocumentStaysInTheHistory() {
        let live = ChatUIMessage.user("Summarize this", attachments: [pdf])
        XCTAssertEqual(text(live.api), "Summarize this\n\n# report.pdf\n\nChapter 3 is about tides.")
    }

    /// After a reload the row holds prompt + document text: the bubble shows the prompt again,
    /// and the history carries the document once.
    func testAReloadedTurnShowsThePromptAndSendsTheDocumentOnce() {
        let persisted = "Summarize this\n\n# report.pdf\n\nChapter 3 is about tides."
        let shown = ChatUIMessage.displayText(persisted: persisted, attachments: [pdf])
        XCTAssertEqual(shown, "Summarize this")
        let reloaded = ChatUIMessage.user(shown, attachments: [pdf])
        XCTAssertEqual(text(reloaded.api), persisted)

        // A row from before this change keeps its inline text and is not doubled.
        let old = ChatUIMessage.user(persisted, attachments: [pdf])
        XCTAssertEqual(text(old.api), persisted)
    }

    func testMessagesWithoutDocumentsAreUnchanged() {
        let image = Attachment(name: "a.jpg", mimeType: "image/jpeg", kind: .image, dataUrl: "data:image/jpeg;base64,AA==")
        XCTAssertEqual(text(ChatUIMessage.user("hi", attachments: [image]).api), "hi")
        XCTAssertEqual(ChatUIMessage.displayText(persisted: "hi", attachments: nil), "hi")
    }

    // MARK: - Copy Markdown

    func testMathDelimitersBecomeDollars() {
        XCTAssertEqual(MarkdownCopyNormalizer.dollarMathDelimiters(#"Area \(\pi r^2\) and \[E=mc^2\]"#),
                       #"Area $\pi r^2$ and $$E=mc^2$$"#)
    }

    /// Code is copied byte for byte: Swift interpolation and regex classes survive.
    func testCodeBlocksAndInlineCodeAreLeftAlone() {
        let source = """
        Use `print("\\(name)")` here.
        ```swift
        print("\\(name)")
        let r = /\\[a-z\\]/
        ```
        Then \\(x\\).
        """
        let expected = """
        Use `print("\\(name)")` here.
        ```swift
        print("\\(name)")
        let r = /\\[a-z\\]/
        ```
        Then $x$.
        """
        XCTAssertEqual(MarkdownCopyNormalizer.dollarMathDelimiters(source), expected)
    }
}
