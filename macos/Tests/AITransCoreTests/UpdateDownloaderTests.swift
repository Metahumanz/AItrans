// UpdateDownloaderTests.swift - 更新包安装提示

import XCTest
@testable import AITransCore

final class UpdateDownloaderTests: XCTestCase {
    func testInstallHintMatchesAssetTypeAndDirectory() {
        let dmg = URL(filePath: "/Users/me/Updates/AITrans-0.3.7-arm64.dmg")
        let dmgHint = UpdateDownloader.installHint(for: dmg)
        XCTAssertTrue(dmgHint.contains("/Users/me/Updates"))
        XCTAssertTrue(dmgHint.contains("打开 dmg"))
        XCTAssertFalse(dmgHint.contains("解压"))

        let zip = URL(filePath: "/Users/me/Updates/AITrans-0.3.7-arm64.zip")
        let zipHint = UpdateDownloader.installHint(for: zip)
        XCTAssertTrue(zipHint.contains("/Users/me/Updates"))
        XCTAssertTrue(zipHint.contains("解压"))
        XCTAssertFalse(zipHint.contains("打开 dmg"))
    }
}
