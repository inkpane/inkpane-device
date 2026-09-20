-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 InkPane
-- See LICENSE for the full terms, THIRD_PARTY_NOTICES for included third-party code.

--[[
InkPane plugin for KOReader.

The network/image-display portions follow the TRMNL KOReader plugin's MIT-licensed
approach. InkPane adds first-run device registration + pairing and an RTC-backed
low-power refresh path for Kindles.
]]

local DataStorage = require("datastorage")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local PluginShare = require("pluginshare")
local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local Screen = Device.screen
local Input = Device.input

-- How long after drawing a Pane the device is allowed to go back to sleep.
-- Counted from the moment the image is handed to the screen (see
-- applyAutoSuspendTimeout), not from the start of the wake. E-ink finishes
-- drawing a second or two after we ask, and Wi-Fi is switched off in the same
-- moment, so sleeping instantly could cut either short; ten seconds leaves room
-- for both. It was 30, which only had to be well clear of the next alarm, and
-- the extra 20 seconds were spent awake on every wake.
local DISPLAY_SUSPEND_TIMEOUT = 10
-- How long to let KOReader's own machinery deliver the wake before assuming it
-- never will. On Kindle the RTC task is executed from checkUnexpectedWakeup,
-- which is scheduled 15 seconds after the resume and silently declines if
-- Amazon's power state has moved to "active" -- which is what a single stray
-- touch during those 15 seconds causes.
local WAKE_DELIVERY_GRACE = 40
local WIFI_CONNECT_ATTEMPTS = 3
local WIFI_POLL_INTERVAL = 3
-- turnOnWifi does not poll -- it re-enables the radio and starts a fresh
-- scan-and-associate, so asking again restarts an attempt already in progress.
-- Within a 60-second budget that means two tries rather than four interrupted
-- ones, which costs nothing on a device that associates quickly and stops us
-- interfering with one that does not.
local WIFI_RETRY_GAP = 25
-- Briefly raised to 180 on 2026-09-13. It made things worse, and the reason is
-- worth keeping.
--
-- A Kindle Scribe never associates on a cold RTC wake: the radio reports itself
-- on, turnOnWifi returns ok, and nothing connects. What was keeping it working
-- at half rate was an accident -- the failed attempt leaves the radio switched
-- on, the device sleeps for the rest of the interval, and by the next wake it
-- has associated on its own. Giving up early is what creates that gap.
--
-- At 180 the device fell asleep about 70 seconds in, which freezes every
-- scheduled timer, so the deadline was only noticed when the NEXT alarm woke
-- it -- twelve minutes late, fourteen seconds before the following cycle. The
-- quiet interval that was doing all the work disappeared, and every wake then
-- started cold.
--
-- So: fail fast, on purpose. Sixty seconds is not patience, it is how much
-- sleeping time is left afterwards for the radio to sort itself out.
local WIFI_TOTAL_BUDGET = 60

-- How long the radio gets to settle after being switched on, before anything
-- asks it to associate. Enabling and scanning in the same breath is what made
-- turnOnWifi fail instantly on a cold radio ("scan yielded no results"), so the
-- gap is the whole point.
local WIFI_RADIO_SETTLE = 8

-- How long to wait for a software power-button press to actually land the
-- device in the active state. Bounded hard: this blocks the cycle.
local WAKE_CONFIRM_TICKS = 10
local WAKE_CONFIRM_TICK_MS = 200
local HTTP_TIMEOUT_SECONDS = 20

-- The image is not the metadata. /api/display returns a few hundred bytes and
-- should fail fast; the screen itself is 2.6 MB on a Scribe, and the server has
-- to draw it before a byte moves. Measured on device: 12, 12, 13, 13, 14 and 16
-- seconds -- against a 20-second limit, with one failure at exactly 20. That is
-- not a slow network, it is a ceiling sitting in the middle of the normal range.
local IMAGE_TIMEOUT_SECONDS = 90
local MIN_REFRESH_INTERVAL = 300
-- Two hours: the fastest rate a free display is actually refreshed at. It used
-- to be one hour, which is now a Pro interval -- so a newly paired free device
-- would have defaulted to waking twice as often as the screen could change.
local DEFAULT_REFRESH_INTERVAL = 2 * 60 * 60
local OP_LOG_MAX_BYTES = 512 * 1024

-- Must match the version in clients/koreader/kpm/package/manifest.json. Sent
-- on every request and recorded against the device, so a support question
-- can be answered with what the device is actually running rather than a
-- guess. See the migration in init(): settings persist, so a new value here
-- reaches an existing install only because init() overwrites it.
local CLIENT_VERSION = "1.0.4"

-- How long the tap menu stays up if nobody chooses. Shorter than the time the
-- device waits before sleeping after a tap, so it never sleeps with the menu
-- on screen.
local PANE_MENU_TIMEOUT = 8

-- Failsafe for the cycle guards themselves. beginCycle sets refresh_in_progress
-- and takes two holds (PluginShare.pause_auto_suspend and Kindle's
-- preventScreenSaver); every normal path releases them in endCycle. But nothing
-- in the cycle is wrapped in pcall, so a single unhandled error -- a corrupt PNG
-- reaching RenderImage, an unexpected nil from a KOReader API -- would leave all
-- three set for good. The consequences are bad in both directions: every later
-- refresh returns early on "already in progress", so InkPane is dead until
-- KOReader restarts, AND both holds stay on, so the Kindle never sleeps and
-- quietly burns the battery.
--
-- Must stay comfortably longer than the worst LEGITIMATE cycle, or it stops
-- being a failsafe and starts killing healthy refreshes. These numbers only
-- work as a set:
--
--   60s Wi-Fi budget + 2s settle + 20s metadata + 20s its one retry
--   + 90s image download  =  about 192s
--
-- Still well above the old 105s worst case, because the image timeout is now 90
-- rather than 20 -- a Scribe page is 2.6 MB and the server has to draw it
-- before a byte moves.
local CYCLE_WATCHDOG_SECONDS = 300

-- The "Pro" mark is a statement about the plan, not about whoever is holding
-- the device, so it is a fixed label rather than something the device has to
-- learn. That matters more than it looks: the alternative was the Kindle
-- tracking subscription state, which goes stale between check-ins -- so someone
-- who had just paid would find the fast options still locked for up to two
-- hours, with nothing to do about it but wait.
--
-- Every option stays selectable. A free display set to 15 minutes simply wakes
-- more often than the screen changes, which costs its owner some battery and
-- nobody anything else. The upside is that upgrading needs no trip to the
-- e-reader at all: the setting is already there, and the server starts
-- honouring it the moment the subscription is active.
local REFRESH_INTERVALS = {
    { label = "15 minutes", seconds = 15 * 60, pro = true },
    { label = "30 minutes", seconds = 30 * 60, pro = true },
    { label = "1 hour", seconds = 60 * 60, pro = true },
    { label = "2 hours", seconds = 2 * 60 * 60 },
    { label = "4 hours", seconds = 4 * 60 * 60 },
    { label = "8 hours", seconds = 8 * 60 * 60 },
    { label = "24 hours", seconds = 24 * 60 * 60 },
}

local InkPane = WidgetContainer:extend {
    name = "inkpane",
    is_doc_only = false,
    settings = nil,
    settings_file = nil,
    image_widget = nil,
    current_image_path = nil,
    rtc_task = nil,
    cycle_watchdog = nil,
    expected_wake_epoch = nil,
    saved_suspend_timeout = nil,
    saved_pause_auto_suspend = nil,
    auto_suspend_hold_owned = false,
    auto_refresh_enabled = false,
    refresh_in_progress = false,
}

InkPane.default_settings = {
    base_url = "https://inkpane.ink",
    device_id = nil,
    device_token = nil,
    pairing_code = nil,
    pairing_expires_at = nil,
    refresh_interval = DEFAULT_REFRESH_INTERVAL,
    fixed_interval_version = 1,
    -- "full", not "ui". A partial refresh is quick and leaves the previous
    -- screen showing through, which is fine for a menu drawn over a book page
    -- and wrong for a photograph replacing a file browser: the first fetch
    -- after opening KOReader ghosted the file list, and InkPane's own
    -- "fetching" message, straight through the Pane.
    --
    -- The cost is the black flash of a full panel refresh. On a screen that
    -- changes every fifteen minutes at most, that is the right trade -- it is
    -- the same flash the device makes on a page turn, and it leaves the image
    -- clean instead of layered over whatever was there before.
    refresh_type = "full",
    user_agent = "inkpane-koreader/" .. CLIENT_VERSION,
    client_version = CLIENT_VERSION,
}

local function trimTrailingSlash(value)
    return (value or ""):gsub("/+$", "")
