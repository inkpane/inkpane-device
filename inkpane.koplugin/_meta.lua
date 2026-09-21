-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 InkPane
-- See LICENSE for the full terms.

local _ = require("gettext")
return {
    name = "inkpane",
    -- Kept in step with kpm/package/manifest.json. KOReader itself ignores
    -- this; the community app store reads it to decide whether an installed
    -- copy is older than the one in the public repo.
    version = "1.0.5",
    fullname = _("InkPane"),
    description = _([[Pairs this e-reader with InkPane, fetches its dashboard image, and can use Kindle RTC wakeups for low-power refreshes.]]),
}
