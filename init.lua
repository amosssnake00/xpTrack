-- Sample Performance Monitor Class Module
-- Refactored to use SQLite database for XP data storage and display.

local mq                   = require('mq')
local ImGui                = require('ImGui')
local ImPlot               = require('ImPlot')
local ScrollingPlotBuffer  = require('utils.scrolling_plot_buffer')
local db_utils             = require('db_utils') -- Added for database interaction

-- Database Path (should match xp_collector.lua)
local db_path = "xp_data.sqlite"
local db -- Database connection object

-- --- Database Initialization ---
local function connect_and_init_db()
    db = db_utils.get_db_connection(db_path)
    if not db then
        if mq and mq.printf then
            mq.printf("\20XPTrackUI: \arFatal Error: Could not connect to database at %s.", db_path)
        else
            print("XPTrackUI: Fatal Error: Could not connect to database at " .. db_path .. ".")
        end
        return false
    end

    local ok, err_msg = db_utils.init_db(db) -- Ensures table exists
    if not ok then
        if mq and mq.printf then
            mq.printf("\20XPTrackUI: \arWarning: Could not initialize database: %s.", err_msg or "Unknown error")
        else
            print("XPTrackUI: Warning: Could not initialize database: " .. (err_msg or "Unknown error") .. ".")
        end
        -- Continue anyway, as collector might create it.
    end
    if mq and mq.printf then
        mq.printf("\20XPTrackUI: \agDatabase connection successful for UI.")
    else
        print("XPTrackUI: Database connection successful for UI.")
    end
    return true
end

-- Attempt to connect to DB on script start
if not connect_and_init_db() then
    -- If connection fails, UI might be limited. Could decide to exit or run with limited functionality.
    -- For now, will allow script to continue, but plotting will fail.
    mq.printf("\20XPTrackUI: \arDB connection failed. UI will be non-functional for data display.")
end


-- local OnEmu                = (mq.TLO.MacroQuest.BuildName():lower() or "") == "emu" -- Keep for now if any UI elements depend on it

-- Old XP Tracking Logic - To be removed or refactored
-- local XPEvents             = {} -- Will be re-purposed for DB data
local MaxStep              = 50 -- May be useful for plot scaling
local CurMaxExpPerSec      = 0  -- Will be determined by fetched data
local GoalMaxExpPerSec     = 0  -- Will be determined by fetched data
local LastExtentsCheck     = 0
-- local LastEntry            = 0
-- local XPPerSecond          = 0 -- To be derived from DB
-- local AAXPPerSecond        = 0 -- To be derived from DB
-- local PrevXPTotal          = 0
-- local PrevAATotal          = 0

-- local XPTotalPerLevel      = OnEmu and 330 or 100000
-- local XPTotalDivider       = OnEmu and 1 or 1000

-- local startXP              = OnEmu and mq.TLO.Me.PctExp() or (mq.TLO.Me.Exp() / XPTotalDivider)
-- local startLvl             = mq.TLO.Me.Level()
-- local startAAXP            = OnEmu and mq.TLO.Me.PctAAExp() or (mq.TLO.Me.AAExp() / XPTotalDivider)
-- local startAA              = mq.TLO.Me.AAPointsTotal()

-- local XPToNextLevel        = 0
-- local SecondsToLevel       = 0
-- local SecondsToAA          = 0
-- local TimeToLevel          = "<Unknown>" -- To be derived or removed
-- local TimeToAA             = "<Unknown>" -- To be derived or removed
local Resolution           = 15   -- seconds, may not be relevant for DB display
local MaxExpSecondsToStore = 3600 -- Default for live view window
local MaxHorizon           = 3600
-- local MinTime              = 30 -- For waiting for initial data, less relevant now

-- local offset               = 1
-- local horizon_or_less      = 60
-- local trackback            = 1
-- local first_tick           = 0

local ImGui_HorizonStep1   = 1 * 60
local ImGui_HorizonStep2   = 5 * 60
local ImGui_HorizonStep3   = 30 * 60
local ImGui_HorizonStep4   = 60 * 60

