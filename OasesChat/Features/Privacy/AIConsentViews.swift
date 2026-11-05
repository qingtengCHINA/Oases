import SwiftUI

// The one-page consent (2026-10-30) and the onboarding page pieces it shares with the welcome page.
//   • `OnePageConsentView` — "开始使用前": the Oases mark (as on the welcome page), the AI
//     sentence, 《隐私政策》《用户协议》, then 同意并继续 / 不同意. Onboarding step ② and, as a sheet,
//     an AI action or QingTeng sign-in without the consent (`AIConsentSheet`).
//
// Visual rules shared with `OnboardingFlowView`: accent = `OasesColor.primary`
// only; buttons are capsules, cards `OasesRadius.lg`, icon tiles
// `OasesRadius.sm`, all continuous; one display size per screen.

enum OnboardingLayout {
    /// Content column on iPad and in landscape.
    static let maxContentWidth: CGFloat = 560
    /// Step transitions: strong ease-out, entrances 280 ms, exits faster.
    static let pushIn = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.28)
    static let pushOut = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.22)
}

// MARK: - The one page

struct OnePageConsentView: View {
    var showsBackButton = false
    var onBack: () -> Void = {}
    var onAgree: () -> Void
    var onDecline: () -> Void

    var body: some View {
        OnboardingPageLayout(
            showsBackButton: showsBackButton,
            reservesTopBar: showsBackButton,
            onBack: onBack
        ) {
            VStack(spacing: OasesSpacing.xl) {
                OnboardingHeader(
                    title: QT("consent.title"),
                    subtitle: QT("consent.aiSentence")
                ) {
                    OasesDropletsMark(isAnimating: false)
                        .frame(width: 88, height: 88)
                        .accessibilityHidden(true)
                }

                HStack(spacing: OasesSpacing.lg) {
                    Link(QT("consent.privacyLink"), destination: ConsentLinks.privacyPolicy)
                        .accessibilityIdentifier("oases.privacy-consent.privacy-policy")
                    Link(QT("consent.termsLink"), destination: ConsentLinks.terms)
                        .accessibilityIdentifier("oases.privacy-consent.terms")
                }
                .buttonStyle(OnboardingLinkButtonStyle())
            }
        } actions: {
            VStack(spacing: OasesSpacing.xxs) {
                Button(QT("consent.agree"), action: onAgree)
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                    .accessibilityIdentifier("oases.privacy-consent.accept")

                Button(QT("consent.disagree"), action: onDecline)
                    .buttonStyle(OnboardingSecondaryButtonStyle())
                    .accessibilityIdentifier("oases.privacy-consent.decline")
            }
        }
        .accessibilityIdentifier("oases.privacy-consent.summary")
    }
}

/// The page's two links (the same address in every language: the site switches language itself).
enum ConsentLinks {
    static let privacyPolicy = OasesBrand.privacyPolicyURL
    static let terms = OasesBrand.termsOfUseURL
}

// MARK: - Shared page pieces

/// Full-screen onboarding page: a scrolling content column (vertically
/// placed a little above center when there's room) and a bottom action tray
/// that clears the home indicator. The optional back button sits in a fixed
/// top bar; pages without one keep the same bar height so both steps line up.
struct OnboardingPageLayout<Content: View, Actions: View>: View {
    var showsBackButton = false
    var reservesTopBar = true
    /// The page, top bar and action tray colour. `.clear` lets a backdrop behind the page show
    /// (the welcome page's atmosphere); pages that scroll keep the opaque default.
    var pageColor: Color = OasesColor.background
    var onBack: () -> Void = {}
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: OasesSpacing.md)
                    content
                    Spacer(minLength: OasesSpacing.xl)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: OnboardingLayout.maxContentWidth)
                .padding(.horizontal, OasesSpacing.lg)
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                if showsBackButton {
                    OnboardingBackButton(action: onBack)
                }
                Spacer(minLength: 0)
            }
            .frame(height: reservesTopBar ? 44 : 0)
            .padding(.horizontal, OasesSpacing.md)
            .background(pageColor.ignoresSafeArea(edges: .top))
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actions
                .frame(maxWidth: OnboardingLayout.maxContentWidth)
                .padding(.horizontal, OasesSpacing.lg)
                .padding(.top, OasesSpacing.sm)
                .padding(.bottom, OasesSpacing.xs)
                .frame(maxWidth: .infinity)
                .background(pageColor.ignoresSafeArea(edges: .bottom))
        }
        .background(pageColor.ignoresSafeArea())
    }
}

/// Centered hero: mark, the screen's single display-size title, one lead line.
struct OnboardingHeader<Mark: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var mark: Mark

    var body: some View {
        VStack(spacing: OasesSpacing.md) {
            mark
                .padding(.bottom, OasesSpacing.xs)
            Text(title)
                .font(.oasesDisplay())
                .foregroundStyle(OasesColor.foreground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.oasesBody())
                .foregroundStyle(OasesColor.mutedForeground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

/// SF Symbol tinted with the accent, bold title, one-line description.
struct OnboardingFeatureRow: View {
    var symbol: String
    var title: String
    var detail: String

    @ScaledMetric(relativeTo: .title2) private var symbolColumn: CGFloat = 36

    var body: some View {
        HStack(alignment: .top, spacing: OasesSpacing.md) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(OasesColor.primary)
                .frame(width: symbolColumn, alignment: .center)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.oasesBodyBold())
                    .foregroundStyle(OasesColor.foreground)
                Text(detail)
                    .font(.oasesCallout())
                    .foregroundStyle(OasesColor.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

struct OnboardingBackButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.backward")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(OasesColor.foreground)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(OnboardingCircleBackground())
        .accessibilityLabel(SettingsCopy.t("返回", "Back"))
        .accessibilityIdentifier("oases.onboarding.back")
    }
}

private struct OnboardingCircleBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content.background(OasesColor.card, in: Circle())
        }
    }
}

/// Primary action: accent capsule, full column width. The label uses the
/// 18 pt semibold headline so white on the accent reads as large text.
/// Press-in scales to 0.97 within ~100 ms; release springs back.
struct OnboardingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.oasesHeadline())
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, OasesSpacing.md)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(OasesColor.primary, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(
                configuration.isPressed
                    ? .easeOut(duration: 0.1)
                    : .spring(duration: 0.3, bounce: 0),
                value: configuration.isPressed
            )
    }
}

/// Secondary action: plain text in a capsule hit area. Neutral rather than
/// accent: the accent is spent on the primary action, and accent-coloured
/// body text is too light on the light page.
struct OnboardingSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.oasesBodyBold())
            .foregroundStyle(OasesColor.foreground)
            .multilineTextAlignment(.center)
            .padding(.horizontal, OasesSpacing.md)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Capsule(style: .continuous))
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Inline text link (「了解详情」, 「隐私政策」).
struct OnboardingLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.oasesCalloutBold())
            .foregroundStyle(OasesColor.primary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

#Preview("One page") {
    OnePageConsentView(showsBackButton: true, onAgree: {}, onDecline: {})
        .preferredColorScheme(.dark)
}
