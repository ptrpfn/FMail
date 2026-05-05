// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MailScripterDebug",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MailScripterDebug")
    ]
)
