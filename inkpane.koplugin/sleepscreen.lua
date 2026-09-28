-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 InkPane
-- See LICENSE for the full terms, THIRD_PARTY_NOTICES for included third-party code.

-- Sleep-screen mode. Instead of starting InkPane and letting it take over the
-- display, the Pane is simply what the e-reader shows while it sleeps: press
-- power and the Pane appears, press it again and the book is back. Asked for by
-- a reader (September 2026): "the only thing holding it back is that you have to
-- activate it every time".
--
-- Both halves follow WeatherLockscreen (github.com/loeffner/WeatherLockscreen,
-- AGPL-3.0), which does the same for weather:
--
--   * Taking over the sleep screen: Screensaver.show is wrapped, our own
--     full-screen widget is drawn when the mode is on, and KOReader's own sleep
--     screen is shown otherwise.
--   * Keeping it current while asleep ("Active Sleep"): a hardware wake alarm on
--     battery, a plain timer while charging. On a Kobo the wake is delivered while
--     the sleep screen is still up, so it is redrawn in place and KOReader puts the
--     device back to sleep. On a Kindle the wake brings the library back, so the
--     last Pane is put back at once, a fresh one fetched and swapped in, and the
--     Kindle sent back to sleep.
--
-- This is a separate engine from InkPane's display mode, and the two never run
-- together: sleep-screen mode is off whenever display mode is on.

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local ImageWidget = require("ui/widget/imagewidget")
local NetworkMgr = require("ui/network/manager")
local PluginShare = require("pluginshare")
local RenderImage = require("ui/renderimage")
local ScreenSaverWidget = require("ui/widget/screensaverwidget")
local Screensaver = require("ui/screensaver")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")

local Screen = Device.screen

-- A Pane fetched this recently is shown as it is when the device goes to
-- sleep, without switching Wi-Fi on: pressing power twice should not mean two
-- downloads.
local REUSE_WITHIN_SECONDS = 30 * 60
-- The oldest Pane still shown when a fresh one cannot be fetched. Past this,
-- the person's own sleep screen is more honest than old weather.
local STALE_AFTER_SECONDS = 60 * 60
-- How long to wait for Wi-Fi before giving up on a fresh Pane. Display mode's
-- budget: a Kindle just woken by an alarm can take most of it.
local CONNECT_GIVE_UP_SECONDS = 60
-- How long a Kindle stays awake after a refresh wake before being sent back to
-- sleep, if the fetch has not finished by then.
-- Has to cover a slow connect as well as the download.
local KINDLE_RESUSPEND_AFTER_SECONDS = 90

local function imagePath()
    return DataStorage:getDataDir() .. "/inkpane-sleep-screen.png"
end

local function imageAge()
    local modified = lfs.attributes(imagePath(), "modification")
    if not modified then return nil end
    return os.time() - modified
end

-- Switch Wi-Fi on ourselves, the way InkPane's display mode does. turnOnWifi
-- without its interactive flag never asks, so nobody has to change KOReader's
-- "Action when Wi-Fi is off" setting -- which would also change how every other
-- part of KOReader behaves. (WeatherLockscreen goes through goOnlineToRun, which
-- honours that setting and so needs it set to "turn on".)
-- Display mode's numbers, learned the hard way on Kindles woken by an alarm.
local WIFI_POLL_SECONDS = 3
-- isConnected goes true a moment before the connection is usable.
local WIFI_SETTLE_SECONDS = 2
-- Don't ask again before the radio has had this long to come up...
local WIFI_RADIO_SETTLE_SECONDS = 8
-- ...and not more often than this: asking restarts an attempt in progress.
local WIFI_RETRY_GAP_SECONDS = 25

