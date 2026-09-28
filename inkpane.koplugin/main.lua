-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 InkPane
-- See LICENSE for the full terms.

-- InkPane package entry point.
--
-- The RTC client remains the base implementation. Small capability extensions
-- are layered on top so the core client stays easy to validate on Kindle.

local Device = require("device")

-- The Kindle sleep screen used to be forced to "leave as-is" here, once and for
-- good, on every start. It is now held only while a Pane is showing and the
-- person's own choice is put back afterwards: see holdSleepScreen and
-- releaseSleepScreen in main_rtc.lua.

local info = debug.getinfo(1, "S")
local filepath = info and info.source and info.source:match("^@(.+)$")
local plugin_dir = filepath and filepath:match("(.*/)")
if not plugin_dir then
    error("InkPane: could not resolve plugin directory")
end

local rtc_chunk, rtc_error = loadfile(plugin_dir .. "main_rtc.lua")
if not rtc_chunk then
    error("InkPane: could not load main_rtc.lua: " .. tostring(rtc_error))
end

local InkPane = rtc_chunk()

local pairing_chunk, pairing_error = loadfile(plugin_dir .. "pairing.lua")
if not pairing_chunk then
    error("InkPane: could not load pairing.lua: " .. tostring(pairing_error))
end
InkPane = pairing_chunk()(InkPane)

-- Showing the Pane as the sleep screen. Optional, so it is loaded softly: a
-- copy without this file, or with a broken one, must still work exactly as it
-- did before, rather than stop the plugin loading at all.
local sleep_chunk, sleep_error = loadfile(plugin_dir .. "sleepscreen.lua")
if sleep_chunk then
    local ok, with_sleep_screen = pcall(function() return sleep_chunk()(InkPane) end)
    if ok and with_sleep_screen then
        InkPane = with_sleep_screen
    else
        require("logger").warn("InkPane: sleep screen unavailable:", with_sleep_screen)
    end
else
    require("logger").info("InkPane: no sleep screen:", sleep_error)
end

-- Devices without KOReader's hardware wake manager get the software-timer
-- extension layered on top of the same pairing-aware client.
if Device.wakeup_mgr ~= nil then
    return InkPane
end

local nonrtc_chunk, nonrtc_error = loadfile(plugin_dir .. "nonrtc.lua")
if not nonrtc_chunk then
    error("InkPane: could not load nonrtc.lua: " .. tostring(nonrtc_error))
end

local enhance = nonrtc_chunk()
return enhance(InkPane)
