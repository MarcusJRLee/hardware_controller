// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "HardwareController",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(
      name: "HardwareControllerCore",
      targets: ["HardwareControllerCore"]
    ),
    .library(
      name: "HardwareControllerMac",
      targets: ["HardwareControllerMac"]
    ),
    .executable(
      name: "HardwareController",
      targets: ["HardwareControllerApp"]
    ),
  ],
  targets: [
    .target(
      name: "HardwareControllerCore"
    ),
    .target(
      name: "HardwareControllerAudioBoundary",
      path: "Sources/HardwareControllerAudioBoundary",
      publicHeadersPath: "include",
      linkerSettings: [
        .linkedFramework("AVFAudio")
      ]
    ),
    .target(
      name: "HardwareControllerMac",
      dependencies: [
        "HardwareControllerAudioBoundary",
        "HardwareControllerCore",
      ],
      linkerSettings: [
        .linkedFramework("ApplicationServices"),
        .linkedFramework("AVFoundation"),
        .linkedFramework("Carbon"),
        .linkedFramework("CoreAudio"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("IOKit"),
        .linkedFramework("Speech"),
      ]
    ),
    .executableTarget(
      name: "HardwareControllerApp",
      dependencies: [
        "HardwareControllerCore",
        "HardwareControllerMac",
      ]
    ),
    .testTarget(
      name: "HardwareControllerAudioBoundaryTests",
      dependencies: [
        "HardwareControllerAudioBoundary"
      ]
    ),
    .testTarget(
      name: "HardwareControllerCoreTests",
      dependencies: ["HardwareControllerCore"]
    ),
    .testTarget(
      name: "HardwareControllerMacTests",
      dependencies: [
        "HardwareControllerCore",
        "HardwareControllerMac",
      ]
    ),
    .testTarget(
      name: "HardwareControllerAppTests",
      dependencies: [
        "HardwareControllerApp",
        "HardwareControllerCore",
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
