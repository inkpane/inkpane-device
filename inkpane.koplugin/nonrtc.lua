-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 InkPane
-- See LICENSE for the full terms, THIRD_PARTY_NOTICES for included third-party code.

-- Non-RTC refresh extension for InkPane.
--
-- This module is loaded only when Device.wakeup_mgr is unavailable. It follows
-- the proven KOReader/TRMNL pattern for those devices: keep KOReader awake,
-- schedule the next refresh with UIManager:scheduleIn(), fetch, display, repeat.
-- The RTC client itself remains untouched.

local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")

return function(InkPane)
    local original_init = InkPane.init
    local original_refresh = InkPane.refresh
    local original_display_image = InkPane.displayImage
    local original_finish_interactive = InkPane.finishInteractiveCycle
    local original_finish_background = InkPane.finishBackgroundCycle
    local original_stop = InkPane.stopInkPane
    local original_resume = InkPane.onResume
    local original_set_interval = InkPane.setRefreshInterval
    local original_close = InkPane.onCloseWidget
    local original_end_cycle = InkPane.endCycle

    InkPane.software_refresh_task = nil
    InkPane.software_refresh_scheduled = false
    InkPane.software_standby_hold_owned = false
    InkPane.software_refresh_background = nil

    function InkPane:holdSoftwareStandby()
        if self.software_standby_hold_owned then return end
        UIManager:preventStandby()
        self.software_standby_hold_owned = true
        logger.info("InkPane: standby prevented for software-timer refresh mode")
        self:oplog("software_standby_hold")
    end

    function InkPane:releaseSoftwareStandbyHold()
        if not self.software_standby_hold_owned then return end
        UIManager:allowStandby()
        self.software_standby_hold_owned = false
        logger.info("InkPane: standby restored after software-timer refresh mode")
        self:oplog("software_standby_release")
    end

    function InkPane:unscheduleSoftwareRefresh()
        if self.software_refresh_task then
            UIManager:unschedule(self.software_refresh_task)
        end
        self.software_refresh_scheduled = false
    end

    function InkPane:scheduleSoftwareRefresh()
        if not self.auto_refresh_enabled or self:canUseRtcWake() then return false end

        local interval = self:getRefreshInterval()
        self:unscheduleSoftwareRefresh()
        self:holdSoftwareStandby()
        UIManager:scheduleIn(interval, self.software_refresh_task)
        self.software_refresh_scheduled = true

        logger.info("InkPane: next software refresh in", interval, "seconds")
        self:oplog("software_timer_queued", "in=" .. interval)
        return true
    end

    function InkPane:init()
        original_init(self)

        self.software_refresh_scheduled = false
        self.software_standby_hold_owned = false
        self.software_refresh_background = nil
        self.software_refresh_task = function()
            self.software_refresh_scheduled = false
            if not self.auto_refresh_enabled or self:canUseRtcWake() then return end

            logger.info("InkPane: software refresh timer fired")
            self:oplog("software_timer_fired")
            self:refresh(true)
        end

        self:oplog("scheduler_selected", "software")
    end

    -- Remember whether a cycle was interactive. The known-good client enables
    -- automatic mode only after a successful interactive render on RTC devices;
    -- for non-RTC devices we mirror that exact moment in displayImage below.
    function InkPane:refresh(background)
        self.software_refresh_background = background and true or false
        return original_refresh(self, background)
    end

    function InkPane:displayImage(image_path)
        local displayed = original_display_image(self, image_path)

        if displayed
            and self.software_refresh_background == false
            and not self.auto_refresh_enabled
            and not self:canUseRtcWake()
        then
            self.auto_refresh_enabled = true
            self:saveSettings()
            self:oplog("inkpane_started", "scheduler=software")
        end

        return displayed
    end

    function InkPane:finishInteractiveCycle()
        if self:canUseRtcWake() then
            return original_finish_interactive(self)
        end

        if self.auto_refresh_enabled then
            self:scheduleSoftwareRefresh()
            self:holdSoftwareStandby()
        end

        self:releaseWifi()
        self:oplog("cycle_complete", "background=false active=" .. tostring(self.auto_refresh_enabled) .. " scheduler=software")
        self:endCycle()
    end

    function InkPane:finishBackgroundCycle(success)
        if self:canUseRtcWake() then
            return original_finish_background(self, success)
        end

        if not self.auto_refresh_enabled then
            self:endCycle()
            self:releaseWifi()
            return
        end

        if not success and self.current_image_path then
            self:displayImage(self.current_image_path)
        end

        self:scheduleSoftwareRefresh()
        logger.info("InkPane: software-timer background refresh complete; success:", success)
        self:oplog("cycle_complete", "background=true success=" .. tostring(success) .. " scheduler=software")
        self:releaseWifi()
        self:endCycle()
    end

    function InkPane:stopInkPane(show_message)
        local result = original_stop(self, show_message)
        self:unscheduleSoftwareRefresh()
        self:releaseSoftwareStandbyHold()
        return result
    end

    function InkPane:onSuspend()
        if self.auto_refresh_enabled and not self:canUseRtcWake() then
            self:unscheduleSoftwareRefresh()
            self:oplog("software_timer_paused", "reason=suspend")
        end
    end

    function InkPane:onResume()
        if self:canUseRtcWake() then
            return original_resume(self)
        end

        if not self.auto_refresh_enabled or self.refresh_in_progress then return end

        self:holdSoftwareStandby()
        if not self.software_refresh_scheduled then
            self:scheduleSoftwareRefresh()
        end
    end

    function InkPane:setRefreshInterval(seconds, label)
        local result = original_set_interval(self, seconds, label)
        if self.auto_refresh_enabled and not self:canUseRtcWake() then
            self:scheduleSoftwareRefresh()
        end
        return result
    end

    function InkPane:endCycle()
        local result = original_end_cycle(self)
        self.software_refresh_background = nil
        return result
    end

    function InkPane:onCloseWidget()
        if not self:canUseRtcWake() then
            self:unscheduleSoftwareRefresh()
            self:releaseSoftwareStandbyHold()
        end
        return original_close(self)
    end

    return InkPane
end
