import SwiftUI
import UIKit

struct AboutView: View {
    private let appVersion: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }()

    @State private var replayingWelcome = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    OasesAppIconTile(size: 80)
                    Text(OasesBrand.appName)
                        .font(.title2.bold())
                    Text(SettingsCopy.t("版本 \(appVersion)", "Version \(appVersion)"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(OasesBrand.tagline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            Section {
                if let source = OasesBrand.sourceCodeURL {
                    linkRow(
                        url: source,
                        title: String(localized: "本 App 的源代码", comment: "About: link to this app's own open source code"),
                        detail: String(localized: "GPL-3.0 · 可以查看、修改和再分发", comment: "About: license of this app's source"),
                        systemImage: "chevron.left.forwardslash.chevron.right"
                    )
                }
                linkRow(
                    url: OasesBrand.iSHURL,
                    title: "iSH",
                    detail: String(localized: "GPL-3.0 · Ogent 的 Linux 运行环境基于它", comment: "About: credit for iSH"),
                    systemImage: "terminal"
                )
                linkRow(
                    url: OasesBrand.iSHForkURL,
                    title: "iSH ARM64",
                    detail: String(localized: "GPL-3.0 · 本 App 链接的 iSH 分支", comment: "About: credit for the iSH ARM64 fork the app links"),
                    systemImage: "cpu"
                )
                linkRow(
                    url: OasesBrand.openMinisURL,
                    title: "OpenMinis",
                    detail: String(localized: "GPL-3.0 · 部分代码移植自它", comment: "About: credit for OpenMinis, whose code parts of the app are ported from"),
                    systemImage: "arrow.triangle.branch"
                )
                NavigationLink {
                    OpenSourceLicensesView()
                } label: {
                    Label {
                        Text(SettingsCopy.t("开源许可", "Open Source Licenses"))
                            .foregroundStyle(OasesColor.foreground)
                    } icon: {
                        Image(systemName: "doc.text")
                    }
                }
            } header: {
                Text(SettingsCopy.t("开源致谢", "Open-source attribution"))
            } footer: {
                Text(String(localized: "Oases Chat 的客户端以 GNU 通用公共许可证第 3 版（GPL-3.0）发布。内置的 Linux 运行环境基于 iSH，部分代码移植自 OpenMinis，二者也都以 GPL-3.0 发布；点上面的条目可以查看它们的源代码。其他开源组件见「开源许可」。", comment: "About: footer explaining the app's GPL-3.0 license and the iSH / OpenMinis credits"))
            }

            Section {
                linkRow(
                    url: OasesBrand.issuesURL,
                    title: SettingsCopy.t("反馈与问题", "Report an issue"),
                    detail: "qingtengstudio.com",
                    systemImage: "exclamationmark.bubble"
                )
            }

            Section {
                Button {
                    replayingWelcome = true
                } label: {
                    Label {
                        Text(String(localized: "重播欢迎页", comment: "About: play the welcome page again"))
                            .foregroundStyle(Color(UIColor.label))
                    } icon: {
                        Image(systemName: "play.circle")
                    }
                }
            } footer: {
                Text(String(localized: "重新播放首次打开时的欢迎页。不会改变你的 AI 数据共享选择。", comment: "About: what replaying the welcome page does"))
            }
        }
        .navigationTitle(SettingsCopy.t("关于 Oases Chat", "About Oases Chat"))
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $replayingWelcome) {
            OnboardingFlowView(replay: true) { replayingWelcome = false }
        }
    }

    private func linkRow(url: URL, title: String, detail: String, systemImage: String) -> some View {
        Link(destination: url) {
            Label {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: title)
                            .foregroundStyle(OasesColor.foreground)
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(OasesColor.mutedForeground)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(OasesColor.mutedForeground)
                }
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(OasesColor.foreground.opacity(0.8))
            }
        }
    }
}
