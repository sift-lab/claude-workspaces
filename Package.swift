// swift-tools-version: 6.0
import PackageDescription

// The app (AppKit, SwiftTerm) builds only on macOS; the server daemon (tmux) only on Linux.
// WorkspacesCore, the hook helper and the Core tests build on both.
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    .target(name: "WorkspacesCore"),
    .executableTarget(name: "workspaces-hook", dependencies: ["WorkspacesCore"], path: "Sources/WorkspacesHook"),
    .testTarget(name: "WorkspacesCoreTests", dependencies: ["WorkspacesCore"], exclude: ["Fixtures"]),
]
#if os(macOS)
dependencies.append(.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.20.0"))
targets.append(.executableTarget(
    name: "Workspaces",
    dependencies: ["WorkspacesCore", .product(name: "SwiftTerm", package: "SwiftTerm")]
))
#else
targets += [
    .target(name: "WorkspacesDaemon", dependencies: ["WorkspacesCore"]),
    .executableTarget(name: "workspacesd", dependencies: ["WorkspacesDaemon"], path: "Sources/WorkspacesDaemonMain"),
    .testTarget(name: "WorkspacesDaemonTests", dependencies: ["WorkspacesDaemon"]),
]
#endif

let package = Package(
    name: "Workspaces",
    platforms: [.macOS(.v14)],
    dependencies: dependencies,
    targets: targets,
    swiftLanguageModes: [.v5]
)
