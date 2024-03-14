-- Sample Performance Monitor Class Module
-- shamelessly ripped from RGMercs Lua 
-- as suggested by Derple

local mq                  = require('mq')
local ImGui               = require('ImGui')
local ImPlot              = require('ImPlot')
local Set                 = require('mq.Set')
local ScrollingPlotBuffer = require('utils.scrolling_plot_buffer')

local XPEvents           = {}
local MaxStep            = 50
local GoalMaxExpPerSec   = 0
local CurMaxExpPerSec    = 0
local LastExtentsCheck   = os.clock()
local XPPerSecond        = 0
local XPToNextLevel      = 0
local SecondsToLevel     = 0
local TimeToLevel        = "<Unknown>"

local TrackXP            = {
    PlayerLevel = mq.TLO.Me.Level(),
    PlayerAA = mq.TLO.Me.AAPointsTotal(),
    StartTime = os.clock(),

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

local DefaultConfig      = {
    ['ExpSecondsToStore'] = 1800,
    ['ExpPlotFillLines']  = true,
    ['GraphMultiplier']   = 1,
}

local multiplier = tonumber(DefaultConfig.GraphMultiplier)

local function ClearStats()
    TrackXP = {
        PlayerLevel = mq.TLO.Me.Level(),
        PlayerAA = mq.TLO.Me.AAPointsTotal(),
        -- assume we started early so initial numbers are not super out of whack
        StartTime = os.clock() - 60,

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


local function RenderShaded(type, currentData, otherData, multiplier)
    if currentData then
        local offset = currentData.expEvents.Offset - 1
        local count = #currentData.expEvents.DataY

        if DefaultConfig.ExpPlotFillLines then
            ImPlot.PlotShaded(type,
                function(n)
                    local pos = ((offset + n) % count) + 1
                    return ImPlotPoint(currentData.expEvents.DataX[pos], currentData.expEvents.DataY[pos] * multiplier)
                end,
                function(n)
                    local pos = ((offset + n) % count) + 1
                    local lowerBound = 0
                    if otherData and otherData.expEvents and otherData.expEvents.DataY[pos] and otherData.expEvents.DataY[pos] < currentData.expEvents.DataY[pos] then
                        lowerBound = otherData.expEvents.DataY[pos] 
                    end
                    return ImPlotPoint(currentData.expEvents.DataX[pos], lowerBound)
                end,
                count,
                ImPlotShadedFlags.None)
        end
        ImPlot.PlotLine(type,
            ---@diagnostic disable-next-line: param-type-mismatch
            function(n)
                local pos = ((offset + n) % count) + 1

                if currentData.expEvents.DataY[pos] == nil then
                    return ImPlotPoint(0, 0)
                end

                return ImPlotPoint(currentData.expEvents.DataX[pos], currentData.expEvents.DataY[pos] * multiplier)
            end,
            count,
            ImPlotLineFlags.None)
    end
end

local openGUI = true
local shouldDrawGUI = true

function FormatTime(time, formatString)
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
            ImGui.Text(FormatTime(os.clock() - TrackXP.StartTime))
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
            -- 15 sec intervals, only count full AAs
            ImGui.Text(string.format("%2.2f", ((TrackXP.AAExperience.Total / TrackXP.XPTotalDivider) / (math.floor(os.clock()/15)*15 - TrackXP.StartTime)) * 60 * 60 / 100))
            ImGui.EndTable()
        end



        -- converge on new max recalc min and maxes
        if CurMaxExpPerSec + 100 < GoalMaxExpPerSec then CurMaxExpPerSec = CurMaxExpPerSec + 100 
        elseif CurMaxExpPerSec + 10 < GoalMaxExpPerSec then CurMaxExpPerSec = CurMaxExpPerSec + 10 
        elseif CurMaxExpPerSec < GoalMaxExpPerSec then CurMaxExpPerSec = CurMaxExpPerSec + 1 
        end
        if CurMaxExpPerSec - 100 > GoalMaxExpPerSec then CurMaxExpPerSec = CurMaxExpPerSec - 100 
        elseif CurMaxExpPerSec - 10 > GoalMaxExpPerSec  then CurMaxExpPerSec = CurMaxExpPerSec - 10 
        elseif CurMaxExpPerSec > GoalMaxExpPerSec then CurMaxExpPerSec = CurMaxExpPerSec - 1 
        end


        if ImPlot.BeginPlot("Experience Tracker") then
            if multiplier == 1 then
                ImPlot.SetupAxes("Time (s)", "Exp ")
            else
                ImPlot.SetupAxes("Time (s)", string.format("Exp in %sths", multiplier))
            end
            ImPlot.SetupAxisLimits(ImAxis.X1, os.clock() - DefaultConfig.ExpSecondsToStore, os.clock(), ImGuiCond.Always)
            ImPlot.SetupAxisLimits(ImAxis.Y1, 1, CurMaxExpPerSec, ImGuiCond.Always)

            ImPlot.PushStyleVar(ImPlotStyleVar.FillAlpha, 0.35)
            RenderShaded("Exp", XPEvents.Exp, XPEvents.AA, multiplier)
            RenderShaded("AA", XPEvents.AA, XPEvents.Exp, multiplier)
            ImPlot.PopStyleVar()

            ImPlot.EndPlot()
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
    if mq.TLO.EverQuest.GameState() == "INGAME" then
        if CheckExpChanged() then
            printf("\ayXP Gained: \ag%02.3f%% \aw|| \ayXP Total: \ag%02.3f%% \aw|| \ayStart: \am%d \ayCur: \am%d \ayExp/Sec: \ag%2.3f%%",
                TrackXP.Experience.Gained / TrackXP.XPTotalDivider,
                TrackXP.Experience.Total / TrackXP.XPTotalDivider,
                TrackXP.StartTime,
                os.clock(),
                TrackXP.Experience.Total / TrackXP.XPTotalDivider / ((os.clock()) - TrackXP.StartTime))
        end

        if not XPEvents.Exp then
            XPEvents.Exp = {
                lastFrame = os.clock(),
                expEvents =
                    ScrollingPlotBuffer:new(),
            }
        end

        

        XPPerSecond    = (TrackXP.Experience.Total / TrackXP.XPTotalDivider) / (os.clock() - TrackXP.StartTime)
        XPToNextLevel  = TrackXP.XPTotalPerLevel - mq.TLO.Me.Exp()
        AAXPPerSecond  = ((TrackXP.AAExperience.Total / TrackXP.XPTotalDivider) / (os.clock() - TrackXP.StartTime)) / 100
        SecondsToLevel = XPToNextLevel / (XPPerSecond * TrackXP.XPTotalDivider)
        TimeToLevel    = XPPerSecond <= 0 and "<Unknown>" or FormatTime(SecondsToLevel, "%d Days %d Hours %d Mins")

        XPEvents.Exp.lastFrame = os.clock()
        ---@diagnostic disable-next-line: undefined-field
        XPEvents.Exp.expEvents:AddPoint(os.clock(), XPPerSecond * 60 * 60)


        if mq.TLO.Me.PctAAExp() > 0 and CheckAAExpChanged() then
            printf("\ayAA Gained: \ag%2.2f \aw|| \ayAA Total: \ag%2.2f", TrackXP.AAExperience.Gained / TrackXP.XPTotalDivider / 100,
                TrackXP.AAExperience.Total / TrackXP.XPTotalDivider / 100)
        end

        if not XPEvents.AA then
            XPEvents.AA = {
                lastFrame = os.clock(),
                expEvents =
                    ScrollingPlotBuffer:new(),
            }
        end

        XPEvents.AA.lastFrame = os.clock()
        ---@diagnostic disable-next-line: undefined-field
        XPEvents.AA.expEvents:AddPoint(os.clock(), AAXPPerSecond * 60 * 60)
        --XPEvents.AA.expEvents:AddPoint(os.clock(), (TrackXP.AAExperience.Total / ((os.clock()) - TrackXP.StartTime)) / 100)
        
    end

    if os.clock() - LastExtentsCheck > 0.5 then
        GoalMaxExpPerSec = 0
        LastExtentsCheck = os.clock()
        for _, expData in pairs(XPEvents) do
            for idx, exp in ipairs(expData.expEvents.DataY) do
                exp = exp * multiplier
                -- is this entry visible?
                local visible = expData.expEvents.DataX[idx] > os.clock() - DefaultConfig.ExpSecondsToStore and
                    expData.expEvents.DataX[idx] < os.clock()
                if visible and exp > GoalMaxExpPerSec then
                    GoalMaxExpPerSec = (math.ceil(exp / MaxStep) * MaxStep) * 1.25
                end
            end
        end
    end
end

mq.imgui.init('xptracker', DrawMainWindow)

while openGUI do
    mq.delay(1000)
    GiveTime()
end
