import ProjectDescription

let project = Project(
    name: "Bookshelf",
    packages: [
        .package(path: ".")
    ],
    targets: [
        .target(
            name: "Bookshelf",
            destinations: .macOS,
            product: .app,
            bundleId: "com.kristofrevilak.Bookshelf",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "Bookshelf",
                "CFBundleIconName": "Bookshelf",
                "NSHighResolutionCapable": true,
                "NSPrincipalClass": "NSApplication",
            ]),
            sources: ["Sources/Bookshelf/**"],
            resources: ["Resources/Bookshelf.icon"],
            dependencies: [
                .package(product: "SyncEngine"),
                .package(product: "CalibreLibrary"),
                .package(product: "MetadataFetch"),
                .package(product: "KindleFormat"),
            ],
            settings: .settings(base: [
                "ASSETCATALOG_COMPILER_APPICON_NAME": "Bookshelf"
            ])
        ),
        .target(
            name: "BookshelfTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.kristofrevilak.BookshelfTests",
            deploymentTargets: .macOS("26.0"),
            sources: ["Tests/BookshelfTests/**"],
            dependencies: [.target(name: "Bookshelf")]
        ),
        .target(
            name: "MTPKitTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.kristofrevilak.bookshelf.MTPKitTests",
            deploymentTargets: .macOS("26.0"),
            sources: ["Tests/MTPKitTests/**"],
            dependencies: [.package(product: "MTPKit")]
        ),
        .target(
            name: "CalibreLibraryTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.kristofrevilak.bookshelf.CalibreLibraryTests",
            deploymentTargets: .macOS("26.0"),
            sources: ["Tests/CalibreLibraryTests/**"],
            dependencies: [.package(product: "CalibreLibrary")]
        ),
        .target(
            name: "SyncEngineTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.kristofrevilak.bookshelf.SyncEngineTests",
            deploymentTargets: .macOS("26.0"),
            sources: ["Tests/SyncEngineTests/**"],
            dependencies: [.package(product: "SyncEngine")]
        ),
        .target(
            name: "MetadataFetchTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.kristofrevilak.bookshelf.MetadataFetchTests",
            deploymentTargets: .macOS("26.0"),
            sources: ["Tests/MetadataFetchTests/**"],
            dependencies: [.package(product: "MetadataFetch")]
        ),
        .target(
            name: "KindleFormatTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.kristofrevilak.bookshelf.KindleFormatTests",
            deploymentTargets: .macOS("26.0"),
            sources: ["Tests/KindleFormatTests/**"],
            dependencies: [.package(product: "KindleFormat")]
        ),
    ]
)
