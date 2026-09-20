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