end

local function cleanupOldImages(currentPath)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or not lfs then return end
    local dir = DataStorage:getDataDir()
    for name in lfs.dir(dir) do
        if name:match("^inkpane%-.*%.png$") then
            local fullPath = dir .. "/" .. name
            if fullPath ~= currentPath then os.remove(fullPath) end
        end
    end
end

local function operationalLogPath()
    return DataStorage:getDataDir() .. "/inkpane-operational.log"
end

-- Logging stays deliberately boring on-device: each event is a plain append.
-- Once per refresh cycle we check the file size and, if it has grown past the
-- cap, truncate it completely. No backup file, rotation, parsing or rewriting.
local function maybeResetOperationalLog()
    local path = operationalLogPath()
    local ok, err = pcall(function()
        local file = io.open(path, "r")
        if not file then return end
        local size = file:seek("end") or 0
        file:close()
        if size < OP_LOG_MAX_BYTES then return end

        local reset = io.open(path, "w")
        if reset then reset:close() end
    end)
    if not ok then
        logger.warn("InkPane: operational log size check failed:", err)
    end
end

local function operationalLog(message)
    local clean = tostring(message or ""):gsub("[\r\n]+", " ")
    local ok, err = pcall(function()
        local file = io.open(operationalLogPath(), "a")
        if not file then return end
        file:write(os.date("!%Y-%m-%dT%H:%M:%SZ"), " ", clean, "\n")
        file:close()
    end)
    if not ok then
        logger.warn("InkPane: operational log write failed:", err)
    end
end

