-- Sample Performance Monitor Class Module
-- shamelessly ripped from RGMercs Lua
-- as suggested by Derple

-- initial version

local mq                  = require('mq')
local ImGui               = require('ImGui')
local ImPlot              = require('ImPlot')
local Set                 = require('mq.Set')
local ScrollingPlotBuffer = require('utils.scrolling_plot_buffer')

local XPEvents            = {}
local MaxStep             = 50
local GoalMaxExpPerSec    = 0
local CurMaxExpPerSec     = 0
local LastExtentsCheck    = 0
local XPPerSecond         = 0
local XPToNextLevel       = 0
local SecondsToLevel      = 0
local TimeToLevel         = "<Unknown>"
local Resolution          = 15 -- seconds

-- timezone calcs
local utc_now             = os.time(os.date("!*t", os.time()))
local local_now           = os.time(os.date("*t", os.time()))
local utc_offset          = local_now - utc_now

-- Check if we're currently in daylight saving time
local dst                 = os.date("*t", os.time())["isdst"]

-- If we're in DST, add one hour
if dst then
    utc_offset = utc_offset + 3600
end

local function getTime()
    return os.time() + utc_offset
end

local TrackXP       = {
    PlayerLevel = mq.TLO.Me.Level(),
    PlayerAA = mq.TLO.Me.AAPointsTotal(),
    StartTime = getTime(),

    XPTotalPerLevel = 100000,
    XPTotalDivider = 1000,

    Experience = {
        Base = mq.TLO.Me.Exp(),
        Total = 0,
        Gained = 0,
    },
    AAExperience = {
        Base = mq.TLO.Me.AAExp(),
        Total = 0,
        Gained = 0,
    },
}

local settings      = {}

local DefaultConfig = {
    ['ExpSecondsToStore'] = 1800,
    ['ExpPlotFillLines']  = true,
    ['GraphMultiplier']   = 1,
}

settings            = DefaultConfig

local multiplier    = tonumber(settings.GraphMultiplier)

local function ClearStats()
    TrackXP = {
        PlayerLevel = mq.TLO.Me.Level(),
        PlayerAA = mq.TLO.Me.AAPointsTotal(),
        StartTime = getTime(),

        XPTotalPerLevel = 100000,
        XPTotalDivider = 1000,

        Experience = {
            Base = mq.TLO.Me.Exp(),
            Total = 0,
            Gained = 0,
        },
        AAExperience = {
            Base = mq.TLO.Me.AAExp(),
            Total = 0,
            Gained = 0,
        },
    }

    XPEvents = {}
end

local function RenderShaded(type, currentData, otherData)
    if currentData then
        local count = #currentData.expEvents.DataY
        local otherY = {}

        if settings.ExpPlotFillLines then
            for idx, _ in ipairs(currentData.expEvents.DataY) do
                otherY[idx] = 0
                if otherData.expEvents.DataY[idx] then
                    if currentData.expEvents.DataY[idx] >= otherData.expEvents.DataY[idx] then
                        otherY[idx] = otherData.expEvents.DataY[idx]
                    end
                end
            end
            ImPlot.PlotShaded(type, currentData.expEvents.DataX, currentData.expEvents.DataY, otherY,
                count, ImPlotShadedFlags.None, currentData.expEvents.Offset - 1)
        end

        ImPlot.PlotLine(type, currentData.expEvents.DataX, currentData.expEvents.DataY,
            count, ImPlotLineFlags.None, currentData.expEvents.Offset - 1)
    end
end

local openGUI = true
local shouldDrawGUI = true

local function FormatTime(time, formatString)
    local days = math.floor(time / 86400)
    local hours = math.floor((time % 86400) / 3600)
    local minutes = math.floor((time % 3600) / 60)
    local seconds = math.floor((time % 60))
    return string.format(formatString and formatString or "%d:%02d:%02d:%02d", days, hours, minutes, seconds)
end

