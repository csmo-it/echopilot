// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EchoPilot",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SystemAudioProbe", targets: ["SystemAudioProbe"]),
        .executable(name: "SystemAudioRecorder", targets: ["SystemAudioRecorder"]),
        .executable(name: "MeetingRecorder", targets: ["MeetingRecorder"]),
        .executable(name: "EchoPilotApp", targets: ["EchoPilotApp"])
    ],
    targets: [
        .executableTarget(name: "SystemAudioProbe"),
        .executableTarget(name: "SystemAudioRecorder"),
        .executableTarget(name: "MeetingRecorder"),
        .executableTarget(name: "EchoPilotApp")
    ]
)