local debug                = false

-- timezone calcs (keep for converting timestamps from DB if needed, or for historical input)
---@diagnostic disable-next-line: param-type-mismatch
local utc_now_os_time      = os.time(os.date("!*t", os.time()))
---@diagnostic disable-next-line: param-type-mismatch
local local_now_os_time    = os.time(os.date("*t", os.time()))
local utc_offset           = local_now_os_time - utc_now_os_time

if os.date("*t", os.time())["isdst"] then
    utc_offset = utc_offset + 3600
end

-- This function converts a UTC timestamp (from DB) to local time for plotting
local function utc_to_local(utc_timestamp)
    return utc_timestamp - utc_offset
end

-- This function converts a local timestamp (e.g. from ImGui date input) to UTC for DB query
local function local_to_utc(local_timestamp)
    return local_timestamp + utc_offset
end

-- Gets current local time for plot limits
local function get_current_local_time()
    return os.time()
end


-- Old TrackXP table - REMOVE
-- local TrackXP       = {
--     PlayerLevel = mq.TLO.Me.Level() or 0,
--     PlayerAA = mq.TLO.Me.AAPointsTotal(),
--     StartTime = getTime(), -- Old getTime, now use get_current_local_time or direct os.time()

--     XPTotalPerLevel = OnEmu and 330 or 100000,
--     XPTotalDivider = OnEmu and 1 or 1000,

--     Experience = {
--         Base = OnEmu and ((mq.TLO.Me.Level() * 100) + mq.TLO.Me.PctExp()) or mq.TLO.Me.Exp(),
--         Total = 0,
--         Gained = 0,
--     },
--     AAExperience = {
--         Base = OnEmu and ((mq.TLO.Me.AAPointsTotal() * 100) + mq.TLO.Me.PctAAExp()) or mq.TLO.Me.AAExp(),
--         Total = 0,
--         Gained = 0,
--     },
-- }

local settings      = {}
local HorizonChanged      = false -- Keep for UI interaction

local DefaultConfig = {
    ['ExpSecondsToStore'] = MaxExpSecondsToStore, -- This will be settings.Horizon
    ['Horizon']           = ImGui_HorizonStep2,   -- Default live view duration
    ['ExpPlotFillLines']  = true,
    ['GraphMultiplier']   = 1,
}
settings = DefaultConfig
local multiplier    = tonumber(settings.GraphMultiplier) -- Keep for plot rendering

-- New state variables for UI
local selected_server_name = ""
local selected_character_name = ""
local available_profiles = {} -- table of {server="...", char="..."}
local profile_names_for_dropdown = {} -- table of "char@server"
local current_profile_index = 0 -- ImGui combo uses 0-based index in Lua

-- Historical View UI State
local historical_start_time_input = {year=os.date("*t").year, month=os.date("*t").month, day=os.date("*t").day, hour=0, min=0, sec=0}
local historical_end_time_input = {year=os.date("*t").year, month=os.date("*t").month, day=os.date("*t").day, hour=23, min=59, sec=59}
local historical_data_granularity = 60 -- Default to 1-min for historical, will be auto-adjusted
local view_mode = "live" -- "live" or "historical"
local historical_plot_start_time_epoch = 0 -- Store epoch time for plot limits
local historical_plot_end_time_epoch = 0   -- Store epoch time for plot limits

-- Buffers for plot data (will be populated from DB queries)
local XPEvents = {
    Exp = { expEvents = ScrollingPlotBuffer:new(math.ceil(2 * MaxHorizon)) }, -- TODO: Adjust size or handling based on DB data
    AA  = { expEvents = ScrollingPlotBuffer:new(math.ceil(2 * MaxHorizon)) }  -- TODO: Adjust size or handling based on DB data
}
-- ClearStats function - to be refactored or removed
-- For now, it might clear selected profile and plot data
local function ClearStats()
    -- TrackXP related reset is removed
    -- startXP, startLvl, etc. are removed
    if XPEvents.Exp and XPEvents.Exp.expEvents then XPEvents.Exp.expEvents:Clear() end
    if XPEvents.AA and XPEvents.AA.expEvents then XPEvents.AA.expEvents:Clear() end
    -- selected_server_name = "" -- Don't reset profile selection on "Reset Stats" for now
    -- selected_character_name = ""
    -- current_profile_index = 0
    if mq and mq.printf then mq.printf("\20XPTrackUI: \agPlot data cleared.") end
