import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Oases_Chat

/// The QingTeng Studio ID card, ported from 词忆 through K线艺术家 (itself a
/// line-by-line port of the website's `id-card/palette.ts` and `engine.ts`).
/// The expected colours below were computed by running the website's own
/// `palette.ts` (my-app-showcase df34d25) for the same UIDs, so the same UID
/// draws the same card here, in 词忆 and on the web.
@MainActor
struct IdCardTests {
    private func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> IdCardRGBA {
        IdCardRGBA(r: r, g: g, b: b, a: a)
    }

    /// The owner's card, #000001, is bamboo green.
    @Test func theOwnersCardIsBamboo() {
        let palette = IdCardPalette.forUID(1)
        #expect(palette.name == "Bamboo")
        #expect(palette.ground == rgb(24, 51, 35))
        #expect(palette.groundHigh == rgb(36, 60, 41))
        #expect(palette.groundLow == rgb(7, 43, 29))
        #expect(palette.line == rgb(168, 226, 181))
        #expect(palette.detect == rgb(60, 173, 250))
        #expect(palette.detectInk == rgb(0, 24, 43))
        #expect(palette.edge == rgb(255, 255, 255, 0.14))
        #expect(!palette.light)
        #expect(IdCardPalette.seed(for: 1) == 1_364_076_727)
    }

    @Test func otherUIDsMatchTheWebsite() {
        let graphite = IdCardPalette.forUID(482913)
        #expect(graphite.name == "Graphite")
        #expect(graphite.ground == rgb(34, 37, 39))
        #expect(graphite.groundHigh == rgb(42, 45, 48))
        #expect(graphite.groundLow == rgb(26, 28, 31))
        #expect(graphite.line == rgb(213, 237, 77))
        #expect(graphite.detect == rgb(70, 153, 254))
        #expect(graphite.detectInk == rgb(255, 255, 255))
        #expect(IdCardPalette.seed(for: 482913) == 2_095_882_517)

        let midnight = IdCardPalette.forUID(999999)
        #expect(midnight.name == "Midnight")
        #expect(midnight.ground == rgb(17, 25, 55))
        #expect(midnight.line == rgb(236, 197, 110))
        #expect(IdCardPalette.seed(for: 999999) == 3_880_113_745)

        let lagoon = IdCardPalette.forUID(1234567)
        #expect(lagoon.name == "Lagoon")
        #expect(lagoon.ground == rgb(3, 96, 94))
        #expect(lagoon.line == rgb(165, 239, 226))
        #expect(IdCardPalette.seed(for: 1234567) == 2_885_493_108)

        let neighbour = IdCardPalette.forUID(100000)
        #expect(neighbour.name == "Bamboo")
        #expect(neighbour.ground == rgb(17, 50, 38), "same pair, turned by its own hash")
        #expect(neighbour.line == rgb(157, 227, 192))
    }

    /// Before the profile is read: plain Porcelain, a fixed seed, dashes for the UID.
    @Test func aCardWithoutAUIDIsPlainPorcelain() {
        let palette = IdCardPalette.forUID(nil)
        #expect(palette.name == "Porcelain")
        #expect(palette.ground == rgb(231, 230, 227))
        #expect(palette.line == rgb(19, 20, 23))
        #expect(palette.edge == rgb(10, 10, 20, 0.12))
        #expect(palette.light)
        #expect(IdCardPalette.seed(for: nil) == 0x5eed)
        #expect(IdCardEngine(uid: nil, still: true).uidText == nil, "no number is ever made up")
    }

    @Test func theSameUIDAlwaysGetsTheSameCard() {
        #expect(IdCardPalette.forUID(482913) == IdCardPalette.forUID(482913))
        #expect(IdCardPalette.forUID(482913) != IdCardPalette.forUID(482914), "neighbouring numbers land far apart")
        #expect(IdCardPalette.format(1) == "#000001")
        #expect(IdCardPalette.format(482913) == "#482913")
        #expect(IdCardPalette.format(1234567) == "#1234567")
        #expect(IdCardPalette.format(1) == QTCMe.formatUid(1), "the card and the API's formatUid agree")
        // JavaScript's Math.round, not Swift's: halves go up, negatives too.
        #expect(IdCardPalette.jsRound(2.5) == 3)
        #expect(IdCardPalette.jsRound(-2.5) == -2)
    }

    /// 保存图片: a still card at least three times the shown size, 2400…4096 pixels wide.
    @Test func theSavedImageIsALargeStillCard() throws {
        #expect(IdCardExport.fileName(uid: 1) == "QingTeng-ID-000001.png")
        #expect(IdCardExport.imageWidth(cardWidth: 343) == 2400)
        #expect(IdCardExport.imageWidth(cardWidth: 1000) == 3000)
        #expect(IdCardExport.imageWidth(cardWidth: 2000) == 4096)

        let image = try #require(IdCardExport.image(uid: 1, width: 240))
        #expect(image.width == 240)
        #expect(image.height == Int(IdCardPalette.jsRound(240 / IdCardEngine.aspect)))
        #expect(IdCardExport.png(image) != nil)
    }

    /// The card fades into the page from 83% of its height down, never a hard edge.
    @Test func theHeaderFadesOutAtTheBottom() {
        let stops = AccountCardHeader.fadeStops
        #expect(stops.first?.location == 0)
        #expect(stops.last?.location == 1)
        #expect(AccountCardHeader.fadeStart == 0.83)
    }

    /// The Invertocat fills its 24-point artboard.
    @Test func theGitHubMarkIsTheOfficialPath() {
        let box = GitHubMark.base.boundingBoxOfPath
        #expect(abs(box.minX) < 0.01 && abs(box.maxX - 24) < 0.01)
        #expect(box.height > 22 && box.height < 24)
    }
}
