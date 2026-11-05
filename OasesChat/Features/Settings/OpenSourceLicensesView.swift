import SwiftUI

/// "开源许可 / Open Source Licenses": third-party components shipped in the
/// app and their full license texts, read from the bundled
/// `Resources/Licenses/` folder (`licenses.json` + one text file per license).
/// The GPL requires the license text to reach users; iSH's copies must stay in
/// sync with `vendor/iSH/` (see `vendor/iSH/SOURCE.md`).
struct OpenSourceLicensesView: View {
    struct Component: Decodable, Identifiable, Hashable {
        let name: String
        let license: String
        let url: String
        var upstream: String?
        let files: [String]
        var note: String?

        var id: String { name }
    }

    private let components = Self.loadManifest()

    var body: some View {
        List {
            Section {
                ForEach(components) { component in
                    NavigationLink {
                        OpenSourceLicenseDetailView(component: component)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(component.name)
                                .font(.oasesBody())
                                .foregroundStyle(OasesColor.foreground)
                            Text(component.license)
                                .font(.oasesCaption())
                                .foregroundStyle(OasesColor.mutedForeground)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } footer: {
                Text(SettingsCopy.t(
                    "Oases Chat 使用了以上开源软件。点开可查看完整的许可证文本与源码地址。",
                    "Oases Chat includes the open-source software above. Open an entry for its full license text and source location."
                ))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(SettingsCopy.t("开源许可", "Open Source Licenses"))
        .navigationBarTitleDisplayMode(.inline)
    }

    static func loadManifest() -> [Component] {
        guard let url = Bundle.main.url(forResource: "licenses", withExtension: "json", subdirectory: "Licenses"),
              let data = try? Data(contentsOf: url),
              let components = try? JSONDecoder().decode([Component].self, from: data) else {
            return []
        }
        return components
    }

    static func licenseText(_ file: String) -> String? {
        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Licenses") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

private struct OpenSourceLicenseDetailView: View {
    let component: OpenSourceLicensesView.Component

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OasesSpacing.md) {
                if let note = component.note {
                    Text(note)
                        .font(.oasesCaption())
                        .foregroundStyle(OasesColor.mutedForeground)
                }
                sourceLink(SettingsCopy.t("源码", "Source"), component.url)
                if let upstream = component.upstream {
                    sourceLink(SettingsCopy.t("上游", "Upstream"), upstream)
                }
                ForEach(component.files, id: \.self) { file in
                    Divider()
                    Text(OpenSourceLicensesView.licenseText(file) ?? file)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(OasesColor.foreground)
                        .textSelection(.enabled)
                }
            }
            .padding(OasesSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(component.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func sourceLink(_ title: String, _ urlString: String) -> some View {
        if let url = URL(string: urlString) {
            Link(destination: url) {
                Label("\(title): \(urlString)", systemImage: "arrow.up.right.square")
                    .font(.oasesCaption())
            }
        }
    }
}