end

local function RenderShaded(type, currentDataBuffer, otherDataBuffer)
    -- This function expects currentData.expEvents to be a ScrollingPlotBuffer instance
    -- Or at least have DataX, DataY, Offset fields.
    -- Needs to be adapted if the structure of XPEvents changes significantly.
    if not currentDataBuffer or not currentDataBuffer.expEvents or not currentDataBuffer.expEvents.DataY then
        return
    end

    local count = #currentDataBuffer.expEvents.DataY
    if count == 0 then return end

    local otherY = {}
    if settings.ExpPlotFillLines then
        for idx = 1, count do
            otherY[idx] = 0
            if otherDataBuffer and otherDataBuffer.expEvents and otherDataBuffer.expEvents.DataY and otherDataBuffer.expEvents.DataY[idx] then
                if currentDataBuffer.expEvents.DataY[idx] >= otherDataBuffer.expEvents.DataY[idx] then
                    otherY[idx] = otherDataBuffer.expEvents.DataY[idx]
                end
            end
        end
        -- The offset in ScrollingPlotBuffer is 1-based for Lua arrays.
        ImPlot.PlotShaded(type, currentDataBuffer.expEvents.DataX, currentDataBuffer.expEvents.DataY, otherY, count,
            ImPlotShadedFlags.None, currentDataBuffer.expEvents.Offset -1)
    end

    ImPlot.PlotLine(type, currentDataBuffer.expEvents.DataX, currentDataBuffer.expEvents.DataY, count, ImPlotLineFlags.None,
        currentDataBuffer.expEvents.Offset -1)
end

local openGUI = true
local shouldDrawGUI = true

local function FormatTime(time_in_seconds, formatString)
    if not time_in_seconds or time_in_seconds < 0 then return "N/A" end
    local days = math.floor(time_in_seconds / 86400)
    local hours = math.floor((time_in_seconds % 86400) / 3600)
    local minutes = math.floor((time_in_seconds % 3600) / 60)
    local seconds = math.floor((time_in_seconds % 60))
    return string.format(formatString and formatString or "%d:%02d:%02d:%02d", days, hours, minutes, seconds)
end


-- --- Server/Character Selection ---
function get_profiles(db_conn)
    if not db_conn then return {} end
    local profiles = {}
    local distinct_profiles = {} -- To ensure uniqueness before adding to `profiles`
    local sql = "SELECT DISTINCT server_name, character_name FROM xp_data ORDER BY server_name, character_name;"
    local stmt, err = db_conn:prepare(sql)
    if not stmt then
        if mq and mq.printf then mq.printf("\20XPTrackUI: \arError preparing profiles query: %s", err or db_conn:errmsg()) end
        return profiles
    end

    for server, char in stmt:nrows() do
        local profile_key = string.format("%s@%s", char, server)
        if not distinct_profiles[profile_key] then
            table.insert(profiles, {server = server, char = char})
            distinct_profiles[profile_key] = true
        end
    end
    stmt:finalize()
    return profiles
end

local function refresh_available_profiles()
    if not db then return end
    available_profiles = get_profiles(db)
    profile_names_for_dropdown = {}
    for _, p in ipairs(available_profiles) do
        table.insert(profile_names_for_dropdown, string.format("%s @ %s", p.char, p.server))
    end
    -- If current selection is no longer valid, reset it
    local current_selection_valid = false
    for i, p_name in ipairs(profile_names_for_dropdown) do
        if selected_character_name ~= "" and selected_server_name ~= "" and p_name == string.format("%s @ %s", selected_character_name, selected_server_name) then
            current_profile_index = i -1 -- Adjust to 0-based for ImGui
            current_selection_valid = true
            break
        end
    end
    if not current_selection_valid then
        selected_character_name = ""
        selected_server_name = ""
        current_profile_index = 0
        if #available_profiles > 0 then -- Auto-select first profile if available
            selected_server_name = available_profiles[1].server
            selected_character_name = available_profiles[1].char
        end
    end
