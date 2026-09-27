# Contributing to SimplyBar

Thank you for helping. Bug reports, ideas, translations and pull requests are all welcome.

## Before you start

- **Bugs:** open an issue with the bug template. Say which macOS version and which Mac you use.
- **New features and bigger changes:** open an issue with the feature template first, so we can agree on the
  approach before you write the code.
- **Security problems:** do not open a public issue. Follow [SECURITY.md](SECURITY.md).

## Ground rules

These rules keep SimplyBar private, safe and ready for the Mac App Store. A pull request that breaks one of them
cannot be merged.

1. **The App Sandbox stays on.** The app and its widgets run in the App Sandbox. Do not remove it, and do not add
   an entitlement or a temporary exception that widens it. If a value can only be read outside the sandbox
   (temperatures and fan speeds are examples), SimplyBar does not show it.
2. **No network calls.** SimplyBar never connects to anything: no network entitlement, no `URLSession`, no
   sockets, no analytics, no crash reporting service, no update checker. Opening a web page in the user's browser
   from a button is fine.
3. **No third-party dependency without a discussion.** The project uses only the frameworks of the macOS SDK.
   Open an issue before adding a Swift package or any other external code, and explain why the SDK is not enough.
4. **Tests use Swift Testing.** New tests go in `SimplyBarTests/` and use `import Testing`, `@Test` and `#expect`,
   not XCTest. Cover the logic you add or change (math, formats, parsing).
5. **Every text goes through the String Catalog.** Anything the user reads is a localizable string
   (`Text("...")`, `LocalizedStringResource`, `String(localized:)`) listed in `Shared/Localizable.xcstrings`,
   with its translation for every language the catalog supports. No sentence built by joining pieces of text.
   Use `Text(verbatim:)` only for text that must never be translated.
6. **Swift 6 concurrency.** The project builds in the Swift 6 language mode. Views and state stay on the main
   actor, system readers are `nonisolated`. Do not silence a concurrency error with `@unchecked Sendable` or
   `nonisolated(unsafe)` without a comment that explains why it is safe.
7. **Keep the signing settings.** Do not commit changes to the team, the signing identity or the App Group
   identifier. Use your own team locally only (see the README).

## Build and test

Run the tests from the project folder before you open a pull request. Signing is turned off on the command line,
so you do not need an Apple developer account:

```sh
xcodebuild test \
  -project SimplyBar.xcodeproj \
  -scheme SimplyBar \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

CI runs the same command on every pull request, with Xcode 26.6 and Xcode 27. It must be green.

The project uses folders synchronized with Xcode: a new Swift file placed in an existing folder joins its target
without any change to `project.pbxproj`.

## Pull requests

- One topic per pull request, with a clear title and a short description of what changes for the user.
- Screenshots or a short video for any visible change, in light and dark mode.
- Commit messages in English, in the imperative mood ("Add disk picker to the Storage widget").
- Code, comments and identifiers in English.

## License

By contributing, you agree that your contribution is released under the [MIT License](LICENSE) of this project.

Please also follow the [Code of Conduct](CODE_OF_CONDUCT.md).
