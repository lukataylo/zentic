import Testing

@testable import ZenticKit

/// Which model does which work.
///
/// These exist because the failure the rule prevents is silent in both
/// directions. A route that quietly sends a medical page to a third party looks
/// exactly like one that worked, and so does a route that quietly runs a
/// six-thousand-word feature through a 3B model until the voice comes apart three
/// sections in. Neither shows up as an error, so both have to show up here.
///
/// The old rule was a switch in the View menu that the user had to maintain, which
/// meant the everyday case — re-voicing one paragraph — paid for the rare heavy
/// one, and `generateDocument` told people to go and change a setting.
@Suite("Model routing")
struct ModelRoutingTests {

    // MARK: - Shape of the work

    @Test("Everyday prose runs on the device")
    func everydayRewriteIsOnDevice() {
        let route = ModelRouting.route(for: .rewrite(words: 700, isFidelitySensitive: false))
        #expect(route.tier == .onDevice)
        #expect(route.fallback == .byoKey)
        #expect(route.reason == ModelRouting.everydayOnDevice)
    }

    @Test("A long read earns the cloud model, and can still fall back to the device")
    func longRewriteEscalates() {
        let route = ModelRouting.route(
            for: .rewrite(words: Budget.cloudRewriteWords, isFidelitySensitive: false)
        )
        #expect(route.tier == .byoKey)
        // Honest rather than absolute: with no key, a long rewrite on the small
        // model is still better than no rewrite at all.
        #expect(route.fallback == .onDevice)
        #expect(route.reason == ModelRouting.longRewriteEarnsCloud)
    }

    @Test("The threshold is a boundary, not a vibe")
    func thresholdIsExact() {
        let below = ModelRouting.route(
            for: .rewrite(words: Budget.cloudRewriteWords - 1, isFidelitySensitive: false)
        )
        #expect(below.tier == .onDevice)
    }

    /// The decision this suite exists to hold still.
    ///
    /// Size escalates and sensitivity does not — sensitivity *vetoes*. Invariant 6's
    /// answer to high stakes is the confirm, the badge and ⌘\, not a more fluent
    /// model: a frontier model paraphrasing a dosage is not safer than a small one,
    /// only better at sounding right. Escalating here would send exactly the pages
    /// most worth keeping private off the device.
    @Test("A fidelity-sensitive page stays on the device at any length")
    func sensitiveNeverEscalates() {
        for words in [10, Budget.cloudRewriteWords, 50_000] {
            let route = ModelRouting.route(
                for: .rewrite(words: words, isFidelitySensitive: true)
            )
            #expect(route.tier == .onDevice)
            #expect(route.fallback == nil)
            #expect(route.reason == ModelRouting.sensitiveStaysOnDevice)
        }
    }

    @Test("Structured generation goes to the cloud with nowhere to fall back to")
    func structuredWorkIsCloudOnly() {
        for work in [ModelWork.document, .lens] {
            let route = ModelRouting.route(for: work)
            #expect(route.tier == .byoKey)
            // A fallback to a model that declines is a slower way to show an error.
            #expect(route.fallback == nil)
            #expect(route.reason == ModelRouting.structuredNeedsCloud)
        }
    }

    @Test("A theme is small, closed-schema work, so it stays on the device")
    func themeIsOnDevice() {
        let route = ModelRouting.route(for: .theme)
        #expect(route.tier == .onDevice)
        #expect(route.fallback == .byoKey)
    }

    // MARK: - The override

    @Test("Pinning on-device never routes anything off it")
    func onDevicePinIsAbsolute() {
        let everything: [ModelWork] = [
            .document, .lens, .theme, .rewrite(words: 9000, isFidelitySensitive: false),
        ]
        for work in everything {
            let route = ModelRouting.route(for: work, preference: .onDevice)
            #expect(route.tier == .onDevice)
            // Falling back to the cloud is the exact opposite of what this says.
            #expect(route.fallback == nil)
        }
    }

