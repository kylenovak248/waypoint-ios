# Waypoint for iPhone

Waypoint's location simulator, running on the iPhone itself. No computer is
needed once the app is installed.

**Features:** map with search and coordinates, Set Location, Restore Real
Location, favorites, routes played at a chosen speed, and history. Your
places are saved on the phone.

## How it works

iOS only lets developer tools change the phone's location. Waypoint uses the
same developer services the Windows version reaches over USB, but reaches
them on the phone through a loopback VPN (LocalDevVPN). This is the same
method StikDebug uses, built on the open-source
[idevice](https://github.com/jkcoxson/idevice) library.

## Install (one time)

1. **Get the app file.** Download `Waypoint.ipa` from the latest
   [release](../../releases/latest).
2. **Sideload it** with SideStore, AltStore or Sideloadly (on your PC). They
   sign it with your Apple ID. With a free Apple ID, apps must be refreshed
   every 7 days (SideStore can do this on the phone).
3. **Developer Mode:** Settings › Privacy & Security › Developer Mode › On.
4. **LocalDevVPN:** install it from the App Store, open it and turn it on.
5. **Pair:** in Waypoint, open **Setup › Pair This iPhone**, then open
   Settings › Privacy & Security › Developer Mode, tap **Pair with
   Waypoint-XXXX**, and type the code Waypoint shows (iOS 27 or later).
   On older iOS, import a pairing file made on a computer instead.
6. Tap **Connect and Prepare iPhone**. The first time, Waypoint downloads
   Apple's developer support files (about 20 MB).

## Daily use

Turn on LocalDevVPN, open Waypoint, pick a place, and tap **Set Location**.
Waypoint keeps running in the background while a location is active (it
uses background location and silent audio for that). Tap **Restore Real
Location** when you're done. Restarting the iPhone also restores it.

Only use location simulation on devices you own, and respect the rules of
the apps and services you use.

## Building

GitHub Actions builds the unsigned IPA on every push to `main`
(`.github/workflows/build.yml`): it compiles idevice for iOS
(`scripts/build_idevice.sh`), runs the device-layer tests, generates the
Xcode project with XcodeGen (`project.yml`) and archives the app.

On a Mac: `scripts/build_idevice.sh && xcodegen generate`, then open
`Waypoint.xcodeproj`.

## Layout

- `Waypoint/Device/wp_device.c` – small C layer over idevice: on-device
  pairing, tunnel, developer support, location simulation
- `Waypoint/Services` – connection logic, pairing, downloads, keep-alive
- `Waypoint/Views` – SwiftUI screens
- `tests/wp_device_test.c` – checks for the C layer that run without a phone

## License

GPL-3.0, like Waypoint for Windows. idevice is MIT licensed.