local function jsonRequest(url, method, body, headers)
    local http = require("socket.http")
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local JSON = require("json")

    local sink = {}
    local payload = body and JSON.encode(body) or nil
    local request_headers = headers or {}
    request_headers["Accept"] = "application/json"
    if payload then
        request_headers["Content-Type"] = "application/json"
        request_headers["Content-Length"] = tostring(#payload)
    end

    local request = {
        url = url,
        method = method or "GET",
        headers = request_headers,
        sink = ltn12.sink.table(sink),
        source = payload and ltn12.source.string(payload) or nil,
        protocol = "any",
        options = { "all", "no_sslv2", "no_sslv3" },
        verify = "none",
    }

    local httpx = url:match("^https://") and https or http
    http.TIMEOUT = HTTP_TIMEOUT_SECONDS
    https.TIMEOUT = HTTP_TIMEOUT_SECONDS
    local success, status = httpx.request(request)
    local response_body = table.concat(sink)
    if not success or success ~= 1 then
        return nil, tonumber(status) or 0, "network request failed"
    end

    local decoded = nil
    if response_body ~= "" then
        local ok, parsed = pcall(JSON.decode, response_body)
        if ok then decoded = parsed end
    end
    return decoded, tonumber(status) or 0, response_body
end

function InkPane:oplog(event, detail)
    if detail == nil or detail == "" then
        operationalLog(event)
    else
        operationalLog(event .. " " .. tostring(detail))
    end
end

function InkPane:getRefreshInterval()
    return math.max(MIN_REFRESH_INTERVAL, tonumber(self.settings.refresh_interval) or DEFAULT_REFRESH_INTERVAL)
end

function InkPane:init()
    self.settings_file = LuaSettings:open(DataStorage:getSettingsDir() .. "/inkpane.lua")
    local stored_settings = self.settings_file:readSetting("settings")
    local needs_fixed_interval_migration = stored_settings and stored_settings.fixed_interval_version ~= 1
    self.settings = stored_settings or util.tableDeepCopy(self.default_settings)

    for key, value in pairs(self.default_settings) do
        if self.settings[key] == nil then self.settings[key] = value end
    end

    -- Migrate the old server-driven scheduler once. Old installs could have a
    -- 15/30 minute value written by /api/display; the new model starts clean at
    -- one hour and is changed only by the user in KOReader.
    -- Stored settings win over defaults for every key that already exists, so
    -- an install that has ever run keeps whatever version string it was first
    -- saved with. Overwrite it deliberately, or the number we report is the
    -- version the device was installed at rather than the one it is running.
    if self.settings.client_version ~= CLIENT_VERSION
        or self.settings.user_agent ~= "inkpane-koreader/" .. CLIENT_VERSION
    then
        self.settings.client_version = CLIENT_VERSION
        self.settings.user_agent = "inkpane-koreader/" .. CLIENT_VERSION
        self:saveSettings()
    end

    -- Installs from before 14 September saved refresh_type = "ui", the quick
    -- partial refresh, and saved settings win over the defaults, so they never
    -- picked up the change to "full". That is the ghosting of old screens seen
    -- on the first Kindles. Move them over once.
    if self.settings.refresh_type_version ~= 1 then
        self.settings.refresh_type = "full"
        self.settings.refresh_type_version = 1
        self:saveSettings()
    end

    if needs_fixed_interval_migration then
        self.settings.refresh_interval = DEFAULT_REFRESH_INTERVAL
        self.settings.fixed_interval_version = 1
        self.settings.use_server_refresh_rate = nil
        self:saveSettings()
    end

    -- Dashboard sessions are runtime-only. Restarting KOReader never silently
    -- resurrects a previous InkPane session.
    local was_auto_refresh_enabled = self.settings_file:readSetting("auto_refresh_enabled") or false
    self.auto_refresh_enabled = false
    if was_auto_refresh_enabled then
        self.settings_file:saveSetting("auto_refresh_enabled", false)
        self.settings_file:flush()
    end

    maybeResetOperationalLog()
    -- The device id, not the token: the id is what a support conversation needs
    -- to match a log file to an account, and it grants nothing on its own. Both
    -- Kindles that failed on 2026-09-12 sent logs that named neither, so the
    -- only way to tell whose they were was comparing timestamps by hand.
    self:oplog("plugin_start", "model=" .. self:deviceModel()
        .. " device=" .. (self.settings.device_id or "unpaired")
        .. " version=" .. CLIENT_VERSION
        .. " interval=" .. self:getRefreshInterval())

    -- InkPane never resumes by itself at startup (see above), so no Pane is
    -- showing: if the sleep screen was still held -- KOReader closed or crashed
    -- mid-session -- hand the person's own back now.
    self:releaseSleepScreen()

    -- WakeupMgr runs the callback before removing the fired task. Defer one UI
    -- tick so the old task is gone before we arm the next one. The next task is
    -- queued before network work starts; Kindle programs the hardware alarm
    -- during the normal ReadyToSuspend handoff.
    self.rtc_task = function()
        logger.info("InkPane: RTC wakeup fired")
        self:oplog("rtc_fired")
        self.expected_wake_epoch = nil
        UIManager:scheduleIn(0, function()
            if not self.auto_refresh_enabled then return end
            self:scheduleRtcWake()
            self:refresh(true)
        end)
    end

    self.cycle_watchdog = function()
        if not self.refresh_in_progress then return end
        logger.err("InkPane: cycle still running after", CYCLE_WATCHDOG_SECONDS, "seconds; releasing holds")
        self:oplog("cycle_watchdog_fired")
        -- Hand the user's sleep timeout back too: a cycle that died partway may
        -- have already shortened it to 30 seconds.
        self:restoreAutoSuspendTimeout()
        self:endCycle()
    end

    self.ui.menu:registerToMainMenu(self)
end

function InkPane:onFlushSettings()
    if not self.settings_file then return end
    self.settings_file:saveSetting("settings", self.settings)
    self.settings_file:saveSetting("auto_refresh_enabled", self.auto_refresh_enabled)
    self.settings_file:flush()
end

function InkPane:saveSettings()
    self:onFlushSettings()
end

function InkPane:notify(text, timeout)
    -- One box at a time: an error replaces "Getting your screen…" instead of
    -- stacking on top of it.
    self:closeFetchMessage(true)
    UIManager:show(InfoMessage:new { text = text, timeout = timeout or 4 })
end

-- A refresh the device started by itself has nobody watching it. A message
-- there helps no one, and closing it redraws only its own patch, which can
-- leave a faint box on the Pane. The last Pane stays up, the failure is in the
-- log, and the next refresh tries again. A fetch someone asked for still says.
function InkPane:notifyIfWatched(background, text, timeout)
    if background then return end
    self:notify(text, timeout)
end

-- "Getting your screen…" is kept so it can be closed at the right moment rather
-- than on its own 12-second timer. KOReader keeps message boxes above the Pane,
-- so a Pane that arrived sooner was drawn with the box still on it, and when the
-- box then closed KOReader redrew just that patch with a quick partial refresh
-- -- which on a Kindle leaves the box's outline on plain parts of the Pane
-- (reported on a Paperwhite Signature, 16 September 2026).
function InkPane:showFetchMessage()
    self:closeFetchMessage(true)
    local message
    message = InfoMessage:new {
        text = _("Getting your screen…\n\nPlease don't touch the screen until it appears."),
        timeout = 12,
        dismiss_callback = function()
            if self.fetch_message == message then self.fetch_message = nil end
        end,
    }
    self.fetch_message = message
    UIManager:show(message)
end

-- repaint = false only when the Pane is about to be drawn over the whole
-- screen, whose full refresh repaints that patch cleanly anyway. Anywhere else
-- the patch must be redrawn, or the box would stay visible after closing.
function InkPane:closeFetchMessage(repaint)
    local message = self.fetch_message
    if not message then return end
    self.fetch_message = nil
    if not repaint then message.no_refresh_on_close = true end
    UIManager:close(message)
end

-- While a Pane is on the display, KOReader must leave the screen as it is when
-- the Kindle sleeps, or its own sleep screen (a book cover, "Sleeping") is drawn
-- over the Pane until the next wake. This used to be forced once, at startup,
-- and left that way for good, which replaced the person's own sleep screen even
-- while they were just reading (reported 16 September 2026: "it completely
-- blocks the book cover screensaver").
--
-- So it's held only while a Pane is shown, with the person's own settings saved
-- first and put back when InkPane stops. KOReader reads these settings each
-- time the Kindle goes to sleep, so their value at that moment is all that
-- matters. sleep_screen_held is saved with our settings and survives a crash,
-- so our own "leave as-is" is never saved as if it were their choice.
function InkPane:holdSleepScreen()
    if not Device:isKindle() or not G_reader_settings then return end
    if not self.settings.sleep_screen_held then
        self.settings.saved_sleep_screen = {
            screensaver_type = G_reader_settings:readSetting("screensaver_type"),
            screensaver_show_message = G_reader_settings:readSetting("screensaver_show_message"),
        }
        self.settings.sleep_screen_held = true
        self:saveSettings()
        self:oplog("sleep_screen_held", "saved=" .. tostring(self.settings.saved_sleep_screen.screensaver_type))
    end
    G_reader_settings:saveSetting("screensaver_type", "disable")
    G_reader_settings:makeFalse("screensaver_show_message")
    G_reader_settings:flush()
end

-- Only when InkPane has actually stopped (or KOReader is starting or closing),
-- never while one Pane image is being swapped for the next: a sleep in that
-- instant would draw the person's sleep screen over the Pane.
function InkPane:releaseSleepScreen()
    if not self.settings or not self.settings.sleep_screen_held then return end
    local saved = self.settings.saved_sleep_screen or {}
    if G_reader_settings then
        -- A value that was never set gets KOReader's own first-run default.
        G_reader_settings:saveSetting("screensaver_type", saved.screensaver_type or "disable")
        if saved.screensaver_show_message == nil then
            G_reader_settings:makeTrue("screensaver_show_message")
        else
            G_reader_settings:saveSetting("screensaver_show_message", saved.screensaver_show_message)
        end
        G_reader_settings:flush()
    end
    self.settings.sleep_screen_held = nil
    self.settings.saved_sleep_screen = nil
    self:saveSettings()
    self:oplog("sleep_screen_released", "restored=" .. tostring(saved.screensaver_type))
end

function InkPane:stopInkPane(show_message)
    local was_enabled = self.auto_refresh_enabled
    self.auto_refresh_enabled = false
    self.expected_wake_epoch = nil
    self:unscheduleRtcWake()
    self:restoreAutoSuspendTimeout()
    self:saveSettings()
    self:oplog("inkpane_stopped", "was_enabled=" .. tostring(was_enabled))
    if was_enabled then self:recordStop() end
    self:releaseSleepScreen()

    if show_message and was_enabled then
        self:notify(_("InkPane stopped. Use \"Fetch screen now\" to start again."), 4)
    end
end

function InkPane:onReaderReady()
    self:oplog("reader_opened")
    self:stopInkPane(false)
end

function InkPane:onResume()
    if not self.auto_refresh_enabled or self.refresh_in_progress then return end

    local expected = self.expected_wake_epoch

    -- Always hand the user's own idle timeout back first. This resume may be a
    -- person picking the device up and there is no way to tell yet, so assume
    -- it is: nothing should die in someone's hand after thirty seconds. It is
    -- harmless if the resume turns out to be our own wake, because every cycle
    -- ends by applying the short timeout again.
    self:restoreAutoSuspendTimeout()

    -- Observed 2026-09-08: an alarm armed at 19:28:17 for 900 seconds woke the
    -- device at exactly 19:43:17 (epoch 1788892997), and no rtc_fired was ever
    -- logged. On Kindle the RTC task is delivered from checkUnexpectedWakeup,
    -- scheduled 15 seconds after the resume, and it silently declines once
    -- Amazon's power state has moved to "active" -- which one stray touch in
    -- those 15 seconds causes. So nothing ran, nothing re-armed, and with the
    -- long timeout just restored the Kindle sat awake doing nothing for six
    -- minutes: a skipped update and fifteen minutes of battery.
    --
    -- The watch is armed for when the alarm is DUE, not for how close this
    -- resume happened to land. An earlier version only armed it within 60
    -- seconds of the deadline, which missed the failure that actually killed an
    -- overnight run (2026-09-08, verified in crash.log):
    --
    --     21:17:43  next RTC wake in 900 seconds        (due 21:32:43)
    --     21:17:57  idle-sleep timeout set to 30 seconds
    --     21:18:29  Restoring user input handling       (suspend bounced back)
    --     21:18:29  restored normal idle-sleep timeout 900 seconds
    --     21:33:30  Inhibiting user input               (slept 15 min later)
    --
    -- That resume was fourteen minutes early, so no watch was armed. The device
    -- then stayed awake past 21:32:43 on the restored timeout -- and an RTC task
    -- can only ever be delivered on a resume, so the alarm was never executed.
    -- At 21:33:30 readyToSuspend found the epoch in the past, discarded the
    -- alarm and programmed no rtcWakeup: dead for ten hours.
    --
    -- Arming for the deadline instead covers any early resume. Safe on every
    -- other path because the closure no-ops when the wake arrived normally
    -- (expected_wake_epoch has changed) or a cycle is already running, so extra
    -- watches from repeated resumes cost nothing.
    if expected then
        local delay = math.max(0, expected - os.time()) + WAKE_DELIVERY_GRACE
        self:oplog("wake_delivery_watch", "expected=" .. expected .. " in=" .. delay)
        UIManager:scheduleIn(delay, function()
            if not self.auto_refresh_enabled or self.refresh_in_progress then return end
            -- rtc_task clears expected_wake_epoch and scheduleRtcWake replaces
            -- it, so an unchanged value means the wake never reached us.
            if self.expected_wake_epoch ~= expected then return end
            logger.warn("InkPane: scheduled wake at", expected, "was never delivered; running it here")
            self:oplog("wake_not_delivered_recovery", "expected=" .. expected)
            self:recordFailure("late_wake")
            self.expected_wake_epoch = nil
            self:scheduleRtcWake()
            self:refresh(true)
        end)
        return
    end

    if not expected and self:canUseRtcWake() then
        logger.warn("InkPane: resumed with no wake scheduled; re-arming")
        self:oplog("resume_rearm")
        self:scheduleRtcWake()
    end
end

function InkPane:showPairingCode()
    if not self.settings.pairing_code then
        self:notify(_("This device is not registered yet."))
        return
    end
    self:notify(
        _("Pair this e-reader") .. "\n\n" ..
        _("Code: ") .. self.settings.pairing_code .. "\n\n" ..
        _("Open InkPane on your phone/computer and enter the code."),
        20
    )
end

function InkPane:deviceModel()
    if Device.model then return tostring(Device.model) end
    return "KOReader e-reader"
end

function InkPane:registerDevice(complete_callback)
    local url = trimTrailingSlash(self.settings.base_url) .. "/api/device/register"
    local payload = {
        name = "My e-reader",
        model = self:deviceModel(),
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }

    logger.info("InkPane: registering device at", url)
    self:oplog("registration_start")
    local response, status = jsonRequest(url, "POST", payload, {
        ["User-Agent"] = self.settings.user_agent,
    })

    if status ~= 200 or not response or not response.device_token or not response.pairing_code then
        logger.err("InkPane: registration failed, HTTP", status)
        self:oplog("registration_failed", "http=" .. tostring(status))
        self:notify(_("InkPane registration failed. Check Wi-Fi and Base URL."), 8)
        if complete_callback then complete_callback(false) end
        return
    end

    self.settings.device_id = response.device_id
    self.settings.device_token = response.device_token
    self.settings.pairing_code = response.pairing_code
    self.settings.pairing_expires_at = response.pairing_expires_at
    self:saveSettings()

    logger.info("InkPane: device registered")
    self:oplog("registration_success")
    self:showPairingCode()
    if complete_callback then complete_callback(true, true) end
end

function InkPane:ensureRegistered(complete_callback)
    if self.settings.device_token and self.settings.device_token ~= "" then
        complete_callback(true, false)
        return
    end
    self:registerDevice(complete_callback)
end

function InkPane:fetchMetadata()
    if not self.settings.device_token or self.settings.device_token == "" then
        return nil, 401
    end

    local url = trimTrailingSlash(self.settings.base_url) .. "/api/display"
    return jsonRequest(url, "GET", nil, self:healthHeaders({
        ["access-token"] = self.settings.device_token,
        ["png-width"] = tostring(Screen:getWidth()),
        ["png-height"] = tostring(Screen:getHeight()),
        ["User-Agent"] = self.settings.user_agent,
        -- The refresh interval is chosen here, on the device, so the server has
        -- no way to know when to expect this Kindle back -- which is why it
        -- cannot currently tell a dead display from someone reading a book.
        -- Telling it costs one header on a request that already happens.
        ["inkpane-interval"] = tostring(self:getRefreshInterval()),
        ["inkpane-version"] = CLIENT_VERSION,
        -- Whether this device has a hardware wake timer, as the device itself
        -- reports it. KOReader has no per-model table to copy -- the capability
        -- is detected at runtime -- so the honest way to know which e-readers
        -- support a low-power scheduled refresh is to ask the ones people
        -- actually own, rather than publish a list we guessed at.
        --
        -- Note this says "has an RTC", not "scheduled refresh works". The
        -- Scribe had one and for a while still could not reach Wi-Fi after a
        -- timed wake, so the two are different claims.
        ["inkpane-rtc"] = self:canUseRtcWake() and "1" or "0",
        ["inkpane-model"] = self:deviceModel(),
        -- Battery level, so drain can be measured rather than guessed. The
        -- device already knows it; this is one more header on a request that
        -- is made anyway, so it costs no extra wake and no extra connection.
        ["inkpane-battery"] = self:batteryLevel(),
    }))
end

-- What went wrong since the last good refresh, kept in the settings file and
-- sent with the next check-in so failures can be seen without asking anyone
-- for a log. A counter and a short note; nothing is sent on its own, so this
-- adds no wake and no connection. Every step is wrapped: recording a failure
-- must never be the thing that breaks a refresh.
-- Seconds since 1970, which is UTC whatever time zone the device is set to.
local function healthStamp()
    return tostring(os.time())
end

function InkPane:recordFailure(kind)
    pcall(function()
        local label = tostring(kind or "unknown"):gsub("[^%w_]", ""):sub(1, 24)
        if label == "" then label = "unknown" end
        self.settings.health_failures = math.min((tonumber(self.settings.health_failures) or 0) + 1, 9999)
        self.settings.health_last_failure = label .. " " .. healthStamp()
        self:saveSettings()
    end)
end

function InkPane:recordStop()
    pcall(function()
        self.settings.health_stopped_at = healthStamp()
        self:saveSettings()
    end)
end

function InkPane:healthHeaders(headers)
    pcall(function()
        headers["inkpane-failures"] = tostring(math.floor(tonumber(self.settings.health_failures) or 0))
        if type(self.settings.health_last_failure) == "string" then
            headers["inkpane-last-failure"] = self.settings.health_last_failure:sub(1, 48)
        end
        if type(self.settings.health_stopped_at) == "string" then
            headers["inkpane-stopped"] = self.settings.health_stopped_at:sub(1, 20)
        end
    end)
    return headers
end

-- Called once the server has answered a check-in properly: it now has the
-- report, so start counting again. The last failure is kept on the server.
function InkPane:clearHealthReport()
    pcall(function()
        if (tonumber(self.settings.health_failures) or 0) == 0
            and self.settings.health_last_failure == nil
            and self.settings.health_stopped_at == nil
        then
            return
        end
        self.settings.health_failures = 0
        self.settings.health_last_failure = nil
        self.settings.health_stopped_at = nil
        self:saveSettings()
    end)
end

function InkPane:batteryLevel()
    local level = nil
    pcall(function() level = Device:getPowerDevice():getCapacity() end)
    level = tonumber(level)
    if not level or level < 0 or level > 100 then return nil end
    return tostring(math.floor(level + 0.5))
end

-- Give Wi-Fi back at the end of a cycle. If InkPane switched it on itself, it
-- switches it off again. Otherwise this is KOReader's usual afterWifiAction,
-- which does nothing unless KOReader's own prompt flow turned Wi-Fi on.
function InkPane:releaseWifi()
    if self.wifi_enabled_by_inkpane then
        self.wifi_enabled_by_inkpane = false
        pcall(function() NetworkMgr:turnOffWifi() end)
        self:oplog("wifi_off", "by=inkpane")
        return
    end
    NetworkMgr:afterWifiAction()
end

function InkPane:downloadImage(image_url, filepath)
    local http = require("socket.http")
    local https = require("ssl.https")
    local ltn12 = require("ltn12")

    local file = io.open(filepath, "wb")
    if not file then return false end

    local request = {
        url = image_url,
        method = "GET",
        headers = {
            ["User-Agent"] = self.settings.user_agent,
            ["access-token"] = self.settings.device_token or "",
        },
        sink = ltn12.sink.file(file),
        protocol = "any",
        options = { "all", "no_sslv2", "no_sslv3" },
        verify = "none",
    }

    local httpx = image_url:match("^https://") and https or http
    -- The image limit, not the metadata one. These are module-level globals in
    -- luasocket, so whichever ran last wins -- which is why they are set on
    -- every request rather than once at load.
    http.TIMEOUT = IMAGE_TIMEOUT_SECONDS
    https.TIMEOUT = IMAGE_TIMEOUT_SECONDS
    local started_at = os.time()
    local success, status = httpx.request(request)
    local took = math.max(0, os.time() - started_at)
    if not success or success ~= 1 or tonumber(status) ~= 200 then
        self:oplog("image_download_detail", "took=" .. took .. "s http=" .. tostring(status))
        os.remove(filepath)
        return false
    end
    -- Recorded on success too: the only way to know whether the new limit is
    -- generous or still marginal is to see what a real download costs.
    self:oplog("image_download_detail", "took=" .. took .. "s ok")
    return true
end

function InkPane:displayImage(image_path)
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local image_bb = RenderImage:renderImageFile(image_path, true, screen_w, screen_h)
    if not image_bb then return false end

    -- A Scribe on 2026-09-13 painted the Pane down the left of the screen with
    -- the file manager still showing down the right, text cut mid-word at the
    -- boundary. A Kindle Basic rendered the same fetch correctly. That is a
    -- width mismatch somewhere between the PNG, the decoded bitmap and the
    -- panel, and no photograph can say which. These are the three numbers that
    -- can, so log them on every render rather than guess again.
    local file_bytes, bb_w, bb_h = 0, 0, 0
    pcall(function()
        local handle = io.open(image_path, "rb")
        if handle then
            file_bytes = handle:seek("end") or 0
            handle:close()
        end
    end)
    pcall(function()
        bb_w, bb_h = image_bb:getWidth(), image_bb:getHeight()
    end)
    self:oplog("image_geometry", "bytes=" .. file_bytes
        .. " bb=" .. bb_w .. "x" .. bb_h
        .. " screen=" .. screen_w .. "x" .. screen_h)

    if self.image_widget then
        UIManager:close(self.image_widget)
        self.image_widget = nil
    end

    local image = ImageWidget:new {
        image = image_bb,
        image_disposable = true,
        width = screen_w,
        height = screen_h,
        -- No alpha. The Pane is an opaque full-screen photograph, and blending
        -- it means any pixel the decoder did not produce shows whatever was on
        -- screen before -- which on a Kindle is the file manager we are
        -- supposed to be covering. Copy the pixels instead of mixing them.
    }

    -- covers_fullscreen tells UIManager the stack below this widget does not
    -- need painting. Without it the file manager is drawn first and we rely on
    -- our own image landing on every pixel to hide it.
    self.image_widget = InputContainer:new {
        dimen = Geom:new { x = 0, y = 0, w = screen_w, h = screen_h },
        covers_fullscreen = true,
        image,
    }

    -- A tap used to stop InkPane straight away, and people tap a still screen
    -- to see whether it is alive. Ask instead. If the menu can't be shown for
    -- any reason, fall back to stopping, so nobody is ever stuck on the Pane.
    self.image_widget.onTapClose = function()
        local ok, err = pcall(function() self:showPaneMenu() end)
        if not ok then
            logger.warn("InkPane: tap menu failed; stopping instead", err)
            self:stopFromPane()
        end
        return true
    end
    self.image_widget.onAnyKeyPressed = self.image_widget.onTapClose

    if Device:isTouchDevice() then
        self.image_widget.ges_events = {
            TapClose = {
                GestureRange:new {
                    ges = "tap",
                    range = Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() },
                },
            },
        }
    end
    if Device:hasKeys() then
        self.image_widget.key_events = { AnyKeyPressed = { { Input.group.Any } } }
    end

    -- Close "Getting your screen…" before the Pane goes up, without its own
    -- patch redraw: the full refresh below repaints the whole screen once.
    self:closeFetchMessage(false)
    UIManager:show(self.image_widget)
    -- The region is passed explicitly. Left to infer it, UIManager uses the
    -- widget's own dimen, so a widget that measures itself short refreshes
    -- short and leaves the rest of the panel holding stale pixels.
    UIManager:setDirty(self.image_widget, self.settings.refresh_type or "ui",
        Geom:new { x = 0, y = 0, w = screen_w, h = screen_h })
    self.current_image_path = image_path
    self:holdSleepScreen()
    return true
end

function InkPane:stopFromPane()
    self:stopInkPane(true)
    if self.image_widget then
        UIManager:close(self.image_widget)
        self.image_widget = nil
    end
end

-- Keep showing / Refresh now / Stop InkPane, over the Pane.
function InkPane:showPaneMenu()
    if self.pane_menu then return end
    local ButtonDialog = require("ui/widget/buttondialog")

    local menu
    local timeout_task
    local function dismiss(after)
        if not menu then return end
        local closing = menu
        menu = nil
        self.pane_menu = nil
        if timeout_task then UIManager:unschedule(timeout_task) end
        UIManager:close(closing)
        -- The dialog repaints only its own patch; redraw the whole Pane with a
        -- full refresh so no outline of it is left behind.
        if self.image_widget then
            UIManager:setDirty(self.image_widget, "full",
                Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() })
        end
        if after then UIManager:nextTick(after) end
    end

    menu = ButtonDialog:new {
        title = _("InkPane"),
        buttons = {
            { { text = _("Keep showing"), callback = function() dismiss() end } },
            { { text = _("Refresh now"), callback = function()
                dismiss(function() self:refresh(false) end)
            end } },
            { { text = _("Stop InkPane"), callback = function()
                dismiss(function() self:stopFromPane() end)
            end } },
        },
        -- Tapping outside the menu, or Back, means keep showing.
        tap_close_callback = function()
            menu = nil
            self.pane_menu = nil
            if timeout_task then UIManager:unschedule(timeout_task) end
            if self.image_widget then
                UIManager:setDirty(self.image_widget, "full",
                    Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() })
            end
        end,
    }
    timeout_task = function() dismiss() end
    self.pane_menu = menu
    self:oplog("pane_menu_shown")
    UIManager:show(menu)
    UIManager:scheduleIn(PANE_MENU_TIMEOUT, timeout_task)
