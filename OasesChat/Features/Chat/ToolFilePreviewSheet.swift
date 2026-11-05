import SwiftUI
import QuickLook
import UIKit

/// Tap-to-preview sheet for files the agent wrote via `file_write`.
/// Backed by QuickLook's native `QLPreviewController` so HTML, code,
/// images, PDFs, and most text formats Just Work — including the
/// system "share / open in" toolbar. The user can immediately AirDrop
/// the HTML showoff page to a Mac, open it in Safari for in-app
/// rendering, etc.
struct ToolFilePreviewSheet: View {
    let filePath: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QuickLookView(filePath: filePath)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle((filePath as NSString).lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: URL(fileURLWithPath: filePath)) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
        }
    }
}

private struct QuickLookView: UIViewControllerRepresentable {
    let filePath: String

    func makeCoordinator() -> Coordinator { Coordinator(filePath: filePath) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let vc = QLPreviewController()
        vc.dataSource = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        context.coordinator.filePath = filePath
        uiViewController.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var filePath: String
        init(filePath: String) { self.filePath = filePath }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            URL(fileURLWithPath: filePath) as QLPreviewItem
        }
    }
}
