import XCTest
@testable import UDIDRegisterKit

final class UserFacingMessageTests: XCTestCase {
    func testAuth401() {
        XCTAssertEqual(UserFacingMessage.from(ASCError.http(401, "x")),
                       "凭据无效或已过期，请检查 Key ID / Issuer ID / .p8 是否正确")
    }
    func testAuth403() {
        XCTAssertEqual(UserFacingMessage.from(ASCError.http(403, "")),
                       "凭据无效或已过期，请检查 Key ID / Issuer ID / .p8 是否正确")
    }
    func testOtherHTTPKeepsDetail() {
        XCTAssertEqual(UserFacingMessage.from(ASCError.http(500, "boom")), "请求失败：boom")
    }
    func testOtherHTTPNoDetail() {
        XCTAssertEqual(UserFacingMessage.from(ASCError.http(500, "")), "请求失败（ASC API 500）")
    }
    func testInvalidPrivateKey() {
        XCTAssertEqual(UserFacingMessage.from(ASCJWTError.invalidPrivateKey),
                       "这个 .p8 文件无法识别，请确认是从 App Store Connect 下载的原始 .p8 文件")
    }
    func testNetwork() {
        XCTAssertEqual(UserFacingMessage.from(URLError(.notConnectedToInternet)),
                       "网络连接失败，请检查网络后重试")
    }
    func testKeychain() {
        XCTAssertEqual(UserFacingMessage.from(KeychainError.os(-25300)),
                       "本机凭据存取失败（Keychain 错误码 -25300）")
    }
}