end

function InkPane:canUseRtcWake()
    return Device.wakeup_mgr ~= nil
end

function InkPane:findAutoSuspend()
    local ok, plugin = pcall(function() return self.ui and self.ui.autosuspend end)
    if ok and plugin and plugin.auto_suspend_timeout_seconds then return plugin end
    return nil
end

function InkPane:applyAutoSuspendTimeout(seconds)
    local autosuspend = self:findAutoSuspend()
    if not autosuspend then
        logger.info("InkPane: AutoSuspend plugin not reachable; leaving idle-sleep timeout alone")
        return false
    end

    if not self.saved_suspend_timeout then
        self.saved_suspend_timeout = autosuspend.auto_suspend_timeout_seconds
        logger.info("InkPane: saved normal idle-sleep timeout", self.saved_suspend_timeout, "seconds")
    end

    local applied = pcall(function()
        local time = require("ui/time")
        local elapsed = time.to_number(UIManager:getElapsedTimeSinceBoot() - autosuspend.last_action_time)
        if type(elapsed) ~= "number" or elapsed < 0 then error("unusable last_action_time") end
        autosuspend.auto_suspend_timeout_seconds = seconds + elapsed
    end)
    if not applied then
        logger.warn("InkPane: could not read AutoSuspend's last action time; resetting it instead")
        autosuspend.auto_suspend_timeout_seconds = seconds
        pcall(function() autosuspend.last_action_time = UIManager:getElapsedTimeSinceBoot() end)
    end

    pcall(function()
        autosuspend:_unschedule()
        autosuspend:_start()
    end)
    logger.info("InkPane: idle-sleep timeout set to", seconds, "seconds (runtime only, not saved to settings)")
    return true
