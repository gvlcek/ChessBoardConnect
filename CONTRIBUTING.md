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

## Changelog

Add a concise entry under **Unreleased** in [CHANGELOG.md](CHANGELOG.md) for notable changes. Describe the effect on library users or example app users, using the relevant `Added`, `Changed`, `Fixed`, or `Removed` section. Keep hardware support claims tied to actual validation.

When publishing a release, move the pending entries into a section with the version and release date, update the comparison links, and leave an empty **Unreleased** section for future work. Do not rewrite an existing release entry to include changes made after its tag.

## Board drivers

Keep transport and manufacturer details inside the package. Add independent packet fixtures, normalize coordinates, and advertise only implemented capabilities. Distinguish queued writes, protocol acknowledgments, and physical actions. Do not infer sensor positions from commands or claim firmware support from compilation alone.

## Bug reports

Include board model and firmware, OS/device version, reproduction steps, expected versus actual behavior, and a minimal diagnostic log. Review logs before posting: peripheral identifiers, device names, positions, and test notes may be personal. Do not attach account credentials.

For UI hangs, include when the hang occurs (preparing the report, opening the sheet, or selecting a share destination). An Instruments trace is useful if available.
