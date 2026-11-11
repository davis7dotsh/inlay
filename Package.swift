// swift-tools-version: 5.10
import PackageDescription

var products: [Product] = [
    .library(name: "InlayAPI", targets: ["InlayAPI"]),
]
var targets: [Target] = [
    .target(name: "InlayDomain"),
    .target(name: "InlayAPIWire", dependencies: [.product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"), .product(name: "HTTPTypes", package: "swift-http-types")]),
    .target(name: "InlayAPI", dependencies: ["InlayDomain", "InlayAPIWire"]),
]

#if os(macOS)
products += [
    .executable(name: "Inlay", targets: ["Inlay"]),
    .library(name: "InlayCore", targets: ["InlayCore"]),
]
targets += [
    .target(name: "InlayCore", dependencies: ["InlayDomain"]),
    .executableTarget(name: "Inlay", dependencies: ["InlayCore", "InlayAPI"]),
]
#endif

let package = Package(
    name: "Inlay",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", exact: "1.11.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
    ],
    targets: targets,
    swiftLanguageVersions: [.v5]
)
