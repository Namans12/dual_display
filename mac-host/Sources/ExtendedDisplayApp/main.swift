import Foundation

// Same pattern as MacHost: `--selftest` runs the pure-logic checks and exits
// non-zero on failure (this Mac class has no XCTest, so no `swift test`).
if CommandLine.arguments.contains("--selftest") {
    exit(runSelfTests())
}
LauncherApp.main()
