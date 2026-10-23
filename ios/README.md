# FlClash iOS development

This port uses a Flutter host and a native `NEPacketTunnelProvider` extension.
The host can import subscriptions and validate profiles while disconnected.
The extension owns the active mihomo instance and exchanges IP packets through
the public `NEPacketTunnelFlow` API. No private TUN file descriptor is used.

## Build on a Mac

Install Xcode and its iOS SDK, Flutter 3.47.1, Go 1.26.4, rustup, CocoaPods and
XcodeGen (`brew install xcodegen cocoapods`). Initialize the repository submodules.

```sh
git submodule update --init --recursive
bash tool/prepare_ios.sh
flutter build ios --release --no-codesign
open ios/Runner.xcworkspace
```

`project.yml` is the source of the generated Xcode project. Do not run
`flutter create .` over this port. Run `prepare_ios.sh` again after changing the
Go source or Xcode project specification. For an Apple Silicon simulator use
`bash tool/prepare_ios.sh iphonesimulator`; simulator UI testing does not validate
the real VPN. Intel simulator archives are not currently produced.

Set a unique `FLCLASH_BUNDLE_ID` in `project.yml` before generating the project.
The App Group defaults to `group.<bundle-id>`. In Xcode, select your development
team for **both** Runner and PacketTunnel, register the matching App Group, and
enable Network Extensions with Packet Tunnel for both targets. Install and run
on the iPhone, then accept the system VPN configuration prompt. Unsigned build
artifacts cannot be installed directly. Signing credentials stay outside Git.

The GitHub Actions workflow `iOS build validation` builds an unsigned device IPA
on macOS. It runs manually or on pushes to `codex/ios-*` branches. Download the
`FlClash-ios-unsigned` artifact after a successful run; signing is still required.

## Runtime boundaries

- Shared `home/` contains the app's configuration; `runtime/` holds the VPN's
  configuration and separate mihomo caches. Only profiles and geo resources are
  copied, never the application's SQLite database.
- Configuration is applied before requesting VPN startup. Active Core calls go
  through `sendProviderMessage`; local file parsing stays in the host process.
- The extension can run while the Flutter app is suspended. System VPN status
  updates runtime display without issuing a second start/stop command.
- Stop immediately invalidates packet callbacks and closes the stack. An in-flight
  configuration request drains before background Core cleanup; a later start waits
  for that cleanup. Device tests must include cancellation during provider downloads.
- IPv4 and IPv6 default routes are captured. DNS port 53 goes to mihomo's resolver.
  The stack is gVisor, MTU 1500. Android app exclusions and desktop TUN controls
  do not apply. Process-name/UID rules cannot identify other iOS applications.
- Per-application traffic history is disabled on iOS; live total traffic remains
  available. The extension does not accumulate history that no host consumes.
- The Go heap has a soft 32 MiB target; this does not cap total extension RSS.
  Large subscriptions/rule sets still require memory testing on the device.
- The build overlay disables macOS process enumeration and macOS process-memory
  queries in the iOS archive without modifying the mihomo submodule. The Core
  memory gauge therefore does not report extension RSS on iOS.

## Acceptance still required

The Windows checks cannot certify Swift/Xcode linking or iPhone VPN operation.
Before treating this as a usable release, run the unsigned macOS workflow, then
test a signed build for subscription import with VPN off, node selection, TCP,
UDP, DNS, IPv6, stop/start, system Settings disconnect, host termination, locked
screen operation, Wi-Fi/cellular transitions, and a large real subscription.
Use Xcode's PacketTunnel logs and memory graph to diagnose extension termination.
Do not distribute an untested build as a supported iOS release.
