-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 InkPane
-- See LICENSE for the full terms.

-- Pairing-state extension for InkPane.
--
-- The first visit says "Pair this e-reader" and shows one persistent pairing
-- code. Once a code exists, the next useful action on the Kindle is always
-- "Fetch screen now": before the website claim it simply re-shows the same
-- code; after the claim it fetches the selected Pane.

local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

return function(InkPane)
    InkPane.default_settings.paired = false

    local original_register_device = InkPane.registerDevice
    local original_fetch_metadata = InkPane.fetchMetadata
    local original_perform_fetch = InkPane.performFetch
    local original_handle_revoked_token = InkPane.handleRevokedToken
    local original_add_to_main_menu = InkPane.addToMainMenu

    function InkPane:showPairingCode()
        if not self.settings.pairing_code then
            self:notify(_("This device is not registered yet."))
            return
        end

        UIManager:show(InfoMessage:new {
            text = _("Pair this e-reader") .. "\n\n" ..
                _("Code: ") .. self.settings.pairing_code .. "\n\n" ..
                _("Open InkPane on your phone or computer and enter this code. When pairing is complete, close this message and choose Fetch screen now."),
        })
    end

    function InkPane:registerDevice(complete_callback)
        self.settings.paired = false
        self.settings.pairing_expires_at = nil
        return original_register_device(self, complete_callback)
    end

    function InkPane:fetchMetadata()
        if self._pairing_cached_metadata then
            local cached = self._pairing_cached_metadata
            self._pairing_cached_metadata = nil
            return cached.response, cached.status, cached.body
        end
        return original_fetch_metadata(self)
    end

    function InkPane:performFetch(background, is_retry)
        local response, status, body = original_fetch_metadata(self)

        if status == 200 and response and response.pairing_required then
            self.settings.paired = false
            self.auto_refresh_enabled = false

            if response.pairing_code and response.pairing_code ~= "" then
                self.settings.pairing_code = response.pairing_code
            end
            self.settings.pairing_expires_at = nil

            self:saveSettings()
            self:oplog("pairing_required")

            if not background then
                self:showPairingCode()
            end

            self:releaseWifi()
            self:endCycle()
            return
        end

        if status == 200 and response and response.paired == true and response.setup_required then
            self.settings.paired = true
            self.settings.pairing_code = nil
            self.settings.pairing_expires_at = nil
            self.auto_refresh_enabled = false
            self:saveSettings()
            self:oplog("pairing_confirmed_setup_required")

            if not background then
                -- No Pane is added at pairing. This used to say "Finish setting
                -- up Weather", from when every account started with Weather,
                -- which is now a Pro Pane; the free weather Pane is Weather Curve.
                self:notify(_("Paired. Pick a Pane on inkpane.ink, like Weather Curve, then choose Fetch screen now."), 8)
            end

            self:releaseWifi()
            self:endCycle()
            return
        end

        if status == 200 and response and response.paired == true and self.settings.paired ~= true then
            self.settings.paired = true
            self.settings.pairing_code = nil
            self.settings.pairing_expires_at = nil
            self:saveSettings()
            self:oplog("pairing_confirmed")
        end

        self._pairing_cached_metadata = {
            response = response,
            status = status,
            body = body,
        }
        return original_perform_fetch(self, background, is_retry)
    end

    -- allow_clear must be forwarded. Swallowing it here would mean the base
    -- client never sees a manual fetch as manual, so a genuinely removed
    -- display could never clear itself and re-pair.
    function InkPane:handleRevokedToken(allow_clear)
        self.settings.paired = false
        return original_handle_revoked_token(self, allow_clear)
    end

    function InkPane:addToMainMenu(menu_items)
        original_add_to_main_menu(self, menu_items)

        local inkpane_menu = menu_items.inkpane
        local action = inkpane_menu and inkpane_menu.sub_item_table and inkpane_menu.sub_item_table[1]
        if not action then return end

        action.text = nil
        action.text_func = function()
            if self.settings and (
                self.settings.paired == true
                or (self.settings.pairing_code and self.settings.pairing_code ~= "")
            ) then
                return _("Fetch screen now")
            end
            return _("Pair this e-reader")
        end
    end

    return InkPane
end