end

-- --- Data Fetching Functions ---
local live_data_last_fetch_time = 0
local live_data_fetch_interval = 10 -- seconds

function fetch_recent_data(db_conn, server, char, duration_seconds)
    if not db_conn or not server or server == "" or not char or char == "" then return {} end
    local results = {}
    -- Timestamps in DB are UTC. Plotting will convert them to local time.
    local start_utc_time = (get_current_local_time() - duration_seconds) + utc_offset -- Convert local start to UTC for query

    local sql = string.format(
        "SELECT timestamp, xp_gain, aa_xp_gain FROM xp_data WHERE server_name = '%s' AND character_name = '%s' AND granularity = 60 AND timestamp >= %d ORDER BY timestamp ASC;",
        server:gsub("'", "''"), -- basic SQL injection prevention
        char:gsub("'", "''"),   -- basic SQL injection prevention
        start_utc_time
    )

    local stmt, err = db_conn:prepare(sql)
    if not stmt then
        if mq and mq.printf then mq.printf("\20XPTrackUI: \arError preparing recent data query: %s", err or db_conn:errmsg()) end
        return results
    end

    for timestamp, xp_gain, aa_xp_gain in stmt:nrows() do
        table.insert(results, {timestamp = timestamp, xp_gain = xp_gain, aa_xp_gain = aa_xp_gain})
    end
    stmt:finalize()
    return results
end

function fetch_historical_data(db_conn, server, char, start_utc_timestamp, end_utc_timestamp)
    if not db_conn or not server or server == "" or not char or char == "" then return {}, 60 end

    local results = {}
    local query_granularity = 60
    local time_range_seconds = end_utc_timestamp - start_utc_timestamp

    if time_range_seconds <= 0 then return results, query_granularity end

    -- Choose granularity based on range
    if time_range_seconds > (14 * 24 * 60 * 60) then -- More than 14 days
        query_granularity = 3600 -- 1 hour
    elseif time_range_seconds > (2 * 24 * 60 * 60) then -- More than 2 days
        query_granularity = 1800 -- 30 minutes
    else -- Default to 1 minute for shorter ranges
        query_granularity = 60
    end

    local sql = string.format(
        "SELECT timestamp, xp_gain, aa_xp_gain, granularity FROM xp_data WHERE server_name = '%s' AND character_name = '%s' AND granularity = %d AND timestamp >= %d AND timestamp <= %d ORDER BY timestamp ASC;",
        server:gsub("'", "''"),
        char:gsub("'", "''"),
        query_granularity,
        start_utc_timestamp,
        end_utc_timestamp
    )

    local stmt, err = db_conn:prepare(sql)
    if not stmt then
        if mq and mq.printf then mq.printf("\20XPTrackUI: \arError preparing historical data query: %s", err or db_conn:errmsg()) end
        return results, query_granularity
    end
    for timestamp, xp_gain, aa_xp_gain, gran in stmt:nrows() do
        table.insert(results, {timestamp = timestamp, xp_gain = xp_gain, aa_xp_gain = aa_xp_gain, granularity = gran})
    end
    stmt:finalize()
    return results, query_granularity
end

