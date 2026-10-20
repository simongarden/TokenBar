import Foundation
import Testing

@Suite struct ClaudeConnectionPresentationTests {
    @Test func initialConnectionRequiresAUserAction() {
        let state = ClaudeConnectionPresentation(enabled: false, status: nil)
        #expect(state.action == .connect)
        #expect(!state.connected)
    }

    @Test(arguments: [ClaudeUsageClient.Status.expired, .httpError(401)])
    func invalidLoginOffersRepair(_ status: ClaudeUsageClient.Status) {
        let state = ClaudeConnectionPresentation(enabled: true, status: status)
        #expect(state.action == .repair)
        #expect(!state.connected)
    }

    @Test func failedRepairOffersLoginInsteadOfAnotherRepairLoop() {
        let state = ClaudeConnectionPresentation(enabled: true, status: .expired, needsLogin: true)
        #expect(state.action == .login)
    }

    @Test func missingCredentialCanOfferLoginBeforeAccessWasGranted() {
        #expect(ClaudeConnectionPresentation(enabled: false, status: .noCredential).action == .login)
    }

    @Test func systemDenialOffersPermissionInsteadOfRepair() {
        #expect(ClaudeConnectionPresentation(enabled: false, status: .denied).action == .connect)
    }

    @Test(arguments: [ClaudeUsageClient.Status.failed, .httpError(500), .waiting(Date().addingTimeInterval(600))])
    func temporaryFailuresDoNotSuggestSigningInAgain(_ status: ClaudeUsageClient.Status) {
        #expect(ClaudeConnectionPresentation(enabled: true, status: status).action == .none)
    }

    @Test func onlySuccessfulUsageConfirmsConnection() {
        #expect(!ClaudeConnectionPresentation(enabled: true, status: nil).connected)
        #expect(ClaudeConnectionPresentation(enabled: true, status: .ok).connected)
        #expect(!ClaudeConnectionPresentation(enabled: false, status: .ok).connected)
    }
}