local function DrawMainWindow()
    if not openGUI then return end
    openGUI, shouldDrawGUI = ImGui.Begin('xpTrack', openGUI)

    if shouldDrawGUI then
        ImGui.SameLine()
        local pressed
        if ImGui.Button("Reset Stats", ImGui.GetWindowWidth() * .3, 25) then
            ClearStats()
        end

        if ImGui.BeginTable("ExpStats", 2, bit32.bor(ImGuiTableFlags.Borders)) then
            ImGui.TableNextColumn()
            ImGui.Text("Exp Session Time")
            ImGui.TableNextColumn()
            ImGui.Text(FormatTime(getTime() - TrackXP.StartTime))
            ImGui.TableNextColumn()
            ImGui.Text("Exp Gained")
            ImGui.TableNextColumn()
            ImGui.Text(string.format("%2.3f%%", TrackXP.Experience.Total / TrackXP.XPTotalDivider))
            ImGui.TableNextColumn()
            ImGui.Text("AA Gained")
            ImGui.TableNextColumn()
            ImGui.Text(string.format("%2.2f", TrackXP.AAExperience.Total / TrackXP.XPTotalDivider / 100))
            ImGui.TableNextColumn()
            ImGui.Text("Exp / Min")
            ImGui.TableNextColumn()
            ImGui.Text(string.format("%2.3f%%", XPPerSecond * 60))
            ImGui.TableNextColumn()
            ImGui.Text("Exp / Hr")
            ImGui.TableNextColumn()
            ImGui.Text(string.format("%2.3f%%", XPPerSecond * 3600))
            ImGui.TableNextColumn()
            ImGui.Text("Time To Level")
            ImGui.TableNextColumn()
            ImGui.Text(string.format("%s", TimeToLevel))
            ImGui.TableNextColumn()
            ImGui.Text("AA / Hr")
            ImGui.TableNextColumn()
            -- "Resolution" sec intervals, only count full AAs
            ImGui.Text(string.format("%2.2f",
                ((TrackXP.AAExperience.Total / TrackXP.XPTotalDivider) / (math.floor(getTime() / Resolution) * Resolution - TrackXP.StartTime)) * 60 * 60 / 100))
            ImGui.EndTable()
        end

        local ordMagDiff = 10 ^ math.floor(math.abs(math.log((CurMaxExpPerSec > 0 and CurMaxExpPerSec or 1) / (GoalMaxExpPerSec > 0 and GoalMaxExpPerSec or 1), 10)))

        -- converge on new max recalc min and maxes
        if CurMaxExpPerSec < GoalMaxExpPerSec then
            CurMaxExpPerSec = CurMaxExpPerSec + ordMagDiff
        end

        if CurMaxExpPerSec > GoalMaxExpPerSec then
            CurMaxExpPerSec = CurMaxExpPerSec - ordMagDiff
        end


        if ImPlot.BeginPlot("Experience Tracker") then
            ImPlot.SetupAxisScale(ImAxis.X1, ImPlotScale.Time)
            if multiplier == 1 then
                ImPlot.SetupAxes("Local Time", "Exp ")
            else
                ImPlot.SetupAxes("Local Time", string.format("reg. Exp in %sths", multiplier))
            end
            ImPlot.SetupAxisLimits(ImAxis.X1, getTime() - settings.ExpSecondsToStore, getTime(), ImGuiCond.Always)
            ImPlot.SetupAxisLimits(ImAxis.Y1, 1, CurMaxExpPerSec, ImGuiCond.Always)

            ImPlot.PushStyleVar(ImPlotStyleVar.FillAlpha, 0.35)
            RenderShaded("Exp", XPEvents.Exp, XPEvents.AA)
            RenderShaded("AA", XPEvents.AA, XPEvents.Exp)
            ImPlot.PopStyleVar()

            ImPlot.EndPlot()
        end
        if ImGui.CollapsingHeader("Config Options") then
            settings.ExpSecondsToStore, pressed = ImGui.SliderInt("Exp observation period",
                settings.ExpSecondsToStore, 60, 3600, "%d s")

            settings.GraphMultiplier, pressed = ImGui.SliderInt("Scaleup for regular XP",
                settings.GraphMultiplier, 1, 20, "%d x")
            if pressed then
                if settings.GraphMultiplier < 5 then
                    settings.GraphMultiplier = 1
                elseif settings.GraphMultiplier < 15 then
                    settings.GraphMultiplier = 10
                else
                    settings.GraphMultiplier = 20
                end

                local new_multiplier = tonumber(settings.GraphMultiplier)

                for idx, pt in ipairs(XPEvents.Exp.expEvents.DataY) do
                    XPEvents.Exp.expEvents.DataY[idx] = (pt / multiplier) * new_multiplier
                end

                multiplier = new_multiplier
            end

            settings.ExpPlotFillLines = ImGui.Checkbox("Shade Plot Lines", settings.ExpPlotFillLines)
        end
    end
    ImGui.Spacing()
    ImGui.End()
end

local function CheckExpChanged()
    local me = mq.TLO.Me
    local currentExp = me.Exp()
    if currentExp ~= TrackXP.Experience.Base then
        if me.Level() == TrackXP.PlayerLevel then
            TrackXP.Experience.Gained = currentExp - TrackXP.Experience.Base
        elseif me.Level() > TrackXP.PlayerLevel then
            TrackXP.Experience.Gained = TrackXP.XPTotalPerLevel - TrackXP.Experience.Base + currentExp
        else
            TrackXP.Experience.Gained = TrackXP.Experience.Base - TrackXP.XPTotalPerLevel + currentExp
        end

        TrackXP.Experience.Total = TrackXP.Experience.Total + TrackXP.Experience.Gained
        TrackXP.Experience.Base = currentExp
        TrackXP.PlayerLevel = me.Level()

        return true
    end

    TrackXP.Experience.Gained = 0
    return false
