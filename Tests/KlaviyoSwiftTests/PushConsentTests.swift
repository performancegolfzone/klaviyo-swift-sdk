@testable import KlaviyoCore
@testable import KlaviyoSwift
import Combine
import Foundation
import XCTest

@MainActor
final class PushConsentTests: XCTestCase {
    override func setUp() async throws {
        environment = KlaviyoEnvironment.test()
        environment.uuid = { UUID() }
        environment.timer = { _ in Empty<Date, Never>().eraseToAnyPublisher() }
        klaviyoSwiftEnvironment = KlaviyoSwiftEnvironment.test()
    }

    func testDisablingRemovesSavedAndQueuedTokensWithoutResettingIdentity() async {
        let initial = makeState()
        let store = TestStore(initialState: initial, reducer: KlaviyoReducer())
        store.exhaustivity = .off

        await store.send(.setPushToken("queued-token", .authorized))
        await store.send(.setPushNotificationsEnabled(false))

        XCTAssertFalse(store.state.pushNotificationsEnabled)
        XCTAssertNil(store.state.pushTokenData)
        XCTAssertEqual(store.state.email, initial.email)
        XCTAssertEqual(store.state.anonymousId, initial.anonymousId)
        XCTAssertFalse(store.state.queue.contains(where: isRegistration))
        XCTAssertEqual(revokedTokens(in: store.state.queue), ["cached-token", "queued-token"])
    }

    func testProfilesAndEventsStillWorkWithPushDisabled() async {
        let store = TestStore(initialState: makeState(), reducer: KlaviyoReducer())
        store.exhaustivity = .off

        await store.send(.setPushNotificationsEnabled(false))
        await store.send(.enqueueProfile(Profile(email: "account@example.com", firstName: "Updated")))
        await store.send(.enqueueEvent(Event(name: .customEvent("Consent regression test"))))

        XCTAssertTrue(store.state.queue.contains {
            if case .createProfile = $0.endpoint {
                return true
            }; return false
        })
        XCTAssertTrue(store.state.queue.contains {
            if case .createEvent = $0.endpoint {
                return true
            }; return false
        })
        XCTAssertFalse(store.state.queue.contains(where: isRegistration))
    }

    func testManualAndAutomaticTokensAreIgnoredWhileDisabled() async {
        let store = TestStore(initialState: makeState(), reducer: KlaviyoReducer())
        store.exhaustivity = .off

        await store.send(.setPushNotificationsEnabled(false))
        await store.send(.setPushToken("manual-token", .authorized))
        await store.send(.setAutomaticPushToken("automatic-token", .authorized))

        XCTAssertNil(store.state.pushTokenData)
        XCTAssertFalse(store.state.queue.contains(where: isRegistration))
        XCTAssertTrue(store.state.pendingRequests.isEmpty)
    }

    func testCurrentOptOutOverridesPreviouslyEnabledDiskStateBeforeStartupFlush() async {
        let initial = KlaviyoState(
            apiKey: "test-key", queue: [], initalizationState: .initializing
        )
        let store = TestStore(initialState: initial, reducer: KlaviyoReducer())
        store.exhaustivity = .off
        var loaded = makeState()
        loaded.queue = [loaded.buildTokenRequest(
            apiKey: "test-key", anonymousId: "anonymous", pushToken: "queued-token", enablement: .authorized
        )]

        await store.send(.setPushNotificationsEnabled(false))
        await store.send(.completeInitialization(loaded))

        XCTAssertFalse(store.state.pushNotificationsEnabled)
        XCTAssertNil(store.state.pushTokenData)
        XCTAssertFalse(store.state.queue.contains(where: isRegistration))
        XCTAssertFalse(store.state.requestsInFlight.contains(where: isRegistration))
        await store.send(.stop)
    }

