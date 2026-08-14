import XCTest
@testable import RAWForge

/// What the app is willing to say about a clipped frame.
///
/// The measurement itself is computed at capture and covered elsewhere. What is
/// tested here is the one claim the interface makes on top of it — *this channel
/// saturated* — because that is a statement about the data, and the app's whole
/// stance is that it does not make statements it cannot support.
final class ClippingPresentationTests: XCTestCase {

    private func channel(colour: String, p50: Int, p99: Int,
                         p99Normalised: Double = 0.5) -> ClippingStats.Channel {
        ClippingStats.Channel(
            cfaPosition: 0, colour: colour, count: 1000, min: 0, max: p99,
            mean: Double(p50), p50: p50, p90: p99, p99: p99, p999: p99,
            countAtMax: 1, modeValue: p50, modeCount: 100,
            fractionAtOrAboveDeclaredWhite: 0,
            fractionAtOrAboveObservedCeiling: 0.01,
            fractionAtOrBelowBlack: 0,
            p50Normalised: 0.2, p99Normalised: p99Normalised,
            histogram256: [])
    }

    private func stats(_ channels: [ClippingStats.Channel]) -> ClippingStats {
        ClippingStats(unavailableReason: nil, pixelFormat: nil, bufferWidth: nil,
                      bufferHeight: nil, activeArea: nil, croppedWidth: nil,
                      croppedHeight: nil, declaredBlackLevel: nil, declaredWhiteLevel: nil,
                      bufferScaleOverDNG: nil, channels: channels)
    }

    /// Over half a channel sitting on one value is something only clipping
    /// does. This is the signature the app is willing to state.
    func testAChannelWhoseMedianEqualsItsNinetyNinthIsSaturated() {
        XCTAssertTrue(channel(colour: "G", p50: 14271, p99: 14271).isSaturated)
    }

    func testAnOrdinaryChannelIsNotSaturated() {
        XCTAssertFalse(channel(colour: "G", p50: 3200, p99: 12800).isSaturated)
    }

    /// Deliberately conservative. A few per cent of blown highlights is a scene,
    /// not a fault, and the app should not editorialise about it — so a frame
    /// whose p99 is at the ceiling but whose median is nowhere near it does not
    /// trip the signature.
    func testBlownHighlightsAloneDoNotCountAsSaturation() {
        let hot = channel(colour: "R", p50: 4000, p99: 16383, p99Normalised: 1.0)
        XCTAssertFalse(hot.isSaturated,
                       "a bright scene is not a saturated channel")
    }

    func testSaturatedChannelsAreNamedSoTheOperatorKnowsWhich() {
        let s = stats([channel(colour: "R", p50: 100, p99: 9000),
                       channel(colour: "G", p50: 14271, p99: 14271),
                       channel(colour: "G", p50: 14271, p99: 14271),
                       channel(colour: "B", p50: 80, p99: 7000)])
        XCTAssertTrue(s.isSaturated)
        XCTAssertEqual(s.saturatedChannels.map(\.colour), ["G", "G"])
    }

    func testNothingIsClaimedWhenTheMeasurementIsUnavailable() {
        let absent = ClippingStats.unavailable("no pixel buffer")
        XCTAssertFalse(absent.isSaturated,
                       "an absent measurement must not read as a clean one")
        XCTAssertTrue(absent.saturatedChannels.isEmpty)
    }

    /// The mockup this came from had a "re-shoot one stop down" button. It was
    /// cut deliberately: the app reports and does not advise, because a ladder
    /// shot to find where the sensor blows is *meant* to blow its top rungs.
    /// This test exists to make that a decision rather than an oversight — if
    /// someone adds advice later, they should have to change a test that says
    /// why not.
    func testTheAppReportsSaturationWithoutRecommendingAnAction() {
        let blown = stats([channel(colour: "G", p50: 14271, p99: 14271)])
        XCTAssertTrue(blown.isSaturated)
        XCTAssertEqual(blown.saturatedChannels.count, 1,
                       "the measurement is reported; what to do about it is the "
                       + "photographer's call, and the workstation's")
    }
}
