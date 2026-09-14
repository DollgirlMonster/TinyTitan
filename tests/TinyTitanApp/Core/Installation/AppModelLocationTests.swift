import Foundation
import Testing
@testable import TinyTitanAppCore

@Suite struct AppModelLocationTests {
    @Test func explicitURLWins() {
        let result = AppModelLocation.resolve(
            explicitURL: URL(fileURLWithPath: "/models/explicit.gturbo"),
            executableURL: nil,
            currentDirectoryURL: URL(fileURLWithPath: "/repo"),
            applicationSupportURL: URL(fileURLWithPath: "/support"),
            fileExists: { _ in false })
        #expect(result.path == "/models/explicit.gturbo")
    }

    @Test func executableAncestorFindsPackageRootOutsideCWD() {
        let files: Set<String> = ["/repo/Package.swift", "/repo/Sources/TinyTitanApp/Mac"]
        let result = AppModelLocation.resolve(
            explicitURL: nil,
            executableURL: URL(fileURLWithPath: "/repo/.build/debug/TinyTitanMac"),
            currentDirectoryURL: URL(fileURLWithPath: "/elsewhere"),
            applicationSupportURL: URL(fileURLWithPath: "/support"),
            fileExists: files.contains)
        #expect(result.path == "/repo/models/ornith-1.5_35B_A3B_8Bit")
    }

    @Test func currentDirectoryCanBePackageRoot() {
        let files: Set<String> = ["/repo/Package.swift", "/repo/Sources/TinyTitanApp/Mac"]
        let result = AppModelLocation.resolve(
            explicitURL: nil,
            executableURL: nil,
            currentDirectoryURL: URL(fileURLWithPath: "/repo"),
            applicationSupportURL: URL(fileURLWithPath: "/support"),
            fileExists: files.contains)
        #expect(result.path == "/repo/models/ornith-1.5_35B_A3B_8Bit")
    }

    @Test func standaloneAppFallsBackToApplicationSupport() {
        let result = AppModelLocation.resolve(
            explicitURL: nil,
            executableURL: URL(fileURLWithPath: "/Applications/TinyTitanMac"),
            currentDirectoryURL: URL(fileURLWithPath: "/"),
            applicationSupportURL: URL(fileURLWithPath: "/support"),
            fileExists: { _ in false })
        #expect(result.path == "/support/TinyTitan/ornith-1.5_35B_A3B_8Bit")
    }
}
