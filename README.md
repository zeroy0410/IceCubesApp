# Permission Boundary Lab

Permission Boundary Lab is a SwiftUI iOS research app for teaching and coursework. It uses an existing open-source client codebase as the host shell, but the primary product surface is now a foreground-only permission experiment platform.

The app is designed to answer four questions:

1. What data can an iOS app actually collect after a user explicitly grants a permission?
2. Which fields stay blocked by the system, even after authorization?
3. What privacy impact does that data have on its own?
4. What stronger inferences become possible when multiple permissions are combined?

## Project Purpose

This project is for permission-boundary experiments, privacy analysis, demos, and course reports.

Key design rules:

- All sensitive reads are triggered by explicit foreground user action.
- Experiment results are stored locally in the app sandbox as JSON.
- No Permission Lab result is uploaded by the experiment module.
- No background silent polling is used for the lab features.
- If iOS blocks a field, the UI reports a system boundary instead of trying to bypass it.

## Supported Permission Modules

Current modules exposed from the `Permission Lab` top-level tab:

- Photos
  - System picker minimal-access path
  - PhotoKit authorization path
- Camera
- Microphone
- Location
  - Single sample
  - Foreground continuous sample
  - Precise vs approximate state display
- Contacts
- Calendar
- Reminders
- Notifications
  - Authorization state and option granularity snapshot
- Pasteboard
  - Programmatic read probe
  - Explicit button read
  - System `PasteButton` path
- Files / Document Picker
- Motion / Sensors
- Media Library
- Local Network
  - Boundary note page and result snapshot

Each module writes a unified `PermissionExperimentResult` JSON record with:

- `permissionType`
- `osVersion`
- `deviceModel`
- `authorizationStatus`
- `authorizationSubstatus`
- `triggerAction`
- `timestamp`
- `fieldsCollected`
- `fieldsUnavailable`
- `boundaryFindings`
- `privacyRiskLevel`
- `privacyImpactSummary`
- `rawSamplePreview`
- `notes`

## App Structure

The main entry point is a new top-level tab: `Permission Lab`.

Inside the lab you will find:

- Module list with current authorization state
- Per-permission experiment pages
- Per-permission result pages
- Experiment overview page
- Local export page
- Risk analysis guide

Core implementation pieces:

- `PermissionBroker`
  - Centralizes permission status and request flows
- Extractors / experiment executors
  - One experiment implementation per permission family
- `PermissionLabResultStore`
  - Persists experiment results locally as JSON
- `PermissionRiskAnalyzer`
  - Generates short privacy impact summaries for teaching use

## Local Run

1. Clone the repository.
2. Create a local config file:

```bash
cp IceCubesApp.xcconfig.template IceCubesApp.xcconfig
```

3. Fill `DEVELOPMENT_TEAM` and `BUNDLE_ID_PREFIX` in `IceCubesApp.xcconfig`.
4. Open `IceCubesApp.xcodeproj`.
5. Build the `IceCubesApp` scheme for an iOS Simulator or a physical iPhone.
6. Launch the app and open the `Permission Lab` tab.

### Verified Build Command

The following command was used to verify the project builds for iOS Simulator in this workspace:

```bash
xcodebuild -quiet \
  -project IceCubesApp.xcodeproj \
  -scheme IceCubesApp \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/icecubes-build/derived2 \
  -clonedSourcePackagesDirPath /tmp/icecubes-build/spm \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## How To Demonstrate Results

Recommended demo flow:

1. Open `Permission Lab`.
2. Pick one module, for example `Photos`, `Location`, `Contacts`, or `Pasteboard`.
3. Check the current authorization state on the module page.
4. Tap `Request Permission` if needed.
5. Tap the experiment action that corresponds to the path you want to test.
6. Open the saved result page.
7. Review:
   - authorization state
   - collected fields
   - unavailable fields
   - sample preview
   - boundary findings
   - risk analysis
8. Repeat for multiple permissions.
9. Open `Experiment Overview` to discuss cross-permission inference risk.
10. Open `Local Export` to generate:
   - a JSON archive
   - a readable text summary

## Privacy And Ethics Constraints

This repository is intended for teaching and research, not covert data collection.

The lab explicitly avoids:

- hidden background capture
- automatic exfiltration of experiment data
- silent continuous collection loops
- bypass instructions for iOS system restrictions

Risk analysis in the UI is intentionally framed as privacy impact analysis, not attack guidance.

## Notes

- Some permissions expose status but not a universal authorization API. Local Network is the main example.
- Some fields are conditionally available depending on device, simulator, hardware, or whether the source data is local versus remote.
- Some APIs still surface deprecation warnings under the current SDK even though the app builds successfully. The current focus is lab usability and result clarity for coursework.
