# AGENTS.md

## Project Structure & Module Organization

This repository contains the Objective-C `OTFCDTDatastore` framework, CocoaPods
packaging, tests, documentation, and sample applications.

- `OTFCDTDatastore.xcworkspace` and `OTFCDTDatastore.xcodeproj` are the current root
  Xcode entry points. Shared schemes live in
  `OTFCDTDatastore.xcodeproj/xcshareddata/xcschemes/`.
- `OTFCDTDatastore/` is the framework source. Major subsystems are grouped by
  directory: `Attachments/`, `CDTReplicator/`, `Encryption/`, `HTTP/`, `Utils/`,
  `query/`, `touchdb/`, `fmdb/`, `mrdatabasecontentchecker/`, and
  `vendor/MYUtilities/`.
- `OTFCDTDatastoreTests/` contains unit and integration tests, with helper areas
  such as `Assets/`, `Helpers/`, `Mocks/`, `Matchers/`, `Encryption/`, and
  `Keychain/`.
- `OTFCDTDatastoreReplicationAcceptanceTests/` contains longer-running replication
  acceptance tests and `ReplicationSettings.plist`.
- `OTFCDTDatastoreTestApp/`, `OTFCDTDatastoreTestAppTests/`, and
  `OTFCDTDatastoreTestAppUITests/` cover the root sample app target.
- `Project/` contains a separate CocoaPods sample app workspace and project.
- `doc/` holds feature documentation and `doc/style-guide.md`; `badges/coverage.svg`
  is the checked-in coverage badge; `Scripts/generate_coverage_badge.rb` regenerates it.

Place new framework code in the matching subsystem directory and keep the Xcode groups
aligned with filesystem locations. Add tests next to similar tests in
`OTFCDTDatastoreTests/` or the replication acceptance target.

## Build, Test, and Development Commands

```sh
pod install
```

Installs root workspace dependencies from `Podfile`. Use `encrypted=yes pod install`
when setting up SQLCipher-enabled dependencies.

```sh
open OTFCDTDatastore.xcworkspace
```

Opens the current root workspace. `CDTDatastore.xcworkspace` is referenced by older
docs and rake tasks, but `xcodebuild -list` currently reports no schemes for it.

```sh
xcodebuild -workspace OTFCDTDatastore.xcworkspace -scheme OTFCDTDatastore -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' build
xcodebuild -workspace OTFCDTDatastore.xcworkspace -scheme OTFCDTDatastoreOSX -destination 'platform=macOS' build
```

Builds the iOS and macOS framework schemes.

```sh
xcodebuild test -workspace OTFCDTDatastore.xcworkspace -scheme OTFCDTDatastoreTests -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'
xcodebuild test -workspace OTFCDTDatastore.xcworkspace -scheme OTFCDTDatastoreTestsOSX -destination 'platform=macOS'
```

Runs the primary iOS and macOS test targets. For a single XCTest method, append
`-only-testing:OTFCDTDatastoreTests/CDTReplay429InterceptorTests/testMethodName`.

```sh
xcodebuild test -workspace OTFCDTDatastore.xcworkspace -scheme OTFCDTDatastore -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -enableCodeCoverage YES -resultBundlePath /tmp/OTFCDTDatastore-coverage.xcresult
ruby Scripts/generate_coverage_badge.rb /tmp/OTFCDTDatastore-coverage.xcresult
```

Generates coverage and updates `badges/coverage.svg`. The badge script targets
`OTFCDTDatastore.framework` by default.

```sh
cd Project && pod install && open Project.xcworkspace
```

Sets up the separate sample app under `Project/`.

```sh
clang-format -i OTFCDTDatastore/path/to/File.m
pod lib lint --allow-warnings --use-libraries --verbose
```

Formats touched Objective-C files using `.clang-format` and validates the podspec.
`Jenkinsfile` also runs root/sample pod setup, iOS/macOS tests, encrypted variants,
replication acceptance tests, docs, and pod lint; `.travis.yml` is older and currently
only enables macOS rake jobs.