    @Test("Pinning the cloud sends even a short rewrite there")
    func cloudPinIsAbsolute() {
        let route = ModelRouting.route(
            for: .rewrite(words: 200, isFidelitySensitive: false),
            preference: .cloud
        )
        #expect(route.tier == .byoKey)
        #expect(route.reason == ModelRouting.pinnedCloud)
    }

    // MARK: - Meeting availability

    private let intelligenceOff = ProviderAvailability.unavailable(
        reason: "Apple Intelligence is off. Turn it on in System Settings."
    )
    private let noKey = ProviderAvailability.unavailable(
        reason: "Add an OpenAI API key first — Zentic ▸ OpenAI API Key… (⌘,)."
    )
    private let notEligible = ProviderAvailability.ineligible(
        reason: "This Mac does not support Apple Intelligence."
    )

    @Test("The preferred tier wins when it can serve the work")
    func preferredTierWins() {
        let route = ModelRouting.route(for: .rewrite(words: 400, isFidelitySensitive: false))
        #expect(
            ModelRouting.resolve(route, onDevice: .available, cloud: .available) == .use(.onDevice)
        )
    }

    @Test("An unavailable device model falls through to the key that is already there")
    func fallsBackToCloud() {
        let route = ModelRouting.route(for: .rewrite(words: 400, isFidelitySensitive: false))
        #expect(
            ModelRouting.resolve(route, onDevice: intelligenceOff, cloud: .available)
                == .use(.byoKey)
        )
    }

    /// What the user hears when nothing can run. The point of the assertion is that
    /// the sentence is the *device* model's own — "why not the model you would have
    /// used" — and that the cloud is offered as a route out rather than assumed.
    @Test("With no model and no key, the device model's reason is what is said")
    func namesTheBlockingTier() {
        let route = ModelRouting.route(for: .rewrite(words: 400, isFidelitySensitive: false))
        #expect(
            ModelRouting.resolve(route, onDevice: intelligenceOff, cloud: noKey)
                == .unavailable(reason: intelligenceOff.reason!, cloudRoute: true)
        )
    }

    @Test("A sensitive page is never offered the cloud, and is told why instead")
    func sensitiveFailureOffersNoCloud() {
        let route = ModelRouting.route(for: .rewrite(words: 400, isFidelitySensitive: true))
        let outcome = ModelRouting.resolve(route, onDevice: intelligenceOff, cloud: .available)
        // The cloud is available and is still not offered: the rule has no cloud in
        // it, so a button here would route around the rule from the UI.
        #expect(
            outcome
                == .unavailable(
                    reason: intelligenceOff.reason! + "\n\n" + ModelRouting.sensitiveStaysOnDevice,
                    cloudRoute: false
                )
        )
    }

    @Test("A Mac that cannot run the model is never offered a key it would not use")
    func ineligibleCloudIsNotOffered() {
        // Cloud pinned, device ineligible: the only tier on the route is the cloud,
        // and it has no key. That is still recoverable, so it is offered.
        let pinned = ModelRouting.route(for: .theme, preference: .cloud)
        #expect(
            ModelRouting.resolve(pinned, onDevice: notEligible, cloud: noKey)
                == .unavailable(reason: noKey.reason!, cloudRoute: true)
        )

        // But an ineligible *cloud* tier is never offered, since nothing the user
        // does today changes it.
        let route = ModelRouting.route(for: .theme)
        let outcome = ModelRouting.resolve(
            route,
            onDevice: intelligenceOff,
            cloud: .ineligible(reason: "unsupported")
        )
        guard case .unavailable(_, let cloudRoute) = outcome else {
            Issue.record("expected no model to be available")
            return
        }
        #expect(!cloudRoute)
    }

    @Test("A long rewrite with no key quietly does the honest thing")
    func longRewriteWithoutKeyRunsOnDevice() {
        let route = ModelRouting.route(for: .rewrite(words: 6000, isFidelitySensitive: false))
        #expect(ModelRouting.resolve(route, onDevice: .available, cloud: noKey) == .use(.onDevice))
    }
}
