// swift-tools-version: 5.10
import PackageDescription

var products: [Product] = [
    .library(name: "V07API", targets: ["V07API"]),
    .executable(name: "v07-server", targets: ["V07Server"]),
]
var targets: [Target] = [
    .target(name: "V07Domain"),
    .target(name: "V07APIWire", dependencies: [.product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"), .product(name: "HTTPTypes", package: "swift-http-types")]),
    .target(name: "V07API", dependencies: ["V07Domain", "V07APIWire"]),
    .target(name: "V07ServerKit", dependencies: ["V07API", "V07Domain", .product(name: "Hummingbird", package: "hummingbird"), .product(name: "Crypto", package: "swift-crypto")]),
    .executableTarget(name: "V07Server", dependencies: ["V07ServerKit"]),
]

#if os(macOS)
products += [
    .executable(name: "V07", targets: ["V07"]),
    .library(name: "V07Core", targets: ["V07Core"]),
]
targets += [
    .target(name: "V07Core", dependencies: ["V07Domain"]),
    .executableTarget(name: "V07", dependencies: ["V07Core", "V07API"]),
]
#endif

let package = Package(
    name: "V07",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", exact: "1.11.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
    ],
    targets: targets,
    swiftLanguageVersions: [.v5]
)
