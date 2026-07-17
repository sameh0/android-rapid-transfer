import Observation

@MainActor
@Observable
final class OnboardingCoordinator {
    var page = OnboardingPage.welcome
    var isPresented = false
    /// Which way the last page change went, so pages slide in from the
    /// matching side.
    private(set) var isMovingForward = true

    func show(page: OnboardingPage = .welcome) {
        isMovingForward = true
        self.page = page
        isPresented = true
    }

    /// The next page, or closes the sheet from the last one.
    func advance() {
        guard let nextPage = page.next else {
            dismiss()
            return
        }
        go(to: nextPage)
    }

    func goBack() {
        guard let previousPage = page.previous else { return }
        go(to: previousPage)
    }

    func go(to newPage: OnboardingPage) {
        guard newPage != page else { return }
        isMovingForward = newPage.rawValue > page.rawValue
        page = newPage
    }

    func dismiss() {
        isPresented = false
    }
}