## Coding Style & Naming Conventions

Most code is Objective-C, with a small Swift test bridge. Follow `doc/style-guide.md`
and `.clang-format`: Google base style, 4 spaces, no tabs, 100-column limit, Linux
brace style, and Objective-C property spacing. Format only touched code in legacy
files, especially under `touchdb/`, to avoid noisy whitespace changes.

Public framework types use existing prefixes such as `CDT`, `CDTQ`, `TD`, and `OTF`.
Use paired `.h`/`.m` files for Objective-C types, category names like
`CDTDatastore+Query`, protocol names such as `CDTEncryptionKeyProvider`, and test
classes/files ending in `Tests`. Put mocks in `OTFCDTDatastoreTests/Mocks/`, helpers
in `Helpers/`, and static resources in `Assets/`.

## Testing Guidelines

Tests use XCTest, Specta/Expecta, OCMock, and OHHTTPStubs. Current project targets are
`OTFCDTDatastoreTests`, `OTFCDTDatastoreTestsOSX`,
`OTFCDTDatastoreReplicationAcceptanceTests`,
`OTFCDTDatastoreReplicationAcceptanceTestsOSX`, `OTFCDTDatastoreTestAppTests`, and
`OTFCDTDatastoreTestAppUITests`.

Use XCTest method names beginning with `test...` for XCTest cases and `SpecBegin`,
`describe`, and `it` blocks for Specta specs, matching nearby files. Keep fixtures in
`OTFCDTDatastoreTests/Assets/`; keep replication settings in
`OTFCDTDatastoreReplicationAcceptanceTests/ReplicationSettings.plist`.

Whenever test targets are added, removed, renamed, or significantly reorganized,
update the coverage badge and any related coverage documentation or scripts so they
continue to reflect the current test configuration.

## Commit & Pull Request Guidelines

Recent commits mostly use short, imperative summaries such as `Add manual test coverage
badge`, `Improve coverage for local docs and 429 retries`, and `Handle duplicate
tombstone insertions`, with occasional Conventional Commit prefixes like
`fix(podspec): ...` and `chore: ...`. Prefer concise imperative messages; use a scoped
prefix when it clarifies packaging, CI, or release-only changes.

PRs should complete `.github/PULL_REQUEST_TEMPLATE.md`: DCO checkbox, tests or build-only
justification, changelog decision, description, approach, schema/API changes, security
and privacy notes, testing evidence, and monitoring/logging notes. Run the relevant
build/test commands and update `CHANGELOG.md` when behavior or public API changes.

## Architecture Overview

The framework centers on `CDTDatastore` and `CDTDatastoreManager`, backed by TouchDB-style
storage classes in `touchdb/` and SQLite/FMDB integration. Capabilities are layered as
Objective-C categories and subsystem APIs: attachments, conflict resolution, query/index
management, encryption/keychain support, HTTP interceptors, and replication via
`CDTReplicator` and related replication classes. Extend behavior in the owning subsystem
instead of adding broad top-level helpers.

## Security & Configuration Tips

Configuration lives in `Podfile`, `OTFCDTDatastore.podspec`, plist files, Xcode build
settings, and replication test settings. Do not commit credentials for replication
acceptance tests; CI expects CouchDB/Cloudant values through environment variables such
as `TEST_COUCH_USERNAME`, `TEST_COUCH_PASSWORD`, and `TEST_COUCH_IAM_API_KEY`.

Avoid changing bundle identifiers, deployment targets, signing identities, entitlements,
podspec release metadata, or Jenkins publish settings unless explicitly requested.

## Agent-Specific Instructions

- Prefer minimal, targeted changes that follow the existing subsystem layout.
- Run the relevant build, test, coverage, and formatting commands before finishing.
- Update tests when behavior changes.
- Update snapshots, fixtures, generated files, coverage badges, and documentation when
  the related targets or resources change.
- Do not introduce new dependencies without clear justification.
- Do not modify signing, bundle identifiers, entitlements, or CI release settings unless
  explicitly requested.
