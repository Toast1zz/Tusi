import XCTest
@testable import Tusi

final class LaunchAtLoginTests: XCTestCase {
    func testFailedRegisterDoesNotUnregister() {
        var registerCount = 0
        var unregisterCount = 0
        let result = SettingsStore.applyLaunchAtLogin(
            true,
            register: {
                registerCount += 1
                throw CocoaError(.fileWriteNoPermission)
            },
            unregister: { unregisterCount += 1 }
        )
        XCTAssertEqual(registerCount, 1)
        XCTAssertEqual(unregisterCount, 0)
        XCTAssertFalse(result.enabled)
        XCTAssertNotNil(result.error)
    }

    func testFailedUnregisterKeepsLoginItemOn() {
        var registerCount = 0
        var unregisterCount = 0
        let result = SettingsStore.applyLaunchAtLogin(
            false,
            register: { registerCount += 1 },
            unregister: {
                unregisterCount += 1
                throw CocoaError(.fileWriteNoPermission)
            }
        )
        XCTAssertEqual(registerCount, 0)
        XCTAssertEqual(unregisterCount, 1)
        XCTAssertTrue(result.enabled)
        XCTAssertNotNil(result.error)
    }

    func testSuccessfulToggleKeepsRequestedState() {
        let enabled = SettingsStore.applyLaunchAtLogin(true, register: {}, unregister: { XCTFail("unregister") })
        XCTAssertTrue(enabled.enabled)
        XCTAssertNil(enabled.error)
        let disabled = SettingsStore.applyLaunchAtLogin(false, register: { XCTFail("register") }, unregister: {})
        XCTAssertFalse(disabled.enabled)
        XCTAssertNil(disabled.error)
    }
}
