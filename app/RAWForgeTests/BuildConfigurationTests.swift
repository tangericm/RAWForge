import XCTest
@testable import RAWForge

/// That the build is configured the way the source assumes.
///
/// These are not tests of behaviour. They exist because this project has twice
/// shipped a build setting that silently changed what the code *meant*, and in
/// both cases the source read correctly while doing nothing.
final class BuildConfigurationTests: XCTestCase {

    /// `xcodegen` supplies no `SWIFT_ACTIVE_COMPILATION_CONDITIONS` where
    /// Xcode's own templates do, so `#if DEBUG` compiled to nothing in *every*
    /// configuration for most of this project's life. Every diagnostic written
    /// under it — the instrument checks, the demo seeds, the log console's
    /// debug affordances — was dead code that looked live in the diff.
    ///
    /// The fix is one line in `project.yml`. This is the test that notices if it
    /// ever goes away again, and it has to live in the test target because the
    /// setting is per-configuration and the test target is built Debug.
    func testDebugBuildsActuallyDefineDEBUG() {
        var debugIsDefined = false
        #if DEBUG
        debugIsDefined = true
        #endif
        XCTAssertTrue(debugIsDefined,
                      "SWIFT_ACTIVE_COMPILATION_CONDITIONS has lost DEBUG — every #if DEBUG "
                      + "block in the app is now compiling to nothing, silently")
    }

    /// `@testable import` resolves against the module name, which follows
    /// `PRODUCT_NAME` unless it is pinned. It was empty here once already, and
    /// the symptom was every test failing to compile rather than anything
    /// pointing at the setting.
    func testTheModuleIsNamedWhatTheTestsImport() {
        XCTAssertEqual(String(reflecting: CaptureSet.self).split(separator: ".").first,
                       "RAWForge",
                       "PRODUCT_MODULE_NAME has drifted from RAWForge")
    }
}
