import Testing
@testable import DiskEngine

@Test func versionIsSet() {
    #expect(!DiskEngine.version.isEmpty)
}
