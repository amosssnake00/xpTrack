-- Sample Performance Monitor Class Module
-- Refactored to use SQLite database for XP data storage and display,
-- now using per-profile tables.

-- To enable verbose logging for debugging, set DEBUG_MODE to true below,
-- or toggle it at runtime in the UI's "Config Options" section.
local DEBUG_MODE = false

local mq                   = require('mq')
local ImGui                = require('ImGui')
local ImPlot               = require('ImPlot')
local ScrollingPlotBuffer  = require('utils.scrolling_plot_buffer')
local db_utils             = require('db_utils') -- db_utils now handles per-profile tables

-- --- Debug Logging Helper ---
local function debug_log(message_supplier)
    if DEBUG_MODE then
        if mq and printf then
            printf("\20XPTrackUI DEBUG: \ao%s", message_supplier())
        else
            print("XPTrackUI DEBUG: " .. message_supplier())
        end
    end
end

-- Database Path (should match xp_collector.lua)
local db_path = "xp_data.sqlite"
local db -- Database connection object

-- --- Database Initialization ---
local function connect_and_init_db()
    debug_log(function() return "connect_and_init_db() called. DB path: " .. db_path end)
    db = db_utils.get_db_connection(db_path)
    if not db then
        if mq and printf then printf("\20XPTrackUI: \arFatal Error: Could not connect to database at %s.", db_path)
        else print("XPTrackUI: Fatal Error: Could not connect to database at " .. db_path .. ".") end
        return false
    end
    debug_log(function() return "Database connection successful." end)
    -- No longer call db_utils.init_db() here, as table initialization is profile-specific
    -- and handled by the collector for its own profile. The UI just reads.
    if mq and printf then printf("\20XPTrackUI: \agDatabase connection successful for UI.")
    else print("XPTrackUI: Database connection successful for UI.") end
    return true
end

if not connect_and_init_db() then
    printf("\20XPTrackUI: \arDB connection failed. UI will be non-functional for data display.")
end

local MaxStep              = 50
local CurMaxExpPerSec      = 0
local GoalMaxExpPerSec     = 0
local LastExtentsCheck     = 0
local MaxExpSecondsToStore = 3600
local MaxHorizon           = 3600
local ImGui_HorizonStep1   = 1 * 60
local ImGui_HorizonStep2   = 5 * 60
local ImGui_HorizonStep3   = 30 * 60
local ImGui_HorizonStep4   = 60 * 60

local utc_now_os_time      = os.time(os.date("!*t", os.time()))
local local_now_os_time    = os.time(os.date("*t", os.time()))
local utc_offset           = local_now_os_time - utc_now_os_time
if os.date("*t", os.time())["isdst"] then utc_offset = utc_offset + 3600 end
debug_log(function() return string.format("UTC offset calculated: %d seconds.", utc_offset) end)

local function utc_to_local(utc_timestamp) return utc_timestamp - utc_offset end
local function local_to_utc(local_timestamp) return local_timestamp + utc_offset end
local function get_current_local_time() return os.time() end

local settings      = {}
local HorizonChanged      = false
local DefaultConfig = {
    ['Horizon']           = ImGui_HorizonStep2,
    ['ExpPlotFillLines']  = true,
    ['GraphMultiplier']   = 1,
}
settings = DefaultConfig
local multiplier    = tonumber(settings.GraphMultiplier)

-- UI State for Profile Selection
local selected_server_name = ""
local selected_character_name = ""
local selected_table_name = nil -- Store the actual table name for the selected profile
local available_profiles_info = {} -- Stores {server="...", character="...", table_name="..."} from db_utils
local profile_display_names = {} -- For ImGui combo box
local current_profile_index = 0

-- Historical View UI State
local historical_start_time_input = {year=os.date("*t").year, month=os.date("*t").month, day=os.date("*t").day, hour=0, min=0, sec=0}
local historical_end_time_input = {year=os.date("*t").year, month=os.date("*t").month, day=os.date("*t").day, hour=23, min=59, sec=59}
local historical_data_granularity = 60
local view_mode = "live"
local historical_plot_start_time_epoch = 0
local historical_plot_end_time_epoch = 0

local XPEvents = {
    Exp = { expEvents = ScrollingPlotBuffer:new(math.ceil(2 * MaxHorizon)) },
    AA  = { expEvents = ScrollingPlotBuffer:new(math.ceil(2 * MaxHorizon)) }
}

