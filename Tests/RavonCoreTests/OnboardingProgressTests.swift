import Testing
@testable import RavonCore

@Suite("OnboardingProgress")
struct OnboardingProgressTests {

    @Test("All false = 0.0 completion")
    func allFalse() {
        let progress = OnboardingProgress()
        #expect(progress.completionPercentage == 0.0)
        #expect(progress.isReadyToGoLive == false)
    }

    @Test("All true = 1.0 completion")
    func allTrue() {
        let progress = OnboardingProgress(
            hasRestaurant: true, hasName: true, hasAddress: true,
            hasAtLeastOneCategory: true, hasAtLeastOneMenuItem: true,
            hasHoursConfigured: true
        )
        #expect(progress.completionPercentage == 1.0)
        #expect(progress.isReadyToGoLive == true)
    }

    @Test("Partial completion = correct fraction")
    func partial() {
        let progress = OnboardingProgress(
            hasRestaurant: true, hasName: true, hasAddress: true
        )
        // 3 out of 6
        #expect(progress.completionPercentage == 0.5)
        #expect(progress.isReadyToGoLive == false)
    }

    @Test("isReadyToGoLive requires all true")
    func notReadyIfAnyFalse() {
        let progress = OnboardingProgress(
            hasRestaurant: true, hasName: true, hasAddress: true,
            hasAtLeastOneCategory: true, hasAtLeastOneMenuItem: true,
            hasHoursConfigured: false // missing hours
        )
        #expect(progress.isReadyToGoLive == false)
        // 5/6
        let expected = 5.0 / 6.0
        #expect(abs(progress.completionPercentage - expected) < 0.001)
    }
}