-- Tried on a Kindle Basic (23 September), the simple version -- switch Wi-Fi on,
-- wait for isConnected -- failed on all three alarm wakes: isConnected was true
-- from stale state the moment it woke, so the request went out before there was
-- a network; then a connect that needed more than 25 seconds; then a response
-- that never came from our server at all. Display mode meets all three, so do
-- what it does: restore Wi-Fi the device's own way where there is one, refresh
-- KOReader's idea of the network before believing it, and ask again if slow.
local function connectThen(on_connected, on_failed)
    local has_restore = false
    pcall(function() has_restore = Device:hasWifiRestore() end)
    local ok
    if has_restore and NetworkMgr.restoreWifiAsync then
        ok = pcall(function() NetworkMgr:restoreWifiAsync() end)
    else
        ok = pcall(function() NetworkMgr:turnOnWifi(nil, false) end)
    end
    if not ok then return on_failed("wifi_error") end

    local started = os.time()
    local last_request = started
    local function poll()
        pcall(function() NetworkMgr:queryNetworkState() end)
        if NetworkMgr:isConnected() then
            UIManager:scheduleIn(WIFI_SETTLE_SECONDS, on_connected)
            return
        end
        local now = os.time()
        if now - started >= CONNECT_GIVE_UP_SECONDS then return on_failed("timeout") end
        if now - started >= WIFI_RADIO_SETTLE_SECONDS and now - last_request >= WIFI_RETRY_GAP_SECONDS then
            last_request = now
            pcall(function() NetworkMgr:turnOnWifi(nil, false) end)
        end
        UIManager:scheduleIn(WIFI_POLL_SECONDS, poll)
    end
    UIManager:scheduleIn(WIFI_POLL_SECONDS, poll)
end

-- A request that never completed (0), or a 503 that did not come from us, means
-- the network is not really up yet. Wait, then ask again.
local FETCH_RETRY_DELAY_SECONDS = 5
local FETCH_RETRIES = 2
local function retryable(status)
    return status == 0 or status == 502 or status == 503 or status == 504
end

local function onExternalPower()
    local ok, powered = pcall(function()
        local powerd = Device:getPowerDevice()
        return (powerd.isCharging and powerd:isCharging()) or (powerd.isCharged and powerd:isCharged())
    end)
    return ok and powered or false
end

-- Flips a Kindle between asleep and awake through its power daemon, the way
-- the power button does. Used both to wake it for a refresh and to send it back.
local function toggleSuspend()
    local powerd = Device:getPowerDevice()
    if powerd and powerd.toggleSuspend then
        powerd:toggleSuspend()
    elseif Device.suspend then
        Device:suspend()
    end
end

