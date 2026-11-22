// swift-tools-version:5.9
import PackageDescription

// libchiaki is built separately with CMake into vendor/chiaki-ng/build (see README.md).
let root = Context.packageDirectory
let chiaki = "\(root)/vendor/chiaki-ng"
let brew = "/opt/homebrew"

let package = Package(
    name: "PS5Stream",
    platforms: [.macOS("15.0")],
    targets: [
        .target(
            name: "CPS5",
            path: "Sources/CPS5",
            cSettings: [
                .unsafeFlags([
                    "-I\(chiaki)/lib/include",
                    "-I\(chiaki)/build/lib/include",
                    "-I\(brew)/opt/opus/include/opus",
                    "-I\(brew)/opt/opus/include",
                ])
            ]
        ),
        .executableTarget(
            name: "PS5Stream",
            dependencies: ["CPS5"],
            path: "Sources/PS5Stream",
            linkerSettings: [
                .unsafeFlags([
                    "\(chiaki)/build/lib/libchiaki.a",
                    "\(chiaki)/build/third-party/libjerasure.a",
                    "\(chiaki)/build/third-party/libgf_complete.a",
                    "\(chiaki)/build/third-party/nanopb/libprotobuf-nanopb.a",
                    "\(chiaki)/build/third-party/curl/lib/libcurl.a",
                    "-L\(brew)/opt/openssl@3/lib", "-lssl", "-lcrypto",
                    "-L\(brew)/lib", "-lopus", "-ljson-c", "-lminiupnpc", "-levent", "-levent_pthreads",
                    "-lz", "-lnghttp2",
                ]),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