local function update_plot_data(data_points, target_buffer, data_type)
    -- data_type can be "xp" or "aa"
    -- data_points is an array of {timestamp = UTC_ts, xp_gain = val, aa_xp_gain = val, granularity = (optional, from historical)}
    if not target_buffer or not target_buffer.expEvents then return end
    target_buffer.expEvents:Clear() -- Clear old data

    local max_y_val = 0

    for _, point in ipairs(data_points) do
        local y_value = 0
        local point_granularity = point.granularity or 60 -- Assume 60s if not specified (live data)

        if data_type == "xp" then
            y_value = (point.xp_gain or 0)
        elseif data_type == "aa" then
            y_value = (point.aa_xp_gain or 0)
        end

        -- Convert Y value to rate (per hour, matching old logic for display scaling)
        -- Old logic: XPPerSecond * 60 * 60 * multiplier
        -- New logic: (XP_gained_in_interval / interval_seconds) * 3600
        if point_granularity > 0 then
            y_value = (y_value / point_granularity) * 3600
        else
            y_value = 0 -- Avoid division by zero if granularity is bad
        end

        if data_type == "xp" then
             y_value = y_value * multiplier -- Apply multiplier only for regular XP
        end

        -- Timestamps from DB are UTC. Convert to local for plotting.
        target_buffer.expEvents:AddPoint(utc_to_local(point.timestamp), y_value, 0) -- Third param (total) not used from DB like this.

        if y_value > max_y_val then max_y_val = y_value end
    end
    return max_y_val
end

local current_plot_max_y = 100 -- Default, will be adjusted

