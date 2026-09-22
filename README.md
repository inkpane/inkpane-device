# InkPane Device

The device-side client for InkPane-supported e-ink displays. It currently integrates with [KOReader](https://koreader.rocks).

InkPane is not affiliated with or endorsed by KOReader.

This repository covers the device client only. The hosted InkPane service and its backend are not included.

## What it does

1. **Tools → InkPane → Pair this e-reader** registers it and shows a pairing code.
2. You enter that code once at [inkpane.ink](https://inkpane.ink).
3. From then on the e-reader fetches its screen image and displays it.
4. On Kindles with RTC support it schedules a hardware wake, turns Wi-Fi on for the refresh, turns it off again, and suspends.

## Install

Copy `inkpane.koplugin/` into your e-reader's `koreader/plugins/` folder, restart KOReader, then open **Tools → InkPane**.

The folder here is the installed layout, so it needs no renaming or build step.

If another auto-refreshing display plugin is installed, remove it first. Two plugins driving one device fight over the same wake alarm.

## Licence

AGPL-3.0-only. See [LICENSE](LICENSE).

Third-party code included in the plugin is listed in [THIRD_PARTY_NOTICES](inkpane.koplugin/THIRD_PARTY_NOTICES).