    func testDisabledDecisionAndRevocationSurviveSerialization() async throws {
        let store = TestStore(initialState: makeState(), reducer: KlaviyoReducer())
        store.exhaustivity = .off
        await store.send(.setPushNotificationsEnabled(false))

        let restored = try JSONDecoder().decode(KlaviyoState.self, from: JSONEncoder().encode(store.state))

        XCTAssertFalse(restored.pushNotificationsEnabled)
        XCTAssertNil(restored.pushTokenData)
        XCTAssertEqual(revokedTokens(in: restored.queue), ["cached-token"])
    }

    func testLegacyStateRemainsPushEnabledUntilHostSuppliesConsent() throws {
        let encoded = try JSONEncoder().encode(makeState())
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "pushNotificationsEnabled")

        let restored = try JSONDecoder().decode(
            KlaviyoState.self, from: JSONSerialization.data(withJSONObject: legacy)
        )

        XCTAssertTrue(restored.pushNotificationsEnabled)
        XCTAssertNotNil(restored.pushTokenData)
    }

    func testLateRegistrationCompletionCannotRestoreTokenAfterOptOut() async {
        var initial = makeState()
        let sent = initial.buildTokenRequest(
            apiKey: "test-key", anonymousId: "anonymous", pushToken: "late-token", enablement: .authorized
        )
        initial.requestsInFlight = [sent]
        initial.flushing = true
        let store = TestStore(initialState: initial, reducer: KlaviyoReducer())
        store.exhaustivity = .off

        await store.send(.setPushNotificationsEnabled(false))
        await store.send(.deQueueCompletedResults(sent))

        XCTAssertNil(store.state.pushTokenData)
        XCTAssertFalse(store.state.pushNotificationsEnabled)
        XCTAssertEqual(revokedTokens(in: store.state.queue), ["cached-token", "late-token"])
        XCTAssertTrue(store.state.requestsInFlight.isEmpty)
    }

    func testRegistrationInAnUnsentBatchIsSkippedAfterOptOut() async {
        var initial = makeState()
        let pending = initial.buildTokenRequest(
            apiKey: "test-key", anonymousId: "anonymous", pushToken: "batch-token", enablement: .authorized
        )
        initial.requestsInFlight = [pending]
        initial.flushing = true
        let store = TestStore(initialState: initial, reducer: KlaviyoReducer())
        store.exhaustivity = .off

        await store.send(.setPushNotificationsEnabled(false))
        await store.send(.sendRequest)
        await store.receive(.deQueueCompletedResults(pending))

        XCTAssertNil(store.state.pushTokenData)
        XCTAssertTrue(store.state.requestsInFlight.isEmpty)
    }

    func testOptingBackInAllowsFreshRegistration() async {
        let store = TestStore(initialState: makeState(), reducer: KlaviyoReducer())
        store.exhaustivity = .off

        await store.send(.setPushNotificationsEnabled(false))
        await store.send(.setPushNotificationsEnabled(true))
        await store.send(.setPushToken("fresh-token", .authorized))

        XCTAssertTrue(store.state.pushNotificationsEnabled)
        XCTAssertTrue(store.state.queue.contains(where: isRegistration))
        XCTAssertEqual(revokedTokens(in: store.state.queue), ["cached-token"])
    }

    private func makeState() -> KlaviyoState {
        KlaviyoState(
            apiKey: "test-key", email: "account@example.com", anonymousId: "anonymous",
            pushTokenData: .init(
                pushToken: "cached-token", pushEnablement: .authorized,
                pushBackground: .available, deviceData: .init(context: environment.appContextInfo())
            ),
            queue: [], initalizationState: .initialized
        )
    }

    private func isRegistration(_ request: KlaviyoRequest) -> Bool {
        if case .registerPushToken = request.endpoint {
            return true
        }
        return false
    }

    private func revokedTokens(in requests: [KlaviyoRequest]) -> Set<String> {
        Set(requests.compactMap {
            if case let .unregisterPushToken(_, payload) = $0.endpoint {
                return payload.data.attributes.token
            }
            return nil
        })
    }
}