end

local function CheckAAExpChanged()
    local me = mq.TLO.Me
    local currentExp = me.AAExp()
    if currentExp ~= TrackXP.AAExperience.Base then
        if me.AAPointsTotal() == TrackXP.PlayerAA then
            TrackXP.AAExperience.Gained = currentExp - TrackXP.AAExperience.Base
        else
            TrackXP.AAExperience.Gained = currentExp - TrackXP.AAExperience.Base + ((me.AAPointsTotal() - TrackXP.PlayerAA) * TrackXP.XPTotalPerLevel)
        end

        TrackXP.AAExperience.Total = TrackXP.AAExperience.Total + TrackXP.AAExperience.Gained
        TrackXP.AAExperience.Base = currentExp
        TrackXP.PlayerAA = me.AAPointsTotal()

        return true
    end

    TrackXP.AAExperience.Gained = 0
    return false
end

local function GiveTime()
    local now = getTime()

    if mq.TLO.EverQuest.GameState() == "INGAME" then
        if CheckExpChanged() then
            printf("\ayXP Gained: \ag%02.3f%% \aw|| \ayXP Total: \ag%02.3f%% \aw|| \ayStart: \am%d \ayCur: \am%d \ayExp/Sec: \ag%2.3f%%",
                TrackXP.Experience.Gained / TrackXP.XPTotalDivider,
                TrackXP.Experience.Total / TrackXP.XPTotalDivider,
                TrackXP.StartTime,
                now,
                TrackXP.Experience.Total / TrackXP.XPTotalDivider / (math.floor(now / Resolution) * Resolution - TrackXP.StartTime))
        end

        if not XPEvents.Exp then
            XPEvents.Exp = {
                lastFrame = now,
                expEvents =
                    ScrollingPlotBuffer:new(),
            }
        end

        XPPerSecond            = (TrackXP.Experience.Total / TrackXP.XPTotalDivider) / (math.floor(now / Resolution) * Resolution - TrackXP.StartTime)
        XPToNextLevel          = TrackXP.XPTotalPerLevel - mq.TLO.Me.Exp()
        AAXPPerSecond          = ((TrackXP.AAExperience.Total / TrackXP.XPTotalDivider) / (math.floor(now / Resolution) * Resolution - TrackXP.StartTime)) / 100
        SecondsToLevel         = XPToNextLevel / (XPPerSecond * TrackXP.XPTotalDivider)
        TimeToLevel            = XPPerSecond <= 0 and "<Unknown>" or FormatTime(SecondsToLevel, "%d Days %d Hours %d Mins")

        XPEvents.Exp.lastFrame = now
        ---@diagnostic disable-next-line: undefined-field
        XPEvents.Exp.expEvents:AddPoint(now, XPPerSecond * 60 * 60 * multiplier)

        if mq.TLO.Me.PctAAExp() > 0 and CheckAAExpChanged() then
            printf("\ayAA Gained: \ag%2.2f \aw|| \ayAA Total: \ag%2.2f", TrackXP.AAExperience.Gained / TrackXP.XPTotalDivider / 100,
                TrackXP.AAExperience.Total / TrackXP.XPTotalDivider / 100)
        end

        if not XPEvents.AA then
            XPEvents.AA = {
                lastFrame = now,
                expEvents =
                    ScrollingPlotBuffer:new(),
            }
        end

        XPEvents.AA.lastFrame = now
        ---@diagnostic disable-next-line: undefined-field
        XPEvents.AA.expEvents:AddPoint(now, AAXPPerSecond * 60 * 60)
    end

    if now - LastExtentsCheck > 0.5 then
        local newGoal = 0
        LastExtentsCheck = now
        for id, expData in pairs(XPEvents) do
            for idx, exp in ipairs(expData.expEvents.DataY) do
                -- is this entry visible?
                local curGoal = math.ceil(exp / MaxStep * MaxStep * 1.25)
                local visible = expData.expEvents.DataX[idx] > (now - settings.ExpSecondsToStore)
                if visible and curGoal > newGoal then
                    newGoal = curGoal
                end
            end
        end
        GoalMaxExpPerSec = newGoal
    end
end

mq.imgui.init('xptracker', DrawMainWindow)

while openGUI do
    mq.delay(1000)
    GiveTime()
end
