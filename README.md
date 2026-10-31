# Orb

A 360° camera for iPhone: you follow dots on the screen, Orb takes the shots, and it stitches a
full spherical panorama on the phone. It does what Teleport: 360° Camera does for capture,
stitching, viewing and sharing. It has no account, no server and no paywall.

## Features

| Teleport: 360° Camera                                                     | Orb                                                                                                                                                                                                                                                                                                                                                                                             |
| ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Guided capture, 16 ultra-wide shots                                       | Guided capture laid out from the lens's real field of view: 15 ultra-wide shots (7 around the horizon, 4 up, 4 down), or about 44 with the 1× lens. The shutter fires by itself when the reticle sits still on a dot.                                                                                                                                                                           |
| Upside-down capture                                                       | Any roll works, the nadir included. The shot plan assumes only the frame's inscribed circle.                                                                                                                                                                                                                                                                                                    |
| On-device stitching                                                       | Sensor attitude, then coarse-to-fine overlap matching and rotation bundle adjustment (focal length refined too), then exposure-gain compensation, feathered equirectangular blending, and filling of any holes.                                                                                                                                                                                 |
| Pro mode                                                                  | Settings: lens, overlap (standard or dense), exposure lock, output 4K/6K/8K. Any capture can be re-stitched later at another size.                                                                                                                                                                                                                                                              |
| 360° viewer                                                               | A Metal viewer that turns sideways with the phone: drag, pinch, fling, gyro look-around, and a little-planet mode (double-tap) that morphs smoothly from the normal view. Shows the compass bearing you're facing, with an arrow to north.                                                                                                                                                      |
| Save to Photos, share                                                     | Saves to Photos or shares the JPEG with GPano XMP, so Google Photos, Facebook and other 360° viewers open it as a sphere. Like a camera photo, it carries the capture time and, if location is allowed, GPS in EXIF. It also carries the compass bearing of its centre, so every direction in it has a bearing. Also shares a little-planet image. Originals are in Files › On My iPhone › Orb. |
| Community feed, accounts, Street View upload, Vision Pro app, 3D "splats" | Not built. These need a server or third-party services.                                                                                                                                                                                                                                                                                                                                         |

## Build and run

You need a Mac with Xcode 16 or newer. Sally's macOS partition counts: hold the power button at
boot and pick macOS.

```sh
brew install xcodegen
cd orb && xcodegen          # writes Orb.xcodeproj from project.yml
open Orb.xcodeproj
```

In Xcode, open Signing & Capabilities for the Orb target and pick your Apple ID team (a free
account works, but the app expires after 7 days). Then plug in the iPhone and press Run. The
scheme runs a Release build on purpose: the stitcher is pixel loops, and a Debug build is about
20× slower.

**With Claude Code on the Mac.** Start `claude` in this folder and ask it to build and install
Orb. `CLAUDE.md` gives it the commands, the rules for fixing compile errors, and what to report
back.

**Without a Mac.** On push, `.github/workflows/build.yml` builds an unsigned IPA on a macOS
runner and attaches it to the run as an artifact. Sideload it with SideStore or AltStore (the
AltServer-Linux port runs on Linux).

## How it works

- `Packages/PanoCore`: the stitcher, in plain Swift with no Apple frameworks, so it builds and
  tests on Linux (`swift test -c release -Xswiftc -enable-testing` in the package, or the
  `swift:6.1` container). Its tests render a procedural sphere through simulated cameras,
  corrupt each "sensor" rotation by up to 2° and the focal length by 3%, and check that
  stitching recovers them: rotation error under 0.15° (measured 0.04°), focal length within
  0.5%, and PSNR going from 28 dB to 47 dB. At phone resolution (15 shots of 1500×2000, 6K
  output), a stitch takes 0.8 s on the M1 Pro. Expect a few seconds on an iPhone.
- `Orb/`: the iOS app. `Capture/` holds the AVFoundation camera, the Core Motion attitude
  history, the GPS and compass readings, and the guided-capture model and overlay. `Stitch/`
  decodes the shots, calls PanoCore and writes the outputs. `Viewer/` is the Metal panorama
  viewer. `Library/` holds the capture store and the screens.

