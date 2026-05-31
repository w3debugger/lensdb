# Contributing to LensDB

Thanks for your interest in improving LensDB, a native macOS (SwiftUI) app for browsing and
editing PostgreSQL and MySQL databases. Bug reports, feature ideas, docs, and code are all
welcome.

## Requirements

- macOS 14.4 or newer on Apple Silicon
- The `psql` and/or `mysql` client on disk (LensDB shells out to them)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) for the Xcode workflow

## Setup and build

The real `Signing.xcconfig` holds an Apple Team ID and is gitignored, so a fresh clone must
create it from the committed example first.

### Xcode (recommended)

```sh
cp Signing.xcconfig.example Signing.xcconfig   # then optionally set DEVELOPMENT_TEAM
brew install xcodegen
xcodegen generate
open LensDB.xcodeproj                           # build and run in Xcode
```

### Command line (no signing needed)

```sh
xcodebuild -project LensDB.xcodeproj -scheme LensDB -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

### Quick SwiftPM build

`./build.sh` compiles and ad-hoc signs `LensDB.app` via SwiftPM.

## Project layout

See the [Project layout](README.md#project-layout) section of the README for a map of the
source files and what each one does.

## Coding guidelines

- Match the surrounding SwiftUI style. Read the nearby code before adding new code.
- Keep engine-specific logic (psql, mysql) behind the `DatabaseService` protocol. Shared
  behavior belongs in `DatabaseService.swift`, not duplicated across the two implementations.
- Prefer the smallest correct change. Avoid unrelated refactors in the same PR.

## Reporting bugs and requesting features

Open an issue using one of the templates:

- [Bug report](.github/ISSUE_TEMPLATE/bug_report.yml)
- [Feature request](.github/ISSUE_TEMPLATE/feature_request.yml)

For bugs, include your macOS version, the database engine, and the steps to reproduce.

## Pull requests

1. Fork the repo and create a branch off the default branch.
2. Keep PRs focused on a single change.
3. Make sure it builds (Xcode, `xcodebuild`, or `./build.sh`).
4. Open a PR. The template will prompt you for a summary, the related issue, and how you
   tested. Do not commit a personal Team ID or any secrets (`Signing.xcconfig` stays
   gitignored).
