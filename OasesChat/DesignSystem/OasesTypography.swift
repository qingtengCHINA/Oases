import SwiftUI

/// PingFang SC — Apple's system Han-sans face. Renders crisp at every size on
/// retina, with proper hinting and CJK metric balance the previous STSongti
/// serif couldn't deliver at body sizes. The `serif`/`serifBold` names are
/// kept for source compatibility; the underlying face is now sans.
enum OasesTypography {
    static let serif = "PingFangSC-Regular"
    static let serifBold = "PingFangSC-Semibold"
    static let medium = "PingFangSC-Medium"
    static let fallbackSerif = "HelveticaNeue"
}

extension Font {
    static func oasesDisplay() -> Font { .custom(OasesTypography.serifBold, size: 34, relativeTo: .largeTitle) }
    static func oasesTitle() -> Font { .custom(OasesTypography.serifBold, size: 24, relativeTo: .title) }
    static func oasesHeadline() -> Font { .custom(OasesTypography.serifBold, size: 18, relativeTo: .headline) }
    static func oasesBody() -> Font { .custom(OasesTypography.serif, size: 16, relativeTo: .body) }
    static func oasesBodyBold() -> Font { .custom(OasesTypography.medium, size: 16, relativeTo: .body) }
    static func oasesCallout() -> Font { .custom(OasesTypography.serif, size: 14, relativeTo: .callout) }
    static func oasesCalloutBold() -> Font { .custom(OasesTypography.medium, size: 14, relativeTo: .callout) }
    static func oasesCaption() -> Font { .custom(OasesTypography.serif, size: 12, relativeTo: .caption) }
    static func oasesCaptionBold() -> Font { .custom(OasesTypography.medium, size: 12, relativeTo: .caption) }
    static func oasesFootnote() -> Font { .custom(OasesTypography.serif, size: 11, relativeTo: .footnote) }
}
