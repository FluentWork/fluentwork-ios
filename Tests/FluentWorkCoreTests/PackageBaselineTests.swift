import Testing
@testable import FluentWorkCore

@Test func greetingUsesProvidedName() {
    #expect(PackageBaseline.greeting(for: "FluentWork") == "Hello, FluentWork.")
}

@Test func repoNameMatchesRepository() {
    #expect(PackageBaseline.repoName == "fluentwork-ios")
}
