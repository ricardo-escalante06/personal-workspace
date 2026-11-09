// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WorkspaceKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        // Models, local store, scope queries, sync engine. No UI, no network SDKs.
        // Shared by the Mac app, iPhone app and (later) widgets.
        .library(name: "WorkspaceKit", targets: ["WorkspaceKit"]),
        // Supabase auth + the SyncRemote implementation that talks to PostgREST.
        .library(name: "WorkspaceRemote", targets: ["WorkspaceRemote"]),
        // Design tokens and shared SwiftUI components.
        .library(name: "WorkspaceUI", targets: ["WorkspaceUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/supabase/supabase-swift", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "WorkspaceKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "WorkspaceRemote",
            dependencies: ["WorkspaceKit", .product(name: "Supabase", package: "supabase-swift")]
        ),
        .target(
            name: "WorkspaceUI",
            dependencies: ["WorkspaceKit"]
        ),
        .testTarget(
            name: "WorkspaceKitTests",
            dependencies: ["WorkspaceKit"]
        ),
    ]
)