local function ClearStats()
    debug_log(function() return "ClearStats() called." end)
    if XPEvents.Exp and XPEvents.Exp.expEvents then XPEvents.Exp.expEvents:Clear() end
    if XPEvents.AA and XPEvents.AA.expEvents then XPEvents.AA.expEvents:Clear() end
    if mq and printf then printf("\20XPTrackUI: \agPlot data cleared.") end
end

local function RenderShaded(type, currentDataBuffer, otherDataBuffer)
    if not currentDataBuffer or not currentDataBuffer.expEvents or not currentDataBuffer.expEvents.DataY then return end
    local count = #currentDataBuffer.expEvents.DataY
    if count == 0 then return end
    debug_log(function() return string.format("RenderShaded(%s): Rendering %d points. Offset: %d", type, count, currentDataBuffer.expEvents.Offset -1) end)
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
        ImPlot.PlotShaded(type, currentDataBuffer.expEvents.DataX, currentDataBuffer.expEvents.DataY, otherY, count, ImPlotShadedFlags.None, currentDataBuffer.expEvents.Offset -1)
    end
    ImPlot.PlotLine(type, currentDataBuffer.expEvents.DataX, currentDataBuffer.expEvents.DataY, count, ImPlotLineFlags.None, currentDataBuffer.expEvents.Offset -1)
end

local openGUI = true
local shouldDrawGUI = true

local function FormatTime(time_in_seconds, formatString)
    if not time_in_seconds or time_in_seconds < 0 then return "N/A" end
    local days = math.floor(time_in_seconds / 86400); local hours = math.floor((time_in_seconds % 86400) / 3600)
    local minutes = math.floor((time_in_seconds % 3600) / 60); local seconds = math.floor((time_in_seconds % 60))
    return string.format(formatString and formatString or "%d:%02d:%02d:%02d", days, hours, minutes, seconds)
end