return function(InkPane)
    -- KOReader builds one plugin instance per UI; the sleep screen is drawn
    -- outside it, so keep hold of the current one.
    local active

    local original_init = InkPane.init
    function InkPane:init()
        original_init(self)
        active = self

        self.sleep_rtc_task = function()
            self.sleep_rtc_scheduled = false
            self:oplog("sleep_refresh_fired", "kobo=" .. tostring(Device:isKobo()))
            if not self:sleepScreenWanted() then return end
            if Device:isKobo() then
                -- Delivered while the sleep screen is still up. Redraw on the UI
                -- loop, not inside KOReader's wake handling; KOReader puts the
                -- device back to sleep 30 seconds after delivering the wake.
                UIManager:scheduleIn(0, function()
                    if Device.screen_saver_mode and self:sleepScreenWanted() then
                        self.sleep_refresh_in_place = true
                        Screensaver:show()
                    end
                end)
            else
                -- A Kindle has to be woken properly for the screen to be ours;
                -- onResume takes it from there.
                self.sleep_simulated_wakeup = true
                toggleSuspend()
            end
        end

        self.sleep_charging_task = function()
            if not (Device.screen_saver_mode and self:sleepScreenWanted()) or not onExternalPower() then
                self:cancelSleepRefresh()
                return
            end
            self:oplog("sleep_refresh_fired", "charging=true")
            self.sleep_refresh_in_place = true
            Screensaver:show()
        end
    end

    -- Off unless chosen, only once the e-reader is paired, and never while
    -- InkPane's own display mode is running, which already owns the screen.
    function InkPane:sleepScreenWanted()
        return self.settings ~= nil
            and self.settings.sleep_screen == true
            and self.settings.paired == true
            and not self.auto_refresh_enabled
    end

    function InkPane:cancelSleepRefresh()
        if Device.wakeup_mgr and self.sleep_rtc_task then
            Device.wakeup_mgr:removeTasks(nil, self.sleep_rtc_task)
        end
        self.sleep_rtc_scheduled = false
        if self.sleep_charging_task then UIManager:unschedule(self.sleep_charging_task) end
        if self.sleep_charging then
            self.sleep_charging = false
            PluginShare.pause_auto_suspend = false
        end
    end

    -- Arms the next refresh while the sleep screen is up.
    function InkPane:scheduleSleepRefresh()
        self:cancelSleepRefresh()
        if not self:sleepScreenWanted() then return end
        -- No low-battery cut-off, same as display mode: it keeps refreshing
        -- until the battery runs out, rather than stopping silently at 20%.

        local interval = self:getRefreshInterval()
        if onExternalPower() then
            -- Plugged in: no need to deep-sleep between refreshes, and a Kobo
            -- refuses to while charging anyway.
            self.sleep_charging = true
            PluginShare.pause_auto_suspend = true
            UIManager:scheduleIn(interval, self.sleep_charging_task)
            self:oplog("sleep_refresh_queued", "in=" .. interval .. " charging=true")
        elseif Device.wakeup_mgr then
            Device.wakeup_mgr:addTask(interval, self.sleep_rtc_task)
            self.sleep_rtc_scheduled = true
            self:oplog("sleep_refresh_queued", "in=" .. interval .. " charging=false")
        end
    end

    function InkPane:drawSleepScreen(screensaver)
        local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
        local image_bb = RenderImage:renderImageFile(imagePath(), true, screen_w, screen_h)
        if not image_bb then return false end
        local image = ImageWidget:new {
            image = image_bb,
            image_disposable = true,
            width = screen_w,
            height = screen_h,
        }

        -- Refreshing: swap the picture inside the sleep screen already up.
        -- Closing a ScreenSaverWidget restores rotation and clears the sleep
        -- state as a side effect, so it must not be closed and reopened while
        -- the device is meant to stay asleep.
        local on_screen = screensaver.screensaver_widget
        if on_screen and on_screen == self.sleep_screen_widget and on_screen[1] then
            local frame = on_screen[1]
            if frame[1] and frame[1].free then frame[1]:free() end
            frame[1] = image
            on_screen.widget = image
            UIManager:setDirty(on_screen, "full")
            return true
        end

        local widget = ScreenSaverWidget:new {
            widget = image,
            background = Blitbuffer.COLOR_WHITE,
            covers_fullscreen = true,
        }
        widget.modal = true
        widget.dithered = true
        screensaver.screensaver_widget = widget
        self.sleep_screen_widget = widget
        UIManager:show(widget, "full")
        return true
    end

    -- KOReader's own sleep screen, exactly as if we were not here.
    function InkPane:showOwnSleepScreen(screensaver)
        Device.screen_saver_mode = false
        self.sleep_screen_widget = nil
        Screensaver._inkpane_original_show(screensaver)
    end

    function InkPane:showSleepScreen(screensaver)
        local refreshing = self.sleep_refresh_in_place == true
        local last_only = self.sleep_refresh_last_only == true
        self.sleep_refresh_in_place = false
        self.sleep_refresh_last_only = false

        Device.screen_saver_mode = true
        self:scheduleSleepRefresh()

        -- Kindle refresh wake, first step: put the last Pane straight back.
        if last_only then
            if imageAge() and self:drawSleepScreen(screensaver) then
                self:oplog("sleep_screen", "shown=last_on_wake")
            end
            return
        end

        local age = imageAge()
        if not refreshing and age and age < REUSE_WITHIN_SECONDS and self:drawSleepScreen(screensaver) then
            self:oplog("sleep_screen", "shown=recent age=" .. age)
            return
        end

        -- Put the last Pane up straight away while a fresh one is fetched, so
        -- going to sleep never leaves the book page showing for as long as
        -- Wi-Fi takes. From here on it is a refresh of what is on screen.
        if not refreshing and age and age < STALE_AFTER_SECONDS and self:drawSleepScreen(screensaver) then
            self:oplog("sleep_screen", "shown=last_while_fetching age=" .. age)
            refreshing = true
        end

        -- Exactly one outcome per attempt, whichever path gets there first: a
        -- late network callback must not draw over something already shown.
        local settled = false
        local function done()
            if self.sleep_on_settled then
                local callback = self.sleep_on_settled
                self.sleep_on_settled = nil
                callback()
            end
        end

        local function lastOrOwn(reason)
            if settled then return end
            settled = true
            if refreshing then
                -- A refresh that failed leaves the current Pane up rather than
                -- replacing it with anything else.
                self:oplog("sleep_screen", "kept_current reason=" .. reason)
                return done()
            end
            local last_age = imageAge()
            if last_age and last_age < STALE_AFTER_SECONDS and self:drawSleepScreen(screensaver) then
                self:oplog("sleep_screen", "shown=last age=" .. last_age .. " reason=" .. reason)
            else
                self:oplog("sleep_screen", "shown=own reason=" .. reason)
                self:showOwnSleepScreen(screensaver)
            end
            done()
        end

        local was_online = NetworkMgr:isOnline()

        local function fetchAndDraw(attempt)
            if settled then return end
            attempt = attempt or 0
            local response, status = self:fetchMetadata()
            if retryable(status) and attempt < FETCH_RETRIES then
                self:oplog("sleep_screen", "retry http=" .. tostring(status) .. " n=" .. (attempt + 1))
                UIManager:scheduleIn(FETCH_RETRY_DELAY_SECONDS, function()
                    local ok = pcall(fetchAndDraw, attempt + 1)
                    if not ok then lastOrOwn("error") end
                end)
                return
            end
            if status ~= 200 or not response or not response.image_url then
                return lastOrOwn("http" .. tostring(status))
            end
            local partial = imagePath() .. ".part"
            if not self:downloadImage(response.image_url, partial) then
                os.remove(partial)
                return lastOrOwn("download")
            end
            os.remove(imagePath())
            os.rename(partial, imagePath())
            if settled then return end
            if self:drawSleepScreen(screensaver) then
                settled = true
                self:oplog("sleep_screen", "shown=fresh refresh=" .. tostring(refreshing))
                done()
            else
                lastOrOwn("draw")
            end
        end

        if was_online then
            local ok = pcall(fetchAndDraw)
            if not ok then lastOrOwn("error") end
            return
        end

        -- Leave Wi-Fi as we found it -- off again, since we switched it on --
        -- but only once this attempt has finished, retries included.
        local previous_done = done
        done = function()
            pcall(function() NetworkMgr:turnOffWifi() end)
            previous_done()
        end
        connectThen(function()
            local fetched = pcall(fetchAndDraw)
            if not fetched then lastOrOwn("error") end
        end, function(reason)
            lastOrOwn(reason)
        end)
    end

    -- Kindle refresh wakes arrive as an ordinary resume. Anything else is a
    -- person waking the device, which InkPane's display mode handles as before.
    local original_on_resume = InkPane.onResume
    function InkPane:onResume()
        if not self.sleep_simulated_wakeup then
            if not Device.screen_saver_mode then self:cancelSleepRefresh() end
            if original_on_resume then return original_on_resume(self) end
            return
        end
        self.sleep_simulated_wakeup = false
        self:oplog("sleep_refresh_kindle_wake")

        -- Step 1: the library is showing. Put the last Pane back at once.
        self.sleep_refresh_last_only = true
        Screensaver:show()

        -- Step 2: fetch a fresh Pane and swap it in, then back to sleep as soon
        -- as that settles -- or after a fixed time, whichever comes first.
        local slept = false
        local function backToSleep()
            if slept then return end
            slept = true
            if Device.screen_saver_mode and self:sleepScreenWanted() then
                self:oplog("sleep_refresh_kindle_resuspend")
                toggleSuspend()
            end
        end
        self.sleep_on_settled = backToSleep
        UIManager:scheduleIn(KINDLE_RESUSPEND_AFTER_SECONDS, backToSleep)
        self.sleep_refresh_in_place = true
        Screensaver:show()
    end

    local original_on_close = InkPane.onCloseWidget
    function InkPane:onCloseWidget()
        self:cancelSleepRefresh()
        if original_on_close then return original_on_close(self) end
    end

    -- Installed once per KOReader session, whichever instance loads first.
    if not Screensaver._inkpane_original_show then
        Screensaver._inkpane_original_show = Screensaver.show
        Screensaver.show = function(screensaver)
            local plugin = active
            if plugin and plugin:sleepScreenWanted() then
                local ok, err = pcall(function() plugin:showSleepScreen(screensaver) end)
                if ok then return end
                logger.warn("InkPane: sleep screen failed, showing the usual one:", err)
                pcall(function() plugin:showOwnSleepScreen(screensaver) end)
                return
            end
            return Screensaver._inkpane_original_show(screensaver)
        end
    end

    local original_add_to_main_menu = InkPane.addToMainMenu
    function InkPane:addToMainMenu(menu_items)
        original_add_to_main_menu(self, menu_items)
        local menu = menu_items.inkpane
        if not (menu and menu.sub_item_table) then return end
        table.insert(menu.sub_item_table, {
            text = _("Show on sleep screen"),
            checked_func = function()
                return self.settings ~= nil and self.settings.sleep_screen == true
            end,
            callback = function()
                self.settings.sleep_screen = not (self.settings.sleep_screen == true)
                if not self.settings.sleep_screen then self:cancelSleepRefresh() end
                self:saveSettings()
                self:oplog("sleep_screen_setting", tostring(self.settings.sleep_screen))
            end,
        })
    end

    return InkPane
end
