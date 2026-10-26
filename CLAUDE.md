# Orb: notes for Claude Code

Orb is an iPhone app for 360° photos: guided capture, on-device stitching, a 360° viewer, and
export. Nate (ncb@udel.edu) wrote it with Claude Code on Linux, which has no Xcode.

- **Tested:** the stitching core, `Packages/PanoCore` (Linux, `swift test`; also passes on macOS
  with Xcode 27.1).
- **Compiles, never run on a phone:** the app target, `Orb/`. The unsigned Release build in
  section 3 succeeds with Xcode 27.1, with no code changes.

If you are running on a Mac for a teammate, your job is almost certainly: **get Orb compiling, then
installed on an iPhone, with as few changes as possible, and report what you changed.**

## 1. Check the tools

```sh
xcodebuild -version          # needs Xcode 16 or newer
xcodegen --version || brew install xcodegen
xcrun -f metal || xcodebuild -downloadComponent MetalToolchain   # a separate download since Xcode 26
```

If `xcode-select -p` points at the Command Line Tools, prefix the commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (no sudo needed), or ask the human to
run `sudo xcode-select -s /Applications/Xcode.app`.

## 2. Run the core tests (fast, no signing)

```sh
cd Packages/PanoCore && swift test -c release -Xswiftc -enable-testing && cd ../..
```

Every test passes. `PerfTests` and `DumpTests` skip unless `ORB_PERF=1` or `ORB_DUMP=<dir>` is
set. Always use `-c release`: the synthetic image renders are very slow in debug.

## 3. Generate the project and compile without signing

```sh
xcodegen   # writes Orb.xcodeproj from project.yml; it's gitignored, so never hand-edit it
xcodebuild -project Orb.xcodeproj -scheme Orb -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build \
  2>&1 | grep -E 'error:|\*\* BUILD' | head -50
```

Repeat until you get `** BUILD SUCCEEDED **`. Fix errors under the rules in section 6. If you edit
`project.yml`, run `xcodegen` again.

## 4. Install on the iPhone

**The human's part.** Ask them to do this; you can't:

- Sign in to an Apple ID in Xcode (Settings › Accounts). A free account works, but the app
  expires after 7 days.
- Plug in the phone and unlock it, then tap Trust.
- Turn on Developer Mode (Settings › Privacy & Security), which needs a restart.

**Your part.**

```sh
xcrun devicectl list devices                       # the phone's identifier (UDID)
security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject   # OU=<TEAM_ID>
xcodebuild -project Orb.xcodeproj -scheme Orb -configuration Release \
  -destination 'id=<UDID>' -derivedDataPath build -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<TEAM_ID> build
xcrun devicectl device install app --device <UDID> build/Build/Products/Release-iphoneos/Orb.app
xcrun devicectl device process launch --device <UDID> com.nathanielcblack.orb
```

- **Bundle ID already taken.** If signing fails because `com.nathanielcblack.orb` is taken under
  this team, add `PRODUCT_BUNDLE_IDENTIFIER=com.<something-unique>.orb` to the build command.
  Use the same ID in the launch command.
- **Untrusted developer on first launch** (free accounts): on the phone, open Settings › General ›
  VPN & Device Management and trust the developer.
- **GUI fallback.** Open `Orb.xcodeproj`, set Team under Signing & Capabilities, choose the phone,
  and press ⌘R. A team chosen there is lost the next time `xcodegen` runs.
- **Debug is too slow.** The Run action uses the Release configuration on purpose: the stitcher
  is pixel loops and about 20× slower in Debug. Don't switch it back.

## 5. Hand the work back

- **Where to commit.** This folder lives in the team repo `udelawhere` as `orb/`, on branch
  `feature/orb-360-capture`. Follow `../CONTRIBUTING.md`: small commits with imperative
  summaries, and never push to `main`.
- **Before pushing,** run `npx prettier --write orb/ && npm run check` from the repo root. The
  repo's CI runs Prettier on the `.md`, `.json` and `.yml` files in here.
- **Tell Nate what you changed,** file by file, and anything you could not verify.
- **`.github/workflows/build.yml` does nothing here.** It is for a GitHub copy of Orb; GitLab
  never runs it.

## 6. Rules for fixing compile errors

- **Smallest fix, in `Orb/`.** No restructuring or renaming, and no new dependencies.
- **`PanoCore` stays Foundation-only.** No UIKit, simd, Accelerate or Apple-only API, because it
  must keep building and testing on Linux. Code that needs Apple frameworks belongs in `Orb/`.
- **Keep Swift 5 language mode** (`SWIFT_VERSION: "5.0"`). Concurrency warnings are expected.
  Don't switch to Swift 6 or add `@preconcurrency` or `nonisolated(unsafe)` just to quiet them.
- **Don't change the coordinate conventions, the Metal uniform layout, or the shot-plan math**
  (section 8) to make something compile.
- **Spots that were uncertain when written.** Check these first if they error:
  - `ImageCodec.panoramaMetadata` returns the result of `CGImageMetadataCreateMutable()` as
    `CGImageMetadata`.
  - `.toolbar { if … { bottomBar } }` in `PanoDetailView`.
  - The `Canvas` closure in `CaptureView` calls the `@MainActor` `CaptureOverlay.draw`.
  - `CAMetalLayer.colorspace` in `PanoViewer`.
  - SF Symbol names: a wrong name doesn't break the build, it just shows a blank icon.

