// swift-tools-version:5.9
import PackageDescription

// libchiaki is built separately with CMake into vendor/chiaki-ng/build (see README.md).
let root = Context.packageDirectory
let chiaki = "\(root)/vendor/chiaki-ng"
let brew = "/opt/homebrew"

let package = Package(
    name: "PS5Stream",
    platforms: [.macOS("26.0")],
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
                    // Homebrew libraries are linked statically, so the app runs on Macs without Homebrew.
                    "\(brew)/opt/openssl@3/lib/libssl.a", "\(brew)/opt/openssl@3/lib/libcrypto.a",
                    "\(brew)/opt/opus/lib/libopus.a", "\(brew)/opt/json-c/lib/libjson-c.a",
                    "\(brew)/opt/miniupnpc/lib/libminiupnpc.a", "\(brew)/opt/libevent/lib/libevent.a",
                    "\(brew)/opt/libevent/lib/libevent_pthreads.a", "\(brew)/opt/libnghttp2/lib/libnghttp2.a",
                    "-lz",
                ]),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