-- --- Server/Character Profile Management ---
local function refresh_available_profiles()
    debug_log(function() return "refresh_available_profiles() called." end)
    if not db then debug_log(function() return "refresh_available_profiles: DB connection not available." end); return end
    
    available_profiles_info = db_utils.list_profile_tables(db) -- This now returns {server, character, table_name}
    profile_display_names = {}
    for _, p_info in ipairs(available_profiles_info) do
        -- Using original (potentially sanitized) names for display as that's what user would recognize.
        table.insert(profile_display_names, string.format("%s @ %s", p_info.character, p_info.server))
    end
    debug_log(function() return string.format("Found %d profiles. Display names generated.", #available_profiles_info) end)

    local current_selection_valid = false
    if selected_table_name then -- Check if current selected_table_name is still in the list
        for i, p_info in ipairs(available_profiles_info) do
            if p_info.table_name == selected_table_name then
                current_profile_index = i - 1 -- 0-based for ImGui
                selected_server_name = p_info.server
                selected_character_name = p_info.character
                current_selection_valid = true
                break
            end
        end
    end

    if not current_selection_valid then
        debug_log(function() return "Current profile selection invalid or not set, attempting to reset." end)
        if #available_profiles_info > 0 then
            current_profile_index = 0
            selected_server_name = available_profiles_info[1].server
            selected_character_name = available_profiles_info[1].character
            selected_table_name = available_profiles_info[1].table_name
            debug_log(function() return string.format("Auto-selected first profile: %s @ %s (Table: %s)", selected_character_name, selected_server_name, selected_table_name) end)
        else
            selected_server_name = ""; selected_character_name = ""; selected_table_name = nil; current_profile_index = 0
            debug_log(function() return "No profiles available to auto-select." end)
        end
    end
end

-- --- Data Fetching Functions (Now use selected_table_name) ---
local live_data_last_fetch_time = 0
local live_data_fetch_interval = 10

function fetch_recent_data(db_conn, table_to_query, duration_seconds)
    debug_log(function() return string.format("fetch_recent_data: Table=%s, Duration=%d_sec", table_to_query, duration_seconds) end)
    if not db_conn or not table_to_query then return {} end
    local results = {}
    local start_utc_time = (get_current_local_time() - duration_seconds) + utc_offset
    -- Query now uses dynamic table name and no longer filters by server/character in WHERE
    local sql = string.format(
        "SELECT timestamp, xp_gain, aa_xp_gain FROM %s WHERE granularity = 60 AND timestamp >= %d ORDER BY timestamp ASC;",
        table_to_query, start_utc_time
    )
    debug_log(function() return "fetch_recent_data SQL: " .. sql end)
    local stmt, err = db_conn:prepare(sql)
    if not stmt then
        if mq and printf then printf("\20XPTrackUI: \arError preparing recent data query for %s: %s", table_to_query, err or db_conn:errmsg()) end
        return results
    end
    for row in stmt:nrows() do
        table.insert(results, {timestamp = row.timestamp, xp_gain = row.xp_gain, aa_xp_gain = row.aa_xp_gain})
    end
    stmt:finalize()
    debug_log(function() return string.format("fetch_recent_data for %s: Fetched %d records.", table_to_query, #results) end)
    return results
end

function fetch_historical_data(db_conn, table_to_query, start_utc_timestamp, end_utc_timestamp)
    debug_log(function() return string.format("fetch_historical_data: Table=%s, StartUTC=%d, EndUTC=%d", table_to_query, start_utc_timestamp, end_utc_timestamp) end)
    if not db_conn or not table_to_query then return {}, 60 end
    local results = {}
    local query_granularity = 60
    local time_range_seconds = end_utc_timestamp - start_utc_timestamp
    if time_range_seconds <= 0 then return results, query_granularity end

    if time_range_seconds > (14 * 24 * 60 * 60) then query_granularity = 3600
    elseif time_range_seconds > (2 * 24 * 60 * 60) then query_granularity = 1800
    else query_granularity = 60 end
    debug_log(function() return string.format("fetch_historical_data for %s: Chosen granularity: %d seconds", table_to_query, query_granularity) end)
    -- Query now uses dynamic table name
    local sql = string.format(
        "SELECT timestamp, xp_gain, aa_xp_gain, granularity FROM %s WHERE granularity = %d AND timestamp >= %d AND timestamp <= %d ORDER BY timestamp ASC;",
        table_to_query, query_granularity, start_utc_timestamp, end_utc_timestamp
    )
    debug_log(function() return "fetch_historical_data SQL: " .. sql end)
    local stmt, err = db_conn:prepare(sql)
    if not stmt then
        if mq and printf then printf("\20XPTrackUI: \arError preparing historical data query for %s: %s", table_to_query, err or db_conn:errmsg()) end
        return results, query_granularity
    end
    for row in stmt:nrows() do
        table.insert(results, {timestamp = row.timestamp, xp_gain = row.xp_gain, aa_xp_gain = row.aa_xp_gain, granularity = row.granularity})
    end
    stmt:finalize()
    debug_log(function() return string.format("fetch_historical_data for %s: Fetched %d records with granularity %d.", table_to_query, #results, query_granularity) end)
    return results, query_granularity
end

local function update_plot_data(data_points, target_buffer, data_type)
    debug_log(function() return string.format("update_plot_data for %s: %d data points received.", data_type, #data_points) end)
    if not target_buffer or not target_buffer.expEvents or type(target_buffer.expEvents.Clear) ~= "function" then
        if mq and printf then printf("\20XPTrackUI: \arWarning: Plot buffer for '%s' invalid. Reinitializing.", data_type or "unknown") end
        if target_buffer then
            local buffer_capacity = math.ceil(2 * MaxHorizon)
            target_buffer.expEvents = ScrollingPlotBuffer:new(buffer_capacity)
            if not target_buffer.expEvents or type(target_buffer.expEvents.Clear) ~= "function" then
                if mq and printf then printf("\20XPTrackUI: \arError: Failed to reinitialize plot buffer for '%s'.", data_type or "unknown") end
                return 0
            else if mq and printf then printf("\20XPTrackUI: \agReinitialized plot buffer for '%s'.", data_type or "unknown") end end
        else if mq and printf then printf("\20XPTrackUI: \arCritical Error: target_buffer nil for '%s'.", data_type or "unknown") end; return 0 end
    end
    target_buffer.expEvents:Clear()
    local max_y_val = 0; local points_added = 0
    for i, point in ipairs(data_points) do
        local y_value = 0; local point_granularity = point.granularity or 60
        if data_type == "xp" then y_value = (point.xp_gain or 0) elseif data_type == "aa" then y_value = (point.aa_xp_gain or 0) end
        if point_granularity > 0 then y_value = (y_value / point_granularity) * 3600 else y_value = 0 end
        if data_type == "xp" then y_value = y_value * multiplier end
        target_buffer.expEvents:AddPoint(utc_to_local(point.timestamp), y_value, 0)
        points_added = points_added + 1
        if y_value > max_y_val then max_y_val = y_value end
    end
    debug_log(function() return string.format("Added %d points to %s plot buffer. Max Y value: %.2f", points_added, data_type, max_y_val) end)
    return max_y_val
end

local current_plot_max_y = 100

local function DrawMainWindow()
    if not openGUI then return end
    openGUI, shouldDrawGUI = ImGui.Begin('xpTrack', openGUI)

    if shouldDrawGUI then
        if ImGui.Button("Refresh Profiles") or #available_profiles_info == 0 then
            debug_log(function() return "Refresh Profiles button clicked or no profiles loaded." end)
            refresh_available_profiles()
        end
        ImGui.SameLine()
        if #profile_display_names > 0 then
            local selected_idx_before = current_profile_index
            current_profile_index = ImGui.Combo("Profile", current_profile_index, profile_display_names)
            if selected_idx_before ~= current_profile_index or not selected_table_name then
                if available_profiles_info[current_profile_index + 1] then
                    selected_server_name = available_profiles_info[current_profile_index + 1].server
                    selected_character_name = available_profiles_info[current_profile_index + 1].character
                    selected_table_name = available_profiles_info[current_profile_index + 1].table_name -- Store the table name
                    live_data_last_fetch_time = 0
                    if mq and printf then printf("\20XPTrackUI: \agProfile selected: %s @ %s (Table: %s)", selected_character_name, selected_server_name, selected_table_name) end
                    debug_log(function() return string.format("Profile changed to: %s @ %s (Table: %s)", selected_character_name, selected_server_name, selected_table_name) end)
                end
            end
        else ImGui.Text("No profiles found in database.") end
        ImGui.SameLine()
        if ImGui.Button("Reset Plot", ImGui.GetWindowWidth() * .3, 25) then ClearStats() end

        if ImGui.CollapsingHeader("Exp Stats") then
            if ImGui.BeginTable("ExpStats", 2, bit32.bor(ImGuiTableFlags.Borders)) then
                ImGui.TableNextColumn(); ImGui.Text("Selected Profile:");
                ImGui.TableNextColumn(); ImGui.Text("%s @ %s", selected_character_name, selected_server_name)
                ImGui.TableNextColumn(); ImGui.Text("Table Name:");
                ImGui.TableNextColumn(); ImGui.Text("%s", selected_table_name or "N/A")
                ImGui.TableNextColumn(); ImGui.Text("Data Window (Live):");
                ImGui.TableNextColumn(); ImGui.Text(FormatTime(settings.Horizon))
                ImGui.EndTable()
            end
        end

        if ImGui.CollapsingHeader("XP Plot (Live/Historical)") then
            if selected_table_name then -- Check if a table is selected
                 if get_current_local_time() - live_data_last_fetch_time > live_data_fetch_interval or HorizonChanged then
                    debug_log(function() return string.format("Fetching live data for %s. Reason: Interval met or HorizonChanged", selected_table_name) end)
                    if db then
                        local recent_data = fetch_recent_data(db, selected_table_name, settings.Horizon)
                        local max_xp_y = update_plot_data(recent_data, XPEvents.Exp, "xp")
                        local max_aa_y = update_plot_data(recent_data, XPEvents.AA, "aa")
                        current_plot_max_y = math.max(max_xp_y, max_aa_y, 100)
                        GoalMaxExpPerSec = current_plot_max_y
                        live_data_last_fetch_time = get_current_local_time(); HorizonChanged = false
                        if mq and printf then printf("\20XPTrackUI: \agFetched %d points for live view for %s.", #recent_data, selected_table_name) end
                    else if mq and printf then printf("\20XPTrackUI: \arDB not connected.") end end
                end
            end

            if ImPlot.BeginPlot("Experience Tracker") then
                ImPlot.SetupAxisScale(ImAxis.X1, ImPlotScale.Time)
                if multiplier == 1 then ImPlot.SetupAxes("Local Time", "Exp/AA per Hour")
                else ImPlot.SetupAxes("Local Time", string.format("Exp (x%s) / AA per Hour", multiplier)) end
                if CurMaxExpPerSec < GoalMaxExpPerSec then CurMaxExpPerSec = CurMaxExpPerSec + (GoalMaxExpPerSec - CurMaxExpPerSec) * 0.1 end
                if CurMaxExpPerSec > GoalMaxExpPerSec then CurMaxExpPerSec = CurMaxExpPerSec - (CurMaxExpPerSec - GoalMaxExpPerSec) * 0.1 end
                if math.abs(CurMaxExpPerSec - GoalMaxExpPerSec) < 1 then CurMaxExpPerSec = GoalMaxExpPerSec end
                local plot_start_time_to_use = get_current_local_time() - settings.Horizon
                local plot_end_time_to_use = get_current_local_time()
                if view_mode == "historical" and historical_plot_start_time_epoch > 0 and historical_plot_end_time_epoch > 0 then
                    plot_start_time_to_use = historical_plot_start_time_epoch
                    plot_end_time_to_use = historical_plot_end_time_epoch
                    if ImGui.Button("Switch to Live View") then view_mode = "live"; live_data_last_fetch_time = 0 end
                    ImGui.SameLine()
                end
                ImPlot.SetupAxisLimits(ImAxis.X1, plot_start_time_to_use, plot_end_time_to_use, ImGuiCond.Always)
                ImPlot.SetupAxisLimits(ImAxis.Y1, 0, CurMaxExpPerSec > 0 and CurMaxExpPerSec or 100, ImGuiCond.Always)
                ImPlot.PushStyleVar(ImPlotStyleVar.FillAlpha, 0.35)
                RenderShaded("Exp", XPEvents.Exp, XPEvents.AA); RenderShaded("AA", XPEvents.AA, XPEvents.Exp)
                ImPlot.PopStyleVar(); ImPlot.EndPlot()
            end
        end

        if ImGui.CollapsingHeader("Historical Data View") then
            ImGui.Text("Select Date and Time Range (Local Time)")
            ImGui.InputInt("Year##Start", historical_start_time_input, "year"); ImGui.SameLine(); ImGui.InputInt("Mon##Start", historical_start_time_input, "month"); ImGui.SameLine()
            ImGui.InputInt("Day##Start", historical_start_time_input, "day"); ImGui.SameLine(); ImGui.InputInt("Hr##Start", historical_start_time_input, "hour"); ImGui.SameLine()
            ImGui.InputInt("Min##Start", historical_start_time_input, "min")
            ImGui.InputInt("Year##End", historical_end_time_input, "year"); ImGui.SameLine(); ImGui.InputInt("Mon##End", historical_end_time_input, "month"); ImGui.SameLine()
            ImGui.InputInt("Day##End", historical_end_time_input, "day"); ImGui.SameLine(); ImGui.InputInt("Hr##End", historical_end_time_input, "hour"); ImGui.SameLine()
            ImGui.InputInt("Min##End", historical_end_time_input, "min")

            if ImGui.Button("Fetch and Display Historical Data") then
                if selected_table_name then -- Check if a table is selected
                    if db then
                        local start_local_ts = os.time({ year=historical_start_time_input.year, month=historical_start_time_input.month, day=historical_start_time_input.day, hour=historical_start_time_input.hour, min=historical_start_time_input.min, sec=0 })
                        local end_local_ts = os.time({ year=historical_end_time_input.year, month=historical_end_time_input.month, day=historical_end_time_input.day, hour=historical_end_time_input.hour, min=historical_end_time_input.min, sec=59 })
                        if not start_local_ts or not end_local_ts then if mq and printf then printf("\20XPTrackUI: \arInvalid date/time input.") end
                        else
                            local start_utc_ts = local_to_utc(start_local_ts); local end_utc_ts = local_to_utc(end_local_ts)
                            if mq and printf then printf("\20XPTrackUI: \agFetching historical data for %s from %s to %s UTC", selected_table_name, os.date("%Y-%m-%d %H:%M",start_utc_ts), os.date("%Y-%m-%d %H:%M",end_utc_ts)) end
                            local historical_data, fetched_granularity = fetch_historical_data(db, selected_table_name, start_utc_ts, end_utc_ts)
                            historical_data_granularity = fetched_granularity
                            local max_xp_y = update_plot_data(historical_data, XPEvents.Exp, "xp"); local max_aa_y = update_plot_data(historical_data, XPEvents.AA, "aa")
                            current_plot_max_y = math.max(max_xp_y, max_aa_y, 100); GoalMaxExpPerSec = current_plot_max_y
                            view_mode = "historical"; historical_plot_start_time_epoch = start_local_ts; historical_plot_end_time_epoch = end_local_ts
                            if mq and printf then printf("\20XPTrackUI: \agFetched %d historical points for %s with granularity %d.", #historical_data, selected_table_name, historical_data_granularity) end
                        end
                    else if mq and printf then printf("\20XPTrackUI: \arDB not connected.") end end
                else if mq and printf then printf("\20XPTrackUI: \ayPlease select a profile first.") end end
            end
            ImGui.Text("Data will be plotted with granularity: %d seconds", historical_data_granularity)
        end

        if ImGui.CollapsingHeader("Config Options") then
            local old_horizon = settings.Horizon
            settings.Horizon, pressed = ImGui.SliderInt("Live View Window (seconds)", settings.Horizon, ImGui_HorizonStep1, ImGui_HorizonStep4, "%d s")
            if pressed then
                if settings.Horizon < ImGui_HorizonStep2 then settings.Horizon = ImGui_HorizonStep1
                elseif settings.Horizon < ImGui_HorizonStep3 then settings.Horizon = ImGui_HorizonStep2
                elseif settings.Horizon < ImGui_HorizonStep4 then settings.Horizon = ImGui_HorizonStep3
                else settings.Horizon = ImGui_HorizonStep4 end
                if old_horizon ~= settings.Horizon then HorizonChanged = true; debug_log(function() return string.format("Live View Window to: %d s.", settings.Horizon) end) end
            end
            local old_multiplier = multiplier
            settings.GraphMultiplier, pressed = ImGui.SliderInt("Scaleup for regular XP", settings.GraphMultiplier, 1, 20, "%d x")
            if pressed then
                if settings.GraphMultiplier < 5 then settings.GraphMultiplier = 1
                elseif settings.GraphMultiplier < 15 then settings.GraphMultiplier = 10
                else settings.GraphMultiplier = 20 end
                multiplier = tonumber(settings.GraphMultiplier)
                if old_multiplier ~= multiplier then live_data_last_fetch_time = 0; debug_log(function() return string.format("Graph Multiplier to: %d.", multiplier) end) end
            end
            settings.ExpPlotFillLines = ImGui.Checkbox("Shade Plot Lines", settings.ExpPlotFillLines)
            ImGui.SameLine()
            local debug_toggled; DEBUG_MODE, debug_toggled = ImGui.Checkbox("Enable Debug Logging", DEBUG_MODE)
            if debug_toggled then if mq and printf then printf("\20XPTrackUI: \ayDebug Logging %s.", DEBUG_MODE and "ENABLED" or "DISABLED") end end
        end
    end
    ImGui.Spacing(); ImGui.End()
end

local function CommandHandler(...)
    local args = { ... }; if args[1] == "reset" then ClearStats(); if mq and printf then printf("\20XPTrackUI: \aoPlot Cleared.") end
    elseif args[1] == 'exit' then openGUI = false; if db then db:close() end end
end
mq.bind("/xptui", CommandHandler)
if mq and printf then printf("\20XPTrackUI: \aoCommand: \ay/xptui \aoArguments: \aw[\ayreset\aw|\ayexit\aw]") end

local function SimplifiedGiveTime()
    if get_current_local_time() - LastExtentsCheck > 0.5 then
        LastExtentsCheck = get_current_local_time()
        if CurMaxExpPerSec < GoalMaxExpPerSec then CurMaxExpPerSec = CurMaxExpPerSec + (GoalMaxExpPerSec - CurMaxExpPerSec) * 0.1
            if GoalMaxExpPerSec - CurMaxExpPerSec < 1 then CurMaxExpPerSec = GoalMaxExpPerSec end
        elseif CurMaxExpPerSec > GoalMaxExpPerSec then CurMaxExpPerSec = CurMaxExpPerSec - (CurMaxExpPerSec - GoalMaxExpPerSec) * 0.1
            if CurMaxExpPerSec - GoalMaxExpPerSec < 1 then CurMaxExpPerSec = GoalMaxExpPerSec end
        end
    end
end

mq.imgui.init('xptrackui', DrawMainWindow)
debug_log(function() return "ImGui initialized. Main loop starting. DEBUG_MODE: " .. (DEBUG_MODE and "ON" or "OFF") end)

while openGUI do
    if not db then
        if connect_and_init_db() then refresh_available_profiles() end
    end
    SimplifiedGiveTime(); mq.delay(100)
end

if db then db:close(); if mq and printf then printf("\20XPTrackUI: \agDatabase connection closed.") end end