end

function InkPane:restoreAutoSuspendTimeout()
    if not self.saved_suspend_timeout then return end
    local autosuspend = self:findAutoSuspend()
    if autosuspend then
        autosuspend.auto_suspend_timeout_seconds = self.saved_suspend_timeout
        pcall(function()
            autosuspend:_unschedule()
            autosuspend:_start()
        end)
        logger.info("InkPane: restored normal idle-sleep timeout", self.saved_suspend_timeout, "seconds")
    end
    self.saved_suspend_timeout = nil
end

-- What Amazon's own daemons think, rather than what KOReader thinks.
--
-- A Kindle Basic rejoins its network within six seconds of a scheduled wake,
-- before InkPane has even asked it to; a Scribe, given the identical calls,
-- reports its interface up and never obtains an address. Our logs can say that
-- much and no more, because everything above this line is KOReader's view.
--
-- cmState is the connection manager's own state -- the same property KOReader
-- reads in kindleGetScanList. Unreadable means wifid is not running at all,
-- which would point at the device's power state after an RTC wake; a value that
-- sits at pending means association is being attempted and failing; ready with
-- no address means DHCP. Three different bugs that look identical from here.
local function kindleNetworkState()
    local parts = {}
    pcall(function()
        local handle = Device.powerd and Device.powerd.lipc_handle
        if not handle then
            parts[#parts + 1] = "lipc=none"
            return
        end
        for _, probe in ipairs({
            { "com.lab126.wifid", "cmState" },
            { "com.lab126.wifid", "currentEssid" },
            { "com.lab126.powerd", "state" },
        }) do
            local ok, value = pcall(function()
                return handle:get_string_property(probe[1], probe[2])
            end)
            local name = probe[2]
            parts[#parts + 1] = name .. "=" .. (ok and tostring(value) or "unreadable")
        end
    end)
    if #parts == 0 then return "probe_failed" end
    return table.concat(parts, " ")
end

-- Waking the device before touching the radio.
--
-- Measured on a Kindle Basic, 2026-09-13. A manual fetch reads state=active,
-- cmState moves NA -> PENDING, and Wi-Fi connects in seconds. The two failed
-- scheduled wakes at 12:34 and 13:02 read state=screenSaver and cmState stayed
-- at NA for the whole sixty seconds, through two turnOnWifi calls each.
--
-- That is NOT a rule that screenSaver blocks association. The same log
-- disproves it: the 13:33 wake also started at screenSaver with cmState=NA and
-- connected in eleven seconds, and seventeen consecutive scheduled wakes
-- between 06:30 and 10:32 connected in six to fifteen seconds. Association from
-- screenSaver works most of the time and sometimes stalls -- a race, not a wall.
--
-- The other half of the same log says what the stall actually is. Both failures
-- left the radio on (wifi=true), and both times it associated afterwards with
-- nobody touching the device: the 13:18 recovery cycle, which no human was
-- present for, opened with wifi_already_connected. The association was never
-- failing. It was finishing after we had stopped waiting.
--
-- So this press is a probe for the fast path, not a proven fix. If a device
-- that is properly awake associates in seconds every time, we take it; if it
-- does not, the per-tick net_state lines below time the slow path instead.
--
-- KOReader's own source notes that "there's no distinction between real button
-- presses and lipc-set-prop -i com.lab126.powerd powerButton 1" -- the software
-- equivalent of the thumb that made this work by hand.
--
-- Three constraints, all of them about not breaking sleep:
--   * Only from screenSaver, tested exactly. readyToSuspend is a device on its
--     way down and active is a device already up; a toggle sent to either is a
--     way to suspend the Kindle we were trying to wake.
--   * Once per cycle. The call site below is the only one.
--   * Confirm the transition before enabling the radio, because pressing and
--     immediately reading back says nothing about a transition that is not
--     instant.
local function kindleWakeToActive()
    if not Device:isKindle() then return "not_kindle" end

    local before, after, sent, waited = "unknown", "unknown", false, 0

    pcall(function()
        local handle = Device.powerd and Device.powerd.lipc_handle
        if not handle then
            before = "lipc=none"
            return
        end

        local function readState()
            local ok, value = pcall(function()
                return handle:get_string_property("com.lab126.powerd", "state")
            end)
            return ok and tostring(value) or "unreadable"
        end

        before = readState()
        after = before
        if before ~= "screenSaver" then return end

        handle:set_int_property("com.lab126.powerd", "powerButton", 1)
        sent = true

        local ffiutil
        pcall(function() ffiutil = require("ffi/util") end)

        for _ = 1, WAKE_CONFIRM_TICKS do
            if ffiutil and ffiutil.usleep then
                ffiutil.usleep(WAKE_CONFIRM_TICK_MS * 1000)
                waited = waited + WAKE_CONFIRM_TICK_MS
            end
            after = readState()
            if after == "active" then break end
        end
    end)

    return "before=" .. before .. " pressed=" .. tostring(sent)
        .. " after=" .. after .. " waited=" .. waited .. "ms"
end

local function holdKindleAwake(on)
    if not Device:isKindle() then return end
    local ok, err = pcall(function()
        local handle = Device.powerd and Device.powerd.lipc_handle
        if not handle then return end
        handle:set_int_property("com.lab126.powerd", "preventScreenSaver", on and 1 or 0)
        logger.info("InkPane: preventScreenSaver", on and 1 or 0)
    end)
    if not ok then logger.warn("InkPane: preventScreenSaver failed:", err) end
end

function InkPane:beginCycle()
    self.refresh_in_progress = true
    self.saved_pause_auto_suspend = PluginShare.pause_auto_suspend
    self.auto_suspend_hold_owned = true
    PluginShare.pause_auto_suspend = true
    holdKindleAwake(true)
    if self.cycle_watchdog then
        UIManager:unschedule(self.cycle_watchdog)
        UIManager:scheduleIn(CYCLE_WATCHDOG_SECONDS, self.cycle_watchdog)
    end
end

function InkPane:releaseAutoSuspendHold()
    if not self.auto_suspend_hold_owned then return end
    PluginShare.pause_auto_suspend = self.saved_pause_auto_suspend
    self.saved_pause_auto_suspend = nil
    self.auto_suspend_hold_owned = false
end

function InkPane:endCycle()
    if not self.refresh_in_progress then return end
    if self.cycle_watchdog then UIManager:unschedule(self.cycle_watchdog) end
    self:releaseAutoSuspendHold()
    self.refresh_in_progress = false
    holdKindleAwake(false)
end

function InkPane:unscheduleRtcWake()
    if Device.wakeup_mgr and self.rtc_task then
        Device.wakeup_mgr:removeTasks(nil, self.rtc_task)
    end
end

function InkPane:scheduleRtcWake()
    if not self.auto_refresh_enabled or not self:canUseRtcWake() then return false end
    local interval = self:getRefreshInterval()
    self:unscheduleRtcWake()
    Device.wakeup_mgr:addTask(interval, self.rtc_task)
    self.expected_wake_epoch = os.time() + interval
    logger.info("InkPane: next RTC wake in", interval, "seconds")
    self:oplog("rtc_queued", "in=" .. interval .. " expected=" .. self.expected_wake_epoch)
    return true
end

function InkPane:finishBackgroundCycle(success)
    if not self.auto_refresh_enabled then
        self:endCycle()
        self:releaseWifi()
        return
    end

    -- The next RTC task was already queued at the start of this wake, before
    -- network work. Keep the cadence fixed; Kindle writes the hardware alarm
    -- when KOReader reaches its normal ReadyToSuspend handoff.
    self:releaseAutoSuspendHold()
    self:applyAutoSuspendTimeout(DISPLAY_SUSPEND_TIMEOUT)
    self:oplog("suspend_prepare", "timeout=" .. DISPLAY_SUSPEND_TIMEOUT)

    if not success and self.current_image_path then
        self:displayImage(self.current_image_path)
    end

    logger.info("InkPane: background refresh complete; success:", success)
    self:oplog("cycle_complete", "background=true success=" .. tostring(success))

    local force_off = false
    pcall(function()
        force_off = G_reader_settings ~= nil
            and G_reader_settings:readSetting("wifi_disable_action") == "turn_off"
    end)
    if force_off then
        NetworkMgr:turnOffWifi(function()
            NetworkMgr:afterWifiAction()
        end)
    else
        pcall(function() NetworkMgr:clearBeforeActionFlag() end)
    end

    self:endCycle()
end

function InkPane:finishInteractiveCycle()
    if self.auto_refresh_enabled then
        self:scheduleRtcWake()
        self:releaseAutoSuspendHold()
        self:applyAutoSuspendTimeout(DISPLAY_SUSPEND_TIMEOUT)
        self:oplog("suspend_prepare", "timeout=" .. DISPLAY_SUSPEND_TIMEOUT)
    end
    self:releaseWifi()
    self:oplog("cycle_complete", "background=false active=" .. tostring(self.auto_refresh_enabled))
    self:endCycle()
end

function InkPane:performFetch(background, is_retry)
    if background and not self.auto_refresh_enabled then
        logger.info("InkPane: background refresh cancelled because InkPane was stopped")
        self:oplog("fetch_cancelled", "reason=stopped")
        self:endCycle()
        self:releaseWifi()
        return
    end

    self:oplog("api_display_start")
    local response, status = self:fetchMetadata()
    self:oplog("api_display_result", "http=" .. tostring(status))

    -- Status 0 is jsonRequest's "the request never completed" -- no HTTP
    -- response at all, as distinct from a server that answered with 401 or 500.
    -- On this device it appears when NetworkMgr:isConnected() has gone true but
    -- the stack is not usable yet: association is up while DNS or routing lags
    -- a second or two behind, and the two-second settle after connecting is
    -- sometimes not enough. Seen four times, most recently a 2026-09-09 08:30
    -- cycle where the Kindle was observed connecting to Wi-Fi and the server
    -- logged no /api/display request at all.
    --
    -- Retry exactly once, and only for 0. A 401 must still reach
    -- handleRevokedToken immediately, and a 500 is the server answering --
    -- neither is fixed by waiting. Successful cycles are unaffected, so the
    -- extra five seconds is only ever paid when the network was demonstrably
    -- not ready.
    if status == 0 and not is_retry then
        logger.warn("InkPane: metadata request did not complete; retrying once in 5s")
        self:oplog("api_display_retry", "after=5s")
        UIManager:scheduleIn(5, function()
            -- The cycle can have been ended underneath us in those five seconds
            -- (user stopped InkPane, or the watchdog fired).
            if not self.refresh_in_progress then return end
            self:performFetch(background, true)
        end)
        return
    end

    if status ~= 200 or not response or not response.image_url then
        logger.err("InkPane: metadata fetch failed, HTTP", status)
        -- A bare 401 is not evidence of anything. It can come from a proxy, an
        -- edge error, a half-deployed server, or a future bug. The server says
        -- DEVICE_REVOKED when, and only when, it completed the lookup and this
        -- token matched no device -- so that code, not the status, is what we
        -- act on. Anything else is treated as a failure to reach InkPane: the
        -- last screen stays, the schedule stays, and we try again next time.
        if status == 401 and response and response.code == "DEVICE_REVOKED" then
            self:handleRevokedToken(not background)
        elseif status == 401 then
            self:oplog("unexpected_401", "kept identity")
            self:recordFailure("http401")
            self:notifyIfWatched(background, _("Could not fetch InkPane dashboard."), 6)
        else
            self:oplog("fetch_failed", "http=" .. tostring(status))
            self:recordFailure("http" .. tostring(status))
            self:notifyIfWatched(background, _("Could not fetch InkPane dashboard."), 6)
        end
        if background then self:finishBackgroundCycle(false) else self:finishInteractiveCycle() end
        return
    end

    self:clearHealthReport()

    -- Server timing fields are intentionally ignored. The Kindle owns one
    -- local fixed interval selected by the user.

    local filename = response.filename or "inkpane-screen.png"
    filename = filename:gsub("[^%w%._%-]", "_")
    if not filename:match("%.png$") then filename = filename .. ".png" end
    local path = DataStorage:getDataDir() .. "/" .. filename

    self:oplog("image_download_start")
    if not self:downloadImage(response.image_url, path) then
        self:oplog("image_download_failed")
        self:recordFailure("download")
        self:notifyIfWatched(background, _("Could not download InkPane image."), 6)
        if background then self:finishBackgroundCycle(false) else self:finishInteractiveCycle() end
        return
    end
    self:oplog("image_download_success")

    if background and not self.auto_refresh_enabled then
        logger.info("InkPane: background image arrived after InkPane was stopped; discarding it")
        self:oplog("image_discarded", "reason=stopped")
        os.remove(path)
        self:endCycle()
        self:releaseWifi()
        return
    end

    -- Keep the previous known-good file until the new PNG has actually rendered.
    -- displayImage renders before closing the old widget, so a corrupt new image
    -- cannot blank the screen or destroy our fallback.
    if not self:displayImage(path) then
        logger.err("InkPane: downloaded image could not be rendered")
        self:oplog("image_render_failed")
        self:recordFailure("render")
        os.remove(path)
        if background then self:finishBackgroundCycle(false) else self:finishInteractiveCycle() end
        return
    end

    self:oplog("image_render_success")
    cleanupOldImages(path)

    if not background and not self.auto_refresh_enabled and self:canUseRtcWake() then
        self.auto_refresh_enabled = true
        self:saveSettings()
        self:oplog("inkpane_started")
    end

    if background then self:finishBackgroundCycle(true) else self:finishInteractiveCycle() end
end

function InkPane:refresh(background)
    if self.refresh_in_progress then
        self:oplog("refresh_skipped", "reason=already_in_progress")
        return
    end

    maybeResetOperationalLog()
    self:beginCycle()
    self.wifi_enabled_by_inkpane = false
    self:oplog("cycle_start", "background=" .. tostring(background))

    -- A manual fetch used to say nothing unless Wi-Fi happened to be off, so on
    -- a Scribe -- where connecting, drawing and downloading a 2.6 MB screen can
    -- take well over half a minute -- the device looked dead after the menu tap.
    -- The natural response is to tap the screen to check it is alive, and a tap
    -- on a shown Pane calls stopInkPane: on a background refresh that discards
    -- the image that was already on its way.
    --
    -- Say what is happening and how long it may take. Better than asking people
    -- not to touch their own device, which they will do anyway when nothing
    -- appears to be happening.
    if not background then
        self:showFetchMessage()
    end

    if background and not self.auto_refresh_enabled then
        logger.info("InkPane: alarm fired while switched off; ignoring")
        self:oplog("refresh_skipped", "reason=switched_off")
        self:endCycle()
        return
    end

    local connect_settled = false
    local poll_task = nil
    local started_at = os.time()

    local function onConnectSettled(fn)
        if connect_settled then return end
        connect_settled = true
        if poll_task then UIManager:unschedule(poll_task) end
        fn()
    end

    local function onConnected()
        onConnectSettled(function()
            self:oplog("wifi_connected", "after=" .. math.max(0, os.time() - started_at) .. "s")
            UIManager:scheduleIn(2, function()
                self:ensureRegistered(function(ok, just_registered)
                    if not ok then
                        if background then
                            self:finishBackgroundCycle(false)
                        else
                            self:releaseWifi()
                            self:endCycle()
                        end
                        return
                    end
                    if just_registered then
                        self:endCycle()
                        if background then
                            self.auto_refresh_enabled = false
                            self:saveSettings()
                        end
                        self:releaseWifi()
                        return
                    end
                    self:performFetch(background)
                end)
            end)
        end)
    end

    -- Neither a scheduled wake nor a deliberate "Fetch screen now" should enter
    -- KOReader's interactive scan path. Compare the two Kindle backends:
    --
    --     function NetworkMgr:turnOnWifi(complete_callback, interactive)
    --         kindleEnableWifi(1)
    --         return self:reconnectOrShowNetworkMenu(complete_callback, interactive)
    --     end
    --     function NetworkMgr:restoreWifiAsync()
    --         kindleEnableWifi(1)
    --     end
    --
    -- Both write the same two properties (com.lab126.cmd wirelessEnable 1 and
    -- com.lab126.wifid enable 1), which is what takes the device out of
    -- airplane mode -- so the enable was never the problem. The difference is
    -- everything after it: turnOnWifi scans, and a just-woken or just-enabled
    -- Kindle radio routinely reports no networks, which aborts the whole
    -- attempt in the same second. Observed repeatedly on device, including on a
    -- manual fetch that failed instantly and then connected first try once
    -- airplane mode was toggled in the Kindle's own settings.
    --
    -- Enable the radio and poll for an address instead, letting Amazon's own
    -- supplicant reconnect to the known network in its own time. The user
    -- asking for a fetch is authorisation enough to turn Wi-Fi on; there is
    -- nothing to prompt about.
    local has_wifi_restore = false
    pcall(function() has_wifi_restore = Device:hasWifiRestore() end)
    if has_wifi_restore and NetworkMgr.restoreWifiAsync then
        local deadline = os.time() + WIFI_TOTAL_BUDGET

        local function restoreFailed(detail)
            onConnectSettled(function()
                logger.err("InkPane: Wi-Fi restore failed --", detail)
                self:oplog("wifi_restore_failed", detail)
                self:recordFailure("wifi")
                if background then
                    self:finishBackgroundCycle(false)
                else
                    self:notify(_("Couldn't connect. Check the Kindle isn't in airplane mode, then try again."), 8)
                    self:releaseWifi()
                    self:endCycle()
                end
            end)
        end

        -- Enabling the radio is not the same as connecting it. Observed on
        -- device 2026-09-08: three consecutive background wakes ran the full
        -- 60-second budget with preventScreenSaver held (so the device was
        -- provably awake throughout) and never got an address, while every
        -- manual fetch in the same period reported "wifi_connected after=0s"
        -- because Wi-Fi was already associated.
        --
        -- restoreWifiAsync is one line -- kindleEnableWifi(1) -- and trusts
        -- Amazon's wifid to reconnect on its own. It doesn't. turnOnWifi is
        -- that same enable PLUS reconnectOrShowNetworkMenu(), and the reconnect
        -- is the part that actually associates; the reason we moved off it was
        -- that it scans immediately and a cold radio reports no networks.
        --
        -- So do both, in the right order: switch the radio on, let it settle,
        -- then ask for the association, and keep asking within the budget
        -- rather than giving up on one failed scan. Non-interactive so nothing
        -- prompts on an unattended device.
        local last_reconnect_at = 0
        local attempts = 0
        local radio_ready_at = os.time() + WIFI_RADIO_SETTLE

        -- The radio's own state, sampled every poll tick but logged only when
        -- it changes. A failure where cmState never leaves NA and one where it
        -- reaches PENDING and cannot finish are different bugs that produced
        -- identical logs until now, and the timestamps say whether our own
        -- retries are interrupting an association that was already running.
        local last_probe = nil

        -- The Scribe logs of 2026-09-11 record seventeen consecutive failures
        -- here and not one word about why: KOReader printed no Wi-Fi lines at
        -- all during those sixty seconds, where the Kindle Basic printed scan
        -- failures. The reason is this function -- it calls turnOnWifi inside a
        -- pcall and throws the answer away, so a call that errors instantly and
        -- a call that silently does nothing look identical from the log.
        --
        -- Say which happened. Without it, any change to the budget above is a
        -- guess dressed up as a fix.
        local function requestReconnect()
            last_reconnect_at = os.time()
            attempts = attempts + 1
            -- Logged with the elapsed time so the gap between attempts is
            -- visible in the log rather than inferred. If association is being
            -- interrupted, the evidence is the interval between these lines.
            self:oplog("wifi_attempt_begin", "n=" .. attempts .. " at=" .. math.max(0, os.time() - started_at)
                .. "s " .. kindleNetworkState())
            local ok, err = pcall(function() NetworkMgr:turnOnWifi(nil, false) end)
            if ok then
                self:oplog("wifi_reconnect_request", "turnOnWifi=ok")
            else
                local fallback_ok = pcall(function() NetworkMgr:restoreWifiAsync() end)
                self:oplog("wifi_reconnect_request", "turnOnWifi=error(" .. tostring(err) .. ") fallback=" .. tostring(fallback_ok))
            end
        end

        poll_task = function()
            if connect_settled then return end

            local probe = kindleNetworkState()
            if probe ~= last_probe then
                self:oplog("net_state", "at=" .. math.max(0, os.time() - started_at) .. "s " .. probe)
                last_probe = probe
            end

            pcall(function() NetworkMgr:queryNetworkState() end)
            if NetworkMgr:isConnected() then
                onConnected()
                return
            end

            if os.time() >= deadline then
                -- What the network layer thought at the moment we gave up. A
                -- failure where isConnected is false the whole way through is a
                -- radio that never associated; one where it flickers true is a
                -- different bug entirely, and until now the log could not tell
                -- the two apart.
                -- NetworkMgr.isWifiOn with a dot, not a colon: a colon is a
                -- method CALL and cannot be used to test whether the method
                -- exists. Not every KOReader version has it.
                local state = "unknown"
                pcall(function()
                    local radio = NetworkMgr.isWifiOn and NetworkMgr:isWifiOn()
                    state = tostring(NetworkMgr:isConnected()) .. " wifi=" .. tostring(radio)
                end)
                restoreFailed("timeout=" .. WIFI_TOTAL_BUDGET .. "s connected=" .. state
                    .. " attempts=" .. attempts .. " " .. kindleNetworkState())
                return
            end

            local now = os.time()
            if now >= radio_ready_at and now - last_reconnect_at >= WIFI_RETRY_GAP then
                requestReconnect()
            end

            UIManager:scheduleIn(WIFI_POLL_INTERVAL, poll_task)
        end

        pcall(function() NetworkMgr:queryNetworkState() end)
        if NetworkMgr:isConnected() then
            self:oplog("wifi_already_connected")
            onConnected()
            return
        end

        -- No second message here. The one at the start of the cycle already
        -- says a wait is expected, and stacking a Wi-Fi notice on top of it
        -- puts two boxes over the Pane for the sake of a detail nobody acts on.

        -- Taken before the radio is touched, so the failing case can be compared
        -- against a Kindle Basic's successful one at the same instant.
        self:oplog("wifi_restore_start", "background=" .. tostring(background) .. " " .. kindleNetworkState())

        -- A device with a wake timer drops Wi-Fi when it goes back to sleep. One
        -- without stays awake between refreshes, so Wi-Fi would stay on unless
        -- InkPane switches it off again at the end of the cycle.
        if not self:canUseRtcWake() then
            self.wifi_enabled_by_inkpane = true
        end

        -- Bring the device properly awake first, or the radio below is switched
        -- on into a state where nothing will use it.
        self:oplog("wake_to_active", kindleWakeToActive())

        local ok, err = pcall(function() NetworkMgr:restoreWifiAsync() end)
        if not ok then
            restoreFailed("start_error=" .. tostring(err))
            return
        end

        UIManager:scheduleIn(WIFI_POLL_INTERVAL, poll_task)
        return
    end

    -- Fallback for platforms with no Wi-Fi restore: KOReader's normal path.
    local function schedulePoll()
        if connect_settled or not poll_task then return end
        UIManager:scheduleIn(WIFI_POLL_INTERVAL, poll_task)
    end

    local attempt = 0
    local last_attempt_at = 0
    local deadline = os.time() + WIFI_TOTAL_BUDGET

    -- runWhenConnected asks KOReader to connect, and with KOReader's default
    -- settings that means a "Turn on Wi-Fi?" question before the refresh and a
    -- "Turn off Wi-Fi?" question over the Pane after it. On an unattended
    -- display nobody answers either. Where the device can switch Wi-Fi itself
    -- (PocketBook, for one), do that directly and switch it off afterwards.
    --
    -- "Seamless" matters: on Android, turnOnWifi opens the system Wi-Fi
    -- settings screen, so an Android e-reader keeps KOReader's usual route.
    local can_toggle = false
    pcall(function() can_toggle = Device:hasSeamlessWifiToggle() end)
    if can_toggle then
        local wifi_on = false
        pcall(function() wifi_on = NetworkMgr:isWifiOn() end)
        if not wifi_on then
            self.wifi_enabled_by_inkpane = true
        end
    end

    local function giveUp(reason)
        onConnectSettled(function()
            logger.err("InkPane: Wi-Fi never connected after", attempt, "attempts --", reason)
            self:oplog("wifi_connect_failed", "attempts=" .. attempt .. " reason=" .. reason)
            self:recordFailure("wifi")
            if background then
                self:finishBackgroundCycle(false)
            else
                self:notify(_("Couldn't connect. Check the Kindle isn't in airplane mode, then try again."), 8)
                self:releaseWifi()
                self:endCycle()
            end
        end)
    end

    local function startAttempt()
        attempt = attempt + 1
        last_attempt_at = os.time()
        logger.info("InkPane: Wi-Fi connect attempt", attempt)
        self:oplog("wifi_connect_attempt", "attempt=" .. attempt .. " direct=" .. tostring(can_toggle))
        if can_toggle then
            local ok, err = pcall(function() NetworkMgr:turnOnWifi(nil, false) end)
            if not ok then self:oplog("wifi_turn_on_error", tostring(err)) end
        else
            NetworkMgr:runWhenConnected(onConnected)
        end
    end

    poll_task = function()
        if connect_settled then return end
        pcall(function() NetworkMgr:queryNetworkState() end)
        if NetworkMgr:isConnected() then
            onConnected()
            return
        end
        if os.time() >= deadline then
            giveUp("budget exhausted")
            return
        end
        if NetworkMgr.pending_connection then
            schedulePoll()
            return
        end
        if os.time() - last_attempt_at < WIFI_RETRY_GAP then
            schedulePoll()
            return
        end
        if attempt >= WIFI_CONNECT_ATTEMPTS then
            giveUp("attempts exhausted")
            return
        end
        logger.warn("InkPane: Wi-Fi attempt", attempt, "died without connecting; retrying")
        startAttempt()
        schedulePoll()
    end

    startAttempt()
    schedulePoll()
end

-- allow_clear is true only when a person asked for this fetch from the menu.
--
-- A scheduled refresh that is told "removed" stops and says so, but keeps its
-- device id, token and pairing code exactly where they are. Erasing them is
-- what made 2026-09-12 unrecoverable: the server answered a database timeout
-- with "invalid token", two healthy Kindles believed it, and both wiped
-- themselves while their device rows sat untouched and still paired.
--
-- The server no longer confuses those two things, and only says DEVICE_REVOKED
-- after a lookup that actually completed. But a wrong answer is still possible
-- for reasons we cannot see from here -- a bad migration, a change to how
-- tokens are stored -- and those go wrong for every device at once. So the
-- destructive half now happens only with someone standing in front of the
-- device, where the cost of being wrong is one person re-pairing rather than
-- every customer doing it. If the answer was wrong and gets fixed, a stopped
-- device is still a device that can simply be started again.
function InkPane:handleRevokedToken(allow_clear)
    self:oplog("device_token_revoked", "cleared=" .. tostring(allow_clear == true))
    self:stopInkPane(false)

    if not allow_clear then
        self:notify(_("InkPane says this display was removed from your account. Use \"Fetch screen now\" to check."), 8)
        return
    end

    self.settings.device_id = nil
    self.settings.device_token = nil
    self.settings.pairing_code = nil
    self.settings.pairing_expires_at = nil
    self:saveSettings()
    self:notify(_("This display was removed from your InkPane account. Fetch again to pair it once more."), 8)
end

function InkPane:setRefreshInterval(seconds, label)
    self.settings.refresh_interval = seconds
    self.settings.fixed_interval_version = 1
    self.settings.use_server_refresh_rate = nil
    self:saveSettings()
    if self.auto_refresh_enabled then self:scheduleRtcWake() end
    logger.info("InkPane: refresh interval changed to", seconds, "seconds")
    self:oplog("interval_changed", "seconds=" .. seconds)
    if label then self:notify(_("Refresh interval: ") .. label, 3) end
end

function InkPane:addToMainMenu(menu_items)
    local interval_items = {}
    -- NOT `for _, option`: `_` is gettext (see the requires at the top), and a
    -- loop variable of that name shadows it for the whole body, so the _(label)
    -- calls below would be calling a number. addToMainMenu then throws and the
    -- InkPane entry never reaches the Tools menu at all.
    for index = 1, #REFRESH_INTERVALS do
        local option = REFRESH_INTERVALS[index]
        local label = option.pro and (option.label .. " · Pro") or option.label
        local seconds = option.seconds
        table.insert(interval_items, {
            text = _(label),
            radio = true,
            checked_func = function()
                return self:getRefreshInterval() == seconds
            end,
            callback = function()
                self:setRefreshInterval(seconds, _(label))
            end,
        })
    end

    menu_items.inkpane = {
        text = _("InkPane"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Fetch screen now"),
                callback = function() self:refresh(false) end,
            },
            {
                text = _("Refresh interval"),
                sub_item_table = interval_items,
            },
        },
    }
end

function InkPane:onCloseWidget()
    if not self.auto_refresh_enabled then
        self:unscheduleRtcWake()
    end
    self:restoreAutoSuspendTimeout()
    if self.image_widget then
        UIManager:close(self.image_widget)
        self.image_widget = nil
    end
    -- The Pane goes with this screen (opening a book, or KOReader closing).
    self:releaseSleepScreen()
end

return InkPane
