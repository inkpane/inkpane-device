# InkPane Device

The device-side client for InkPane-supported e-ink displays. It currently integrates with [KOReader](https://koreader.rocks).

InkPane is not affiliated with or endorsed by KOReader.

This repository covers the device client only. The hosted InkPane service and its backend are not included.

## What it does

1. On first fetch the e-reader registers itself and shows a six-character pairing code.
2. You enter that code once at [inkpane.ink](https://inkpane.ink).
3. From then on the e-reader fetches its screen image and displays it.
4. On Kindles with RTC support it schedules a hardware wake, turns Wi-Fi on for the refresh, turns it off again, and suspends.

## Install

Copy `inkpane.koplugin/` into your e-reader's `koreader/plugins/` folder, restart KOReader, then open **Tools → InkPane** and choose **Fetch screen now**.

The installed plugin expects `main-entry.lua` to be named `main.lua`, with `main.lua` shipped alongside it as `main_rtc.lua`. The build script does this for you.

If another auto-refreshing display plugin is installed, remove it first. Two plugins driving one device fight over the same wake alarm.

## Build

    sh kpm/build.sh

Produces a `.kpkg` package for KOReader's package manager.

## Licence

AGPL-3.0-only. See [LICENSE](LICENSE).

Third-party code included in the plugin is listed in [THIRD_PARTY_NOTICES](inkpane.koplugin/THIRD_PARTY_NOTICES).