## 7. First run on the phone

Don't drive the phone's UI or send it input. Ask the human to check these and tell you:

- **Capture screen.** The yellow and white dots should stay fixed on the scene as the phone
  turns.
  - Dots that move the wrong way, mirrored or upside down, mean the attitude or camera axes are
    wrong: see `MotionTracker` and `deviceFromBackCamera` in `PanoCore/Camera.swift`.
  - Dots that are offset but move the right way point at the FOV or preview scaling in
    `CaptureOverlay`.
- **Shutter.** It fires by itself after about 0.3 s held still on a dot. The counter rises to
  about 15 with the 0.5× lens, or about 44 with 1×.
- **Stitching.** The library shows progress, and a panorama appears in a few seconds.
- **Details** (⋯ › Details) shows alignment RMS. Under about 0.1° is good; several degrees
  means the matching failed.
- **Location.** The first capture asks for location before the camera starts (and for precise
  location, whenever it's off). The capture screen shows "GPS ±N m" under the shot counter,
  usually settling to a few metres outdoors. Details shows the final position, or "Not
  recorded" if location was denied or approximate, or there was no fix (common indoors).
- **Report back.** Nate wants a raw capture folder for tuning: Files › On My iPhone › Orb ›
  Captures › `<uuid>`, which holds `capture.json`, `shot-NN.heic` and `pano.jpg`.

## 8. How the code fits together

### Layout

- `Packages/PanoCore/`: the stitcher.
  - `ShotPlan` decides where to point the camera.
  - `Matcher`, `BundleAdjuster`, `Blender` and `Stitcher` do the stitching.
  - `PanoRender.littlePlanet` draws the little-planet image.
  - Tests render a procedural sphere through simulated cameras, corrupt the rotations and focal
    length, and check that stitching recovers them.
- `Orb/Capture/`: `CameraController` (AVFoundation, photo output, exposure lock),
  `MotionTracker` (Core Motion attitude history), `LocationTracker` (Core Location, an
  accuracy-weighted average of the best fixes during a capture), `CaptureModel` (target logic and auto-shutter), `CaptureView`
  (preview, overlay, controls).
- `Orb/Stitch/`: `StitchService` (a queue, off the main thread), `StitchJob` (decode, stitch,
  write `pano.jpg`, `planet.jpg`, `thumb.jpg`), `ImageCodec` (ImageIO, Display P3, GPano XMP,
  EXIF GPS and capture time).
- `Orb/Viewer/`: `PanoViewer` (MTKView, gestures, gyro) and `Pano.metal` (each pixel becomes a
  ray, then an equirectangular texture lookup; rectilinear ↔ stereographic morph).
- `Orb/Library/`: `CaptureStore` (`Documents/Captures/<uuid>/capture.json`), the library grid,
  and the detail view (share, save to Photos, re-stitch, delete).

### Coordinate conventions (don't change these)

- **World frame.** Z is up (gravity), and X is the panorama's centre. Equirectangular `u` grows
  to the viewer's right, so +longitude is −Y. `Equirect.direction` and `Equirect.uv` must agree
  with `Pano.metal`.
- **Camera frame.** x right, y down, z forward. `PinholeCamera.rotation` maps camera to world.
- **Device frame** (Core Motion). x right, y toward the top edge, z out of the screen.
  - Camera rotation = deviceToWorld × `deviceFromBackCamera`.
  - The photo connection uses `videoRotationAngle = 90`, so shots decode upright as portrait.
  - A landscape decode falls back to `deviceFromNativeBackCamera`.
- **CMQuaternion convention.** `MotionTracker` decides it at runtime by checking against
  gravity.
- **Viewer.** In portrait, the view frame is the device frame. The drag camera is
  `yaw · base · Rx(pitch)`.
- **Uniforms.** `PanoRenderer.Uniforms` and the `Uniforms` struct in `Pano.metal` are both
  64 bytes, with float3x3 taking 48. Change them together.

### Stitching pipeline

1. **Start** from the sensor rotations.
2. **Align in 3 rounds** at 0.35, 0.15 and 0.07 degrees per patch pixel, each clamped to what
   the source images resolve. Each round:
   - renders a tangent-plane patch for every overlapping pair;
   - block-matches the patches with NCC (17×17 blocks, subpixel peak, distinctiveness test);
   - runs rotation-only Levenberg–Marquardt bundle adjustment. The residual is between rays,
     with a Huber loss and shot 0 held fixed. Priors: 0.6° tilt, 4° yaw, 8% focal length.
3. **Even out exposure** with gain compensation from overlap means (Brown & Lowe).
4. **Blend** with feather weights `(wx·wy)^3`, rendering the equirectangular output in parallel
   strips.
5. **Fill holes** by push-pull.
6. **Centre** the output on shot 0's heading.

### Known gaps

- Moving people ghost; multi-band blending or seam cutting would fix that.
- Alignment doesn't model parallax.
- No HDR brackets.
- No visionOS viewer.
- No Street View upload.
