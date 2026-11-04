import Foundation
import Testing
@testable import Vita

struct BuildEnvironmentTests {
    @Test func appBundleCarriesAPIBaseURL() throws {
        let environment = try BuildEnvironment.current(bundle: .main)
        #expect(environment.apiBaseURL.absoluteString == "https://vita-api.r4s.leonardo-zhu.me")
    }

    @Test func rejectsMissingInsecureAndUnexpandedValues() {
        #expect(throws: BuildEnvironmentError.missingAPIBaseURL) {
            try BuildEnvironment.load(from: [:])
        }
        #expect(throws: BuildEnvironmentError.invalidAPIBaseURL("http://example.com")) {
            try BuildEnvironment.load(from: [BuildEnvironment.apiBaseURLKey: "http://example.com"])
        }
        #expect(throws: BuildEnvironmentError.invalidAPIBaseURL("$(VITA_API_BASE_URL)")) {
            try BuildEnvironment.load(from: [BuildEnvironment.apiBaseURLKey: "$(VITA_API_BASE_URL)"])
        }
    }
}
