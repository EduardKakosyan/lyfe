// swift-tools-version: 6.0
import PackageDescription

// Everything the iPhone and Mac apps share: the API client, local storage,
// the app model and the Poster screens. The app targets only launch it.
let package = Package(
    name: "LyfeKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "LyfeKit", targets: ["LyfeKit"])
    ],
    targets: [
        .target(name: "LyfeKit", resources: [.process("Food/Ingredients.json")]),
        // Lists the catalogue's foods, for the Spark to draw their icons
        // ahead of time. Run on the Mac; it is not part of the app.
        .executableTarget(name: "lyfe-icon-names", dependencies: ["LyfeKit"]),
        .testTarget(name: "LyfeKitTests", dependencies: ["LyfeKit"]),
    ]
)
