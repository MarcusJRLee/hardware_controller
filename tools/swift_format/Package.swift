// swift-tools-version: 6.0

// Pins the formatter that every check runs, independent of the installed
// Xcode. `Package.resolved` fixes every transitive revision.
import PackageDescription

let package = Package(
  name: "swift_format_tool",
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-format.git", exact: "602.0.0")
  ]
)