Each capture is a folder `Documents/Captures/<uuid>/` that holds `capture.json` (its name,
description, folder, GPS position and compass heading, and per shot: file name and device-to-world
rotation), `shot-NN.heic`, and after stitching `pano.jpg` (equirectangular, 2:1, GPano XMP, EXIF GPS,
compass heading and capture time), `planet.jpg` and `thumb.jpg`. The GPS position averages the
fixes from the whole capture, weighted by their accuracy, keeping only those within 1.5× of the
best. The capture screen shows the live accuracy, and Details (⋯ › Details) the final position,
so you can check it before leaving the spot.

The shots' rotations come from the gyroscope alone, which keeps them steady but leaves north
unknown. So while capturing, a second Core Motion feed steered by the compass reads the same
attitudes against true north (magnetic north if location is off). Each pair of readings says
where north is in the gyroscope's frame, and Orb averages them over the capture, which points the
phone in every direction and so evens out the compass's swings. About two seconds in, the
capture screen starts showing the bearing the camera faces.

The panorama's centre gets that bearing, written as GPano `PoseHeadingDegrees` and EXIF
`GPSImgDirection` (reference `T` for true north, `M` for magnetic). Longitude grows to the right,
as bearings do, so a column `x` of a panorama `W` pixels wide faces
`PoseHeadingDegrees + 360 × (x + 0.5) / W − 180` degrees (modulo 360). The viewer shows the
bearing you face, and Details the centre's bearing and the spread of the compass readings.

## Names, descriptions, folders and sharing

- Drag a panorama onto a folder in the library to file it there.
- Touch and hold a panorama to rename it, describe it, move it to a folder, or share it. The
  detail view's ⋯ menu has the same.
- A description is free text of any length, shown in Details. Unlike a name, it isn't used as the
  title or the file name, and it isn't written into `pano.jpg`, so it isn't shared.
- The folder button at the top of the library makes a folder, and the same button inside a folder
  makes a folder within it, to any depth. Panoramas captured from inside a folder are filed in it.
  A folder's cover and count include its subfolders. Deleting a folder keeps what's in it, which
  moves up a level.
- Shared panoramas, and those saved to Photos, are named after the capture instead of `pano.jpg`:
  `Memorial Hall Steps.jpg`, or `Orb 2026-01-15 14.30.00.jpg` without a name. They are the same
  bytes as `pano.jpg`, so the GPS, capture time and 360° metadata go along.
- A folder's ⋯ menu shares all its panoramas at once, subfolders included, for example by AirDrop
  to a Mac for the game's `npm run photos:locations`.
- Names, descriptions and folders are kept in `capture.json` and
  `Library/Application Support/folders.json`. A folder is stored as its path, such as
  `Trips/Italy`, so a slash typed in a folder's name becomes a dash. Capture folders on disk keep
  their UUID names, and renaming never rewrites `pano.jpg`.

## Tips for clean stitches

- Turn the phone around the camera lens, not around your body. Parallax from swinging the
  phone at arm's length is what ruins seams on nearby objects.
- Keep exposure locked (the default) unless the scene has both very bright and very dark parts.
- Use dense overlap for plain walls, close interiors, or scenes with people moving.

## Tips for accurate GPS

- Shoot outdoors with open sky; buildings, trees, and indoors make GPS worse.
- Keep Precise Location on for Orb. If it's off, Orb asks to turn it on for the session.
- Watch the GPS label on the capture screen. If it still reads more than about ±10 m at the end,
  stay put a little longer, or capture again.

## Tips for an accurate compass heading

- Keep location on, so the heading is from true north. Without it, the heading is from magnetic
  north, about 11° off in Newark, and Details says so.
- Stand clear of cars, railings, steel pillars and big electronics. They bend the magnetic field
  near them. Steel inside buildings does too, so indoor headings are less reliable.