local function DrawMainWindow()
    if not openGUI then return end
    openGUI, shouldDrawGUI = ImGui.Begin('xpTrack', openGUI)

    if shouldDrawGUI then
        -- Profile Selection
        if ImGui.Button("Refresh Profiles") or #available_profiles == 0 then
            refresh_available_profiles()
        end
        ImGui.SameLine()
        if #profile_names_for_dropdown > 0 then
            local selected_idx_before = current_profile_index
            current_profile_index = ImGui.Combo("Profile", current_profile_index, profile_names_for_dropdown)
            if selected_idx_before ~= current_profile_index or selected_character_name == "" then
                if available_profiles[current_profile_index + 1] then
                    selected_server_name = available_profiles[current_profile_index + 1].server
                    selected_character_name = available_profiles[current_profile_index + 1].char
                    live_data_last_fetch_time = 0 -- Force fetch for new profile
                    if mq and mq.printf then mq.printf("\20XPTrackUI: \agProfile selected: %s @ %s", selected_character_name, selected_server_name) end
                end
            end
        else
            ImGui.Text("No profiles found in database.")
        end

        ImGui.SameLine()
        if ImGui.Button("Reset Plot", ImGui.GetWindowWidth() * .3, 25) then -- Old "Reset Stats"
            ClearStats() -- Clears plot data
        end
        -- ImGui.SameLine()
        -- ImGui.TextColored(ImVec4(0, 1, 1, 1), "Current ") -- Current live MQ TLO PctExp/PctAAExp removed for now
        -- ImGui.SameLine()
        -- ImGui.TextColored(ImVec4(0.352, 0.970, 0.399, 1.000), "XP: %2.3f%%", mq.TLO.Me.PctExp())
        -- if mq.TLO.Me.Level() >= 51 then
        --     ImGui.SameLine()
        --     ImGui.TextColored(ImVec4(0.983, 0.729, 0.290, 1.000), "  AA XP: %2.3f%% ", mq.TLO.Me.PctAAExp())
        -- end

        if ImGui.CollapsingHeader("Exp Stats") then
            if ImGui.BeginTable("ExpStats", 2, bit32.bor(ImGuiTableFlags.Borders)) then
                -- This section needs complete rework based on what data we can show from DB
                ImGui.TableNextColumn(); ImGui.Text("Selected Profile:");
                ImGui.TableNextColumn(); ImGui.Text("%s @ %s", selected_character_name, selected_server_name)

                ImGui.TableNextColumn(); ImGui.Text("Data Window (Live):");
                ImGui.TableNextColumn(); ImGui.Text(FormatTime(settings.Horizon))

                -- Add more stats here if derived from fetched data later
                ImGui.EndTable()
            end
        end

        if ImGui.CollapsingHeader("XP Plot (Live/Historical)") then
            -- Fetch data for live view if profile selected and interval passed
            if selected_character_name ~= "" and selected_server_name ~= "" then
                 if get_current_local_time() - live_data_last_fetch_time > live_data_fetch_interval or HorizonChanged then
                    if db then
                        local recent_data = fetch_recent_data(db, selected_server_name, selected_character_name, settings.Horizon)
                        local max_xp_y = update_plot_data(recent_data, XPEvents.Exp, "xp")
                        local max_aa_y = update_plot_data(recent_data, XPEvents.AA, "aa")
                        current_plot_max_y = math.max(max_xp_y, max_aa_y, 100) -- Ensure a minimum plot height
                        GoalMaxExpPerSec = current_plot_max_y -- For dynamic Y axis scaling
                        live_data_last_fetch_time = get_current_local_time()
                        HorizonChanged = false
                        if mq and mq.printf then mq.printf("\20XPTrackUI: \agFetched %d points for live view.", #recent_data) end
                    else
                        if mq and mq.printf then mq.printf("\20XPTrackUI: \arDB not connected, cannot fetch live data.") end
                    end
                end
            end

            if ImPlot.BeginPlot("Experience Tracker") then
                ImPlot.SetupAxisScale(ImAxis.X1, ImPlotScale.Time)
                if multiplier == 1 then
                    ImPlot.SetupAxes("Local Time", "Exp/AA per Hour")
                else
                    ImPlot.SetupAxes("Local Time", string.format("Exp (x%s) / AA per Hour", multiplier))
                end

                -- Dynamic Y axis based on GoalMaxExpPerSec (calculated from fetched data)
                if CurMaxExpPerSec < GoalMaxExpPerSec then CurMaxExpPerSec = CurMaxExpPerSec + (GoalMaxExpPerSec - CurMaxExpPerSec) * 0.1 end
                if CurMaxExpPerSec > GoalMaxExpPerSec then CurMaxExpPerSec = CurMaxExpPerSec - (CurMaxExpPerSec - GoalMaxExpPerSec) * 0.1 end
                if math.abs(CurMaxExpPerSec - GoalMaxExpPerSec) < 1 then CurMaxExpPerSec = GoalMaxExpPerSec end

                local plot_start_time_to_use = get_current_local_time() - settings.Horizon
                local plot_end_time_to_use = get_current_local_time()

                if view_mode == "historical" and historical_plot_start_time_epoch > 0 and historical_plot_end_time_epoch > 0 then
                    plot_start_time_to_use = historical_plot_start_time_epoch
                    plot_end_time_to_use = historical_plot_end_time_epoch
                    if ImGui.Button("Switch to Live View") then
                        view_mode = "live"
                        live_data_last_fetch_time = 0 -- Force refresh live data
                    end
                    ImGui.SameLine() -- Keep button on same line if possible
                end

                ImPlot.SetupAxisLimits(ImAxis.X1, plot_start_time_to_use, plot_end_time_to_use, ImGuiCond.Always)
                ImPlot.SetupAxisLimits(ImAxis.Y1, 0, CurMaxExpPerSec > 0 and CurMaxExpPerSec or 100, ImGuiCond.Always)

                ImPlot.PushStyleVar(ImPlotStyleVar.FillAlpha, 0.35)
                RenderShaded("Exp", XPEvents.Exp, XPEvents.AA) -- RenderShaded expects .expEvents.DataX/Y/Offset
                RenderShaded("AA", XPEvents.AA, XPEvents.Exp)
                ImPlot.PopStyleVar()
                ImPlot.EndPlot()
            end
        end

        if ImGui.CollapsingHeader("Historical Data View") then
            ImGui.Text("Select Date and Time Range (Local Time)")
            -- Using InputInt for date/time components
            ImGui.InputInt("Year##Start", historical_start_time_input, "year") ImGui.SameLine()
            ImGui.InputInt("Mon##Start", historical_start_time_input, "month") ImGui.SameLine()
            ImGui.InputInt("Day##Start", historical_start_time_input, "day") ImGui.SameLine()
            ImGui.InputInt("Hr##Start", historical_start_time_input, "hour") ImGui.SameLine()
            ImGui.InputInt("Min##Start", historical_start_time_input, "min")

            ImGui.InputInt("Year##End", historical_end_time_input, "year") ImGui.SameLine()
            ImGui.InputInt("Mon##End", historical_end_time_input, "month") ImGui.SameLine()
            ImGui.InputInt("Day##End", historical_end_time_input, "day") ImGui.SameLine()
            ImGui.InputInt("Hr##End", historical_end_time_input, "hour") ImGui.SameLine()
            ImGui.InputInt("Min##End", historical_end_time_input, "min")

            if ImGui.Button("Fetch and Display Historical Data") then
                if selected_character_name ~= "" and selected_server_name ~= "" then
                    if db then
                        -- Convert input local times to UTC timestamps
                        local start_local_ts = os.time({
                            year=historical_start_time_input.year, month=historical_start_time_input.month, day=historical_start_time_input.day,
                            hour=historical_start_time_input.hour, min=historical_start_time_input.min, sec=0
                        })
                        local end_local_ts = os.time({
                            year=historical_end_time_input.year, month=historical_end_time_input.month, day=historical_end_time_input.day,
                            hour=historical_end_time_input.hour, min=historical_end_time_input.min, sec=59
                        })

                        if not start_local_ts or not end_local_ts then
                             if mq and mq.printf then mq.printf("\20XPTrackUI: \arInvalid date/time input for historical view.") end
                        else
                            local start_utc_ts = local_to_utc(start_local_ts)
                            local end_utc_ts = local_to_utc(end_local_ts)

                            if mq and mq.printf then mq.printf("\20XPTrackUI: \agFetching historical data from %s to %s UTC", os.date("%Y-%m-%d %H:%M",start_utc_ts), os.date("%Y-%m-%d %H:%M",end_utc_ts)) end

                            local historical_data, fetched_granularity = fetch_historical_data(db, selected_server_name, selected_character_name, start_utc_ts, end_utc_ts)
                            historical_data_granularity = fetched_granularity

                            local max_xp_y = update_plot_data(historical_data, XPEvents.Exp, "xp")
                            local max_aa_y = update_plot_data(historical_data, XPEvents.AA, "aa")
                            current_plot_max_y = math.max(max_xp_y, max_aa_y, 100)
                            GoalMaxExpPerSec = current_plot_max_y
                            
                            view_mode = "historical" -- Switch to historical view mode
                            historical_plot_start_time_epoch = start_local_ts -- Store for plot limits
                            historical_plot_end_time_epoch = end_local_ts   -- Store for plot limits

                            if mq and mq.printf then mq.printf("\20XPTrackUI: \agFetched %d historical points with granularity %d.", #historical_data, historical_data_granularity) end
                        end
                    else
                        if mq and mq.printf then mq.printf("\20XPTrackUI: \arDB not connected, cannot fetch historical data.") end
                    end
                else
                    if mq and mq.printf then mq.printf("\20XPTrackUI: \ayPlease select a profile first.") end
                end
            end
            ImGui.Text("Data will be plotted with granularity: %d seconds", historical_data_granularity)
        end


        if ImGui.CollapsingHeader("Config Options") then
            -- settings.ExpSecondsToStore, pressed = ImGui.SliderInt("Exp observation period",
            --     settings.ExpSecondsToStore, 60, MaxExpSecondsToStore, "%d s")
            -- if pressed then HorizonChanged = true end -- ExpSecondsToStore is now settings.Horizon

            local old_horizon = settings.Horizon
            settings.Horizon, pressed = ImGui.SliderInt("Live View Window (seconds)",
                settings.Horizon, ImGui_HorizonStep1, ImGui_HorizonStep4, "%d s")
            if pressed then
                if settings.Horizon < ImGui_HorizonStep2 then settings.Horizon = ImGui_HorizonStep1
                elseif settings.Horizon < ImGui_HorizonStep3 then settings.Horizon = ImGui_HorizonStep2
                elseif settings.Horizon < ImGui_HorizonStep4 then settings.Horizon = ImGui_HorizonStep3
                else settings.Horizon = ImGui_HorizonStep4
                end
                if old_horizon ~= settings.Horizon then HorizonChanged = true end
            end


            local old_multiplier = multiplier
            settings.GraphMultiplier, pressed = ImGui.SliderInt("Scaleup for regular XP",
                settings.GraphMultiplier, 1, 20, "%d x")
            if pressed then
                if settings.GraphMultiplier < 5 then settings.GraphMultiplier = 1
                elseif settings.GraphMultiplier < 15 then settings.GraphMultiplier = 10
                else settings.GraphMultiplier = 20
                end
                multiplier = tonumber(settings.GraphMultiplier)
                if old_multiplier ~= multiplier then
                    live_data_last_fetch_time = 0 -- Force refresh and recalculate Y values if multiplier changes
                end
            end
            settings.ExpPlotFillLines = ImGui.Checkbox("Shade Plot Lines", settings.ExpPlotFillLines)
        end
    end
    ImGui.Spacing()
    ImGui.End()
end

-- Old CheckExpChanged and CheckAAExpChanged functions (and Emu versions) are REMOVED
-- as data is now sourced from the database by xp_collector.lua

local function CommandHandler(...)
    local args = { ..., }
    if args[1] == "reset" then
        ClearStats() -- Now just clears plot
        if mq and mq.printf then mq.printf("\20XPTrackUI: \aoPlot Cleared.") end
    elseif args[1] == 'exit' then
        openGUI = false
        if db then db:close() end -- Close DB on exit
    end
end

mq.bind("/xptui", CommandHandler) -- Changed command to avoid conflict if old /xpt is used elsewhere
if mq and mq.printf then mq.printf("\20XPTrackUI: \aoCommand: \ay/xptui \aoArguments: \aw[\ayreset\aw|\ayexit\aw]") end

-- Old GiveTime() function - To be heavily refactored or removed.
-- Its role was to calculate XP/sec live and populate XPEvents.
-- Now, data comes from DB. The main loop will just handle UI updates.
local function SimplifiedGiveTime()
    -- This function is now mostly a placeholder or for very minimal periodic UI updates
    -- if not related to data fetching (which is handled in DrawMainWindow or by timers).

    -- The old logic for calculating XP rates and TTL/TTA is removed.
    -- Max Y value for plot (GoalMaxExpPerSec) is now updated when data is fetched.
    -- LastExtentsCheck logic might be adapted if dynamic plot scaling needs to be smoother.
    if get_current_local_time() - LastExtentsCheck > 0.5 then -- Keep this for smooth Y-axis transition
        LastExtentsCheck = get_current_local_time()
        -- Smoothly adjust CurMaxExpPerSec towards GoalMaxExpPerSec
        if CurMaxExpPerSec < GoalMaxExpPerSec then
            CurMaxExpPerSec = CurMaxExpPerSec + (GoalMaxExpPerSec - CurMaxExpPerSec) * 0.1
            if GoalMaxExpPerSec - CurMaxExpPerSec < 1 then CurMaxExpPerSec = GoalMaxExpPerSec end
        elseif CurMaxExpPerSec > GoalMaxExpPerSec then
            CurMaxExpPerSec = CurMaxExpPerSec - (CurMaxExpPerSec - GoalMaxExpPerSec) * 0.1
            if CurMaxExpPerSec - GoalMaxExpPerSec < 1 then CurMaxExpPerSec = GoalMaxExpPerSec end
        end
    end

    -- HorizonChanged flag processing (old logic) is mostly handled by re-fetching data.
    -- HorizonChanged = false -- Resetting here might be too aggressive if fetch fails.
end


mq.imgui.init('xptrackui', DrawMainWindow) -- Changed ImGui context name slightly
while openGUI do
    -- Try to connect to DB if not already connected (e.g. if script started before collector made the DB)
    if not db then
        if connect_and_init_db() then
            refresh_available_profiles() -- Refresh profiles if connection succeeds
        end
    end

    SimplifiedGiveTime() -- Call the simplified version
    mq.delay(100) -- Main loop delay
end

-- Cleanup on script end (if loop is broken by openGUI = false)
if db then
    db:close()
    if mq and mq.printf then mq.printf("\20XPTrackUI: \agDatabase connection closed.") end
end
