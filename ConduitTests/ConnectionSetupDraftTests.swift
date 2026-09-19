import XCTest
@testable import Conduit

final class ConnectionSetupDraftTests: XCTestCase {
    func testLANTrimsInputsAndRequiresAnExplicitValidPort() throws {
        var draft = ConnectionSetupDraft()
        draft.accessMethod = .lan
        draft.lan.host = " 192.168.1.28 \n"
        draft.lan.port = " 9119 "
        XCTAssertEqual(try ConnectionSetupAddressBuilder.build(draft), "http://192.168.1.28:9119")
        for port in ["1", "65535"] {
            draft.lan.port = port
            XCTAssertEqual(try ConnectionSetupAddressBuilder.build(draft), "http://192.168.1.28:\(port)")
        }
        for port in ["", "0", "65536", "abc", "91.19", "-1", "+80", "９１１９"] {
            draft.lan.port = port
            XCTAssertThrowsError(try ConnectionSetupAddressBuilder.build(draft)) {
                XCTAssertEqual($0 as? ConnectionSetupValidationError, .invalidPort)
            }
        }
    }

    func testMalformedHostsCannotInjectURLComponents() {
        var draft = ConnectionSetupDraft()
        draft.accessMethod = .lan
        draft.lan.port = "9119"
        for host in ["", "https://192.168.1.28", "192.168.1.28/path", "user@192.168.1.28",
                     "192.168.1.28:80", "192.168.1.28?x", "bad host", "bad%20host", "-bad.local", "999.1.1.1"] {
            draft.lan.host = host
            XCTAssertThrowsError(try ConnectionSetupAddressBuilder.build(draft)) {
                XCTAssertEqual($0 as? ConnectionSetupValidationError, .invalidHost)
            }
        }
    }

    func testLANHostnamesAndPublicIPsRemainSubjectToCanonicalPolicy() {
        var draft = ConnectionSetupDraft()
        draft.accessMethod = .lan
        draft.lan.port = "9119"
        for host in ["hermes.home.arpa", "hermes.local", "8.8.8.8"] {
            draft.lan.host = host
            XCTAssertThrowsError(try ConnectionSetupAddressBuilder.build(draft)) {
                XCTAssertEqual($0 as? ConnectionSetupValidationError, .policy(.insecureTransport))
            }
        }
    }

    func testTailscaleServeUsesHTTPSWithoutInsertingAPort() throws {
        var draft = ConnectionSetupDraft()
        draft.accessMethod = .tailscale
        draft.tailscale.host = " machine.tailnet.ts.net "
        XCTAssertEqual(try ConnectionSetupAddressBuilder.build(draft), "https://machine.tailnet.ts.net")
        draft.tailscale.port = "8443"
        XCTAssertEqual(try ConnectionSetupAddressBuilder.build(draft), "https://machine.tailnet.ts.net:8443")
        draft.tailscale.port = "65536"
        XCTAssertThrowsError(try ConnectionSetupAddressBuilder.build(draft))
    }

    func testRawTailscaleAddressRequiresExplicitScheme() throws {
        var draft = ConnectionSetupDraft()
        draft.accessMethod = .tailscale
        draft.tailscale.host = "100.88.10.20"
        draft.tailscale.port = "9119"
        XCTAssertThrowsError(try ConnectionSetupAddressBuilder.build(draft)) {
            XCTAssertEqual($0 as? ConnectionSetupValidationError, .schemeRequired)
        }
        draft.tailscaleScheme = .http
        XCTAssertEqual(try ConnectionSetupAddressBuilder.build(draft), "http://100.88.10.20:9119")
        draft.tailscaleScheme = .https
        XCTAssertEqual(try ConnectionSetupAddressBuilder.build(draft), "https://100.88.10.20:9119")
        draft.tailscale.host = "100.128.1.1"
        draft.tailscaleScheme = .http
        XCTAssertThrowsError(try ConnectionSetupAddressBuilder.build(draft)) {
            XCTAssertEqual($0 as? ConnectionSetupValidationError, .policy(.insecureTransport))
        }
    }

    func testReverseProxyRetainsCustomPortAndEncodedPath() throws {
        var draft = ConnectionSetupDraft()
        draft.accessMethod = .reverseProxy
        draft.reverseProxyURL = " https://example.com:9443/hermes%20dashboard/ "
        XCTAssertEqual(try ConnectionSetupAddressBuilder.build(draft), "https://example.com:9443/hermes%20dashboard")
        for url in ["http://192.168.1.28:9119", "example.com/hermes", "https://user:secret@example.com",
                    "https://example.com?token=secret", "https://example.com/#fragment", "https://example.com:65536"] {
            draft.reverseProxyURL = url
            XCTAssertThrowsError(try ConnectionSetupAddressBuilder.build(draft))
        }
    }

    func testExistingExpertAddressIsRetainedWithoutDecomposition() throws {
        let draft = ConnectionSetupDraft(existingServerURL: " http://100.88.10.20:9119/prefix/ ", username: "eric", password: " secret ")
        XCTAssertNil(draft.accessMethod)
        XCTAssertTrue(draft.usesExistingAddress)
        XCTAssertEqual(try draft.result().serverURL, "http://100.88.10.20:9119/prefix")
        XCTAssertEqual(try draft.result().username, "eric")
        XCTAssertTrue(try draft.result().password == " secret ")
        XCTAssertFalse(String(describing: draft).contains("secret"))
        XCTAssertFalse(String(reflecting: try draft.result()).contains("secret"))
    }

    func testEmptyCredentialsCannotProduceResult() {
        var draft = ConnectionSetupDraft(existingServerURL: "https://example.com")
        XCTAssertThrowsError(try draft.result())
        draft.username = "eric"
        draft.password = " \n"
        XCTAssertThrowsError(try draft.result())
    }

    func testSeededCredentialsMatchManualLoginWithoutTrimmingTheirContents() throws {
        let draft = ConnectionSetupDraft(existingServerURL: "https://example.com", username: " eric ", password: " fixture ")
        let result = try draft.result()
        XCTAssertEqual(result.username, " eric ")
        XCTAssertTrue(result.password == " fixture ")
    }
}
