# Contributing

Issues and pull requests are welcome. Keep discussion, code, UI strings, and documentation in English.

## Local checks

Use macOS with Swift 6 and Xcode. Run `swift test`, then compile the example:

```sh
xcodebuild -project Examples/ConnectTestApp/ConnectTestApp.xcodeproj \
  -scheme ConnectTestApp -configuration Debug -sdk iphoneos \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

To test on an iPhone, copy the example signing template to the ignored local configuration. Never commit that local file, account credentials, or personal device reports.

## Board drivers

Keep transport and manufacturer details inside the package. Add independent packet fixtures, normalize coordinates, and advertise only implemented capabilities. Distinguish queued writes, protocol acknowledgments, and physical actions. Do not infer sensor positions from commands or claim firmware support from compilation alone.

## Bug reports

Include board model and firmware, OS/device version, reproduction steps, expected versus actual behavior, and a minimal diagnostic log. Review logs before posting: peripheral identifiers, device names, positions, and test notes may be personal. Do not attach account credentials.

For UI hangs, include when the hang occurs (preparing the report, opening the sheet, or selecting a share destination). An Instruments trace is useful if available.
