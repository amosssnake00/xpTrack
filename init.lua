-- Sample Performance Monitor Class Module
-- Refactored to use SQLite database for XP data storage and display.

-- To enable verbose logging for debugging, set DEBUG_MODE to true below,
-- or toggle it at runtime in the UI's "Config Options" section.
local DEBUG_MODE = false

local mq                   = require('mq')
local ImGui                = require('ImGui')
local ImPlot               = require('ImPlot')
local ScrollingPlotBuffer  = require('utils.scrolling_plot_buffer')
local db_utils             = require('db_utils') -- Added for database interaction

-- --- Debug Logging Helper ---
local function debug_log(message_supplier)
    if DEBUG_MODE then
        if mq and mq.printf then
            -- Using a neutral color for debug, can be changed. \ao is orange-ish.
            mq.printf("\20XPTrackUI DEBUG: \ao%s", message_supplier())
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
        if mq and mq.printf then
            mq.printf("\20XPTrackUI: \arFatal Error: Could not connect to database at %s.", db_path)
        else
            print("XPTrackUI: Fatal Error: Could not connect to database at " .. db_path .. ".")
        end
        debug_log(function() return "Database connection failed." end)
        return false
    end
    debug_log(function() return "Database connection successful." end)

    local ok, err_msg = db_utils.init_db(db) -- Ensures table exists
    if not ok then
        if mq and mq.printf then
            mq.printf("\20XPTrackUI: \arWarning: Could not initialize database: %s.", err_msg or "Unknown error")
        else
            print("XPTrackUI: Warning: Could not initialize database: " .. (err_msg or "Unknown error") .. ".")
        end
        debug_log(function() return "Database initialization warning/error: " .. (err_msg or "Unknown error") end)
        -- Continue anyway, as collector might create it.
    end
    if mq and mq.printf then
        mq.printf("\20XPTrackUI: \agDatabase connection successful for UI.")
    else
        print("XPTrackUI: Database connection successful for UI.")
    end
    debug_log(function() return "connect_and_init_db() finished." end)
    return true
end

-- Attempt to connect to DB on script start
if not connect_and_init_db() then
    mq.printf("\20XPTrackUI: \arDB connection failed. UI will be non-functional for data display.")
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

-- local debug                = false -- Replaced by DEBUG_MODE

-- timezone calcs
local utc_now_os_time      = os.time(os.date("!*t", os.time()))
local local_now_os_time    = os.time(os.date("*t", os.time()))
local utc_offset           = local_now_os_time - utc_now_os_time
if os.date("*t", os.time())["isdst"] then
    utc_offset = utc_offset + 3600
end
debug_log(function() return string.format("UTC offset calculated: %d seconds.", utc_offset) end)

local function utc_to_local(utc_timestamp)
    return utc_timestamp - utc_offset
end

local function local_to_utc(local_timestamp)
    return local_timestamp + utc_offset
end

local function get_current_local_time()
    return os.time()
end

local settings      = {}
local HorizonChanged      = false

local DefaultConfig = {
    ['ExpSecondsToStore'] = MaxExpSecondsToStore,
    ['Horizon']           = ImGui_HorizonStep2,
    ['ExpPlotFillLines']  = true,
    ['GraphMultiplier']   = 1,
}
settings = DefaultConfig
local multiplier    = tonumber(settings.GraphMultiplier)

local selected_server_name = ""
local selected_character_name = ""
local available_profiles = {}
local profile_names_for_dropdown = {}
local current_profile_index = 0

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
    if mq and mq.printf then mq.printf("\20XPTrackUI: \agPlot data cleared.") end
end

local function RenderShaded(type, currentDataBuffer, otherDataBuffer)
    if not currentDataBuffer or not currentDataBuffer.expEvents or not currentDataBuffer.expEvents.DataY then
        debug_log(function() return string.format("RenderShaded(%s): currentDataBuffer or its properties are nil. Skipping.", type) end)
        return
    end
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

function get_profiles(db_conn)
    debug_log(function() return "get_profiles() called." end)
    if not db_conn then
        debug_log(function() return "get_profiles: db_conn is nil." end)
        return {}
    end
    local profiles = {}
    local distinct_profiles = {}
    local sql = "SELECT DISTINCT server_name, character_name FROM xp_data ORDER BY server_name, character_name;"
    debug_log(function() return "get_profiles SQL: " .. sql end)
    local stmt, err = db_conn:prepare(sql)
    if not stmt then
        if mq and mq.printf then mq.printf("\20XPTrackUI: \arError preparing profiles query: %s", err or db_conn:errmsg()) end
        debug_log(function() return "get_profiles: Error preparing query: " .. (err or db_conn:errmsg()) end)
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
    debug_log(function() return string.format("get_profiles: Found %d profiles.", #profiles) end)
    return profiles
end

local function refresh_available_profiles()
    debug_log(function() return "refresh_available_profiles() called." end)
    if not db then
        debug_log(function() return "refresh_available_profiles: DB connection not available." end)
        return
    end
    available_profiles = get_profiles(db)
    profile_names_for_dropdown = {}
    for _, p in ipairs(available_profiles) do
        table.insert(profile_names_for_dropdown, string.format("%s @ %s", p.char, p.server))
    end
    local current_selection_valid = false
    for i, p_name in ipairs(profile_names_for_dropdown) do
        if selected_character_name ~= "" and selected_server_name ~= "" and p_name == string.format("%s @ %s", selected_character_name, selected_server_name) then
            current_profile_index = i -1
            current_selection_valid = true
            break
        end
    end
    if not current_selection_valid then
        debug_log(function() return "Current profile selection invalid or not set, attempting to reset." end)
        selected_character_name = ""
        selected_server_name = ""
        current_profile_index = 0
        if #available_profiles > 0 then
            selected_server_name = available_profiles[1].server
            selected_character_name = available_profiles[1].char
            debug_log(function() return string.format("Auto-selected first profile: %s @ %s", selected_character_name, selected_server_name) end)
        else
            debug_log(function() return "No profiles available to auto-select." end)
        end
    end
end

local live_data_last_fetch_time = 0
local live_data_fetch_interval = 10

function fetch_recent_data(db_conn, server, char, duration_seconds)
    debug_log(function() return string.format("fetch_recent_data: Server=%s, Char=%s, Duration=%d_sec", server, char, duration_seconds) end)
    if not db_conn or not server or server == "" or not char or char == "" then return {} end
    local results = {}
    local start_utc_time = (get_current_local_time() - duration_seconds) + utc_offset
    local sql = string.format(
        "SELECT timestamp, xp_gain, aa_xp_gain FROM xp_data WHERE server_name = '%s' AND character_name = '%s' AND granularity = 60 AND timestamp >= %d ORDER BY timestamp ASC;",
        server:gsub("'", "''"), char:gsub("'", "''"), start_utc_time
    )
    debug_log(function() return "fetch_recent_data SQL: " .. sql end)
    local stmt, err = db_conn:prepare(sql)
    if not stmt then
        if mq and mq.printf then mq.printf("\20XPTrackUI: \arError preparing recent data query: %s", err or db_conn:errmsg()) end
        debug_log(function() return "fetch_recent_data: Error preparing query: " .. (err or db_conn:errmsg()) end)
        return results
    end
    for timestamp, xp_gain, aa_xp_gain in stmt:nrows() do
        table.insert(results, {timestamp = timestamp, xp_gain = xp_gain, aa_xp_gain = aa_xp_gain})
    end
    stmt:finalize()
    debug_log(function() return string.format("fetch_recent_data: Fetched %d records.", #results) end)
    return results
end

function fetch_historical_data(db_conn, server, char, start_utc_timestamp, end_utc_timestamp)
    debug_log(function() return string.format("fetch_historical_data: Server=%s, Char=%s, StartUTC=%d, EndUTC=%d", server, char, start_utc_timestamp, end_utc_timestamp) end)
    if not db_conn or not server or server == "" or not char or char == "" then return {}, 60 end
    local results = {}
    local query_granularity = 60
    local time_range_seconds = end_utc_timestamp - start_utc_timestamp
    if time_range_seconds <= 0 then
        debug_log(function() return "fetch_historical_data: Time range is zero or negative." end)
        return results, query_granularity
    end
    if time_range_seconds > (14 * 24 * 60 * 60) then query_granularity = 3600
    elseif time_range_seconds > (2 * 24 * 60 * 60) then query_granularity = 1800
    else query_granularity = 60 end
    debug_log(function() return string.format("fetch_historical_data: Chosen granularity: %d seconds for time range %.2f days", query_granularity, time_range_seconds / (24*60*60)) end)
    local sql = string.format(
        "SELECT timestamp, xp_gain, aa_xp_gain, granularity FROM xp_data WHERE server_name = '%s' AND character_name = '%s' AND granularity = %d AND timestamp >= %d AND timestamp <= %d ORDER BY timestamp ASC;",
        server:gsub("'", "''"), char:gsub("'", "''"), query_granularity, start_utc_timestamp, end_utc_timestamp
    )
    debug_log(function() return "fetch_historical_data SQL: " .. sql end)
    local stmt, err = db_conn:prepare(sql)
    if not stmt then
        if mq and mq.printf then mq.printf("\20XPTrackUI: \arError preparing historical data query: %s", err or db_conn:errmsg()) end
        debug_log(function() return "fetch_historical_data: Error preparing query: " .. (err or db_conn:errmsg()) end)
        return results, query_granularity
    end
    for timestamp, xp_gain, aa_xp_gain, gran in stmt:nrows() do
        table.insert(results, {timestamp = timestamp, xp_gain = xp_gain, aa_xp_gain = aa_xp_gain, granularity = gran})
    end
    stmt:finalize()
    debug_log(function() return string.format("fetch_historical_data: Fetched %d records with granularity %d.", #results, query_granularity) end)
    return results, query_granularity
end

local function update_plot_data(data_points, target_buffer, data_type)
    debug_log(function() return string.format("update_plot_data for %s: %d data points received.", data_type, #data_points) end)
    if not target_buffer or not target_buffer.expEvents or type(target_buffer.expEvents.Clear) ~= "function" then
        if mq and mq.printf then
            mq.printf("\20XPTrackUI: \arWarning: Plot buffer for '%s' is invalid or lacks 'Clear' method. Attempting reinitialization.", data_type or "unknown")
        end
        debug_log(function() return string.format("Plot buffer for '%s' is invalid or lacks 'Clear'. Reinitializing.", data_type or "unknown") end)
        if target_buffer then
            local buffer_capacity = math.ceil(2 * MaxHorizon)
            target_buffer.expEvents = ScrollingPlotBuffer:new(buffer_capacity)
            if not target_buffer.expEvents or type(target_buffer.expEvents.Clear) ~= "function" then
                if mq and mq.printf then
                    mq.printf("\20XPTrackUI: \arError: Failed to reinitialize plot buffer for '%s'. Plotting for this type will be skipped.", data_type or "unknown")
                end
                debug_log(function() return string.format("Failed to reinitialize plot buffer for '%s'.", data_type or "unknown") end)
                return 0
            else
                if mq and mq.printf then
                    mq.printf("\20XPTrackUI: \agSuccessfully reinitialized plot buffer for '%s'.", data_type or "unknown")
                end
                debug_log(function() return string.format("Successfully reinitialized plot buffer for '%s'.", data_type or "unknown") end)
            end
        else
            if mq and mq.printf then
                mq.printf("\20XPTrackUI: \arCritical Error: target_buffer itself is nil for '%s'. Cannot create plot buffer.", data_type or "unknown")
            end
            debug_log(function() return string.format("Critical Error: target_buffer is nil for '%s'.", data_type or "unknown") end)
            return 0
        end
    end

    target_buffer.expEvents:Clear()
    debug_log(function() return string.format("Cleared plot buffer for %s.", data_type) end)
    local max_y_val = 0
    local points_added = 0

    for i, point in ipairs(data_points) do
        local y_value = 0
        local point_granularity = point.granularity or 60
        if data_type == "xp" then y_value = (point.xp_gain or 0)
        elseif data_type == "aa" then y_value = (point.aa_xp_gain or 0)
        end
        if point_granularity > 0 then y_value = (y_value / point_granularity) * 3600
        else y_value = 0 end
        if data_type == "xp" then y_value = y_value * multiplier end
        target_buffer.expEvents:AddPoint(utc_to_local(point.timestamp), y_value, 0)
        points_added = points_added + 1
        if y_value > max_y_val then max_y_val = y_value end
        if i <= 5 or i == #data_points then -- Log first few and last point for brevity
            debug_log(function() return string.format("Point %d for %s: TimestampUTC=%d (Local=%s), OriginalGain=%.2f, Granularity=%d, YValue(Rate/Hr)=%.2f", i, data_type, point.timestamp, os.date("%H:%M:%S", utc_to_local(point.timestamp)), (data_type == "xp" and point.xp_gain or point.aa_xp_gain), point_granularity, y_value) end)
        end
    end
    debug_log(function() return string.format("Added %d points to %s plot buffer. Max Y value: %.2f", points_added, data_type, max_y_val) end)
    return max_y_val
end

local current_plot_max_y = 100

local function DrawMainWindow()
    if not openGUI then return end
    openGUI, shouldDrawGUI = ImGui.Begin('xpTrack', openGUI)

    if shouldDrawGUI then
        if ImGui.Button("Refresh Profiles") or #available_profiles == 0 then
            debug_log(function() return "Refresh Profiles button clicked or no profiles loaded." end)
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
                    live_data_last_fetch_time = 0
                    if mq and mq.printf then mq.printf("\20XPTrackUI: \agProfile selected: %s @ %s", selected_character_name, selected_server_name) end
                    debug_log(function() return string.format("Profile changed to: %s @ %s", selected_character_name, selected_server_name) end)
                end
            end
        else
            ImGui.Text("No profiles found in database.")
        end
        ImGui.SameLine()
        if ImGui.Button("Reset Plot", ImGui.GetWindowWidth() * .3, 25) then
            debug_log(function() return "Reset Plot button clicked." end)
            ClearStats()
        end

        if ImGui.CollapsingHeader("Exp Stats") then
            if ImGui.BeginTable("ExpStats", 2, bit32.bor(ImGuiTableFlags.Borders)) then
                ImGui.TableNextColumn(); ImGui.Text("Selected Profile:");
                ImGui.TableNextColumn(); ImGui.Text("%s @ %s", selected_character_name, selected_server_name)
                ImGui.TableNextColumn(); ImGui.Text("Data Window (Live):");
                ImGui.TableNextColumn(); ImGui.Text(FormatTime(settings.Horizon))
                ImGui.EndTable()
            end
        end

        if ImGui.CollapsingHeader("XP Plot (Live/Historical)") then
            if selected_character_name ~= "" and selected_server_name ~= "" then
                 if get_current_local_time() - live_data_last_fetch_time > live_data_fetch_interval or HorizonChanged then
                    debug_log(function() return string.format("Fetching live data. Reason: Interval met (%s) or HorizonChanged (%s)", get_current_local_time() - live_data_last_fetch_time > live_data_fetch_interval, HorizonChanged) end)
                    if db then
                        local recent_data = fetch_recent_data(db, selected_server_name, selected_character_name, settings.Horizon)
                        local max_xp_y = update_plot_data(recent_data, XPEvents.Exp, "xp")
                        local max_aa_y = update_plot_data(recent_data, XPEvents.AA, "aa")
                        current_plot_max_y = math.max(max_xp_y, max_aa_y, 100)
                        GoalMaxExpPerSec = current_plot_max_y
                        live_data_last_fetch_time = get_current_local_time()
                        HorizonChanged = false
                        if mq and mq.printf then mq.printf("\20XPTrackUI: \agFetched %d points for live view.", #recent_data) end
                    else
                        if mq and mq.printf then mq.printf("\20XPTrackUI: \arDB not connected, cannot fetch live data.") end
                        debug_log(function() return "Cannot fetch live data, DB not connected." end)
                    end
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
                    if ImGui.Button("Switch to Live View") then
                        debug_log(function() return "Switch to Live View button clicked." end)
                        view_mode = "live"
                        live_data_last_fetch_time = 0
                    end
                    ImGui.SameLine()
                end
                debug_log(function() return string.format("Plot Axis X: %s to %s (Mode: %s). Y Max: %.2f", os.date("%c",plot_start_time_to_use), os.date("%c",plot_end_time_to_use), view_mode, CurMaxExpPerSec) end)
                ImPlot.SetupAxisLimits(ImAxis.X1, plot_start_time_to_use, plot_end_time_to_use, ImGuiCond.Always)
                ImPlot.SetupAxisLimits(ImAxis.Y1, 0, CurMaxExpPerSec > 0 and CurMaxExpPerSec or 100, ImGuiCond.Always)
                ImPlot.PushStyleVar(ImPlotStyleVar.FillAlpha, 0.35)
                RenderShaded("Exp", XPEvents.Exp, XPEvents.AA)
                RenderShaded("AA", XPEvents.AA, XPEvents.Exp)
                ImPlot.PopStyleVar()
                ImPlot.EndPlot()
            end
        end

        if ImGui.CollapsingHeader("Historical Data View") then
            ImGui.Text("Select Date and Time Range (Local Time)")
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
                debug_log(function() return string.format("Fetch Historical Data button clicked. Range: %04d-%02d-%02d %02d:%02d to %04d-%02d-%02d %02d:%02d", historical_start_time_input.year, historical_start_time_input.month, historical_start_time_input.day, historical_start_time_input.hour, historical_start_time_input.min, historical_end_time_input.year, historical_end_time_input.month, historical_end_time_input.day, historical_end_time_input.hour, historical_end_time_input.min) end)
                if selected_character_name ~= "" and selected_server_name ~= "" then
                    if db then
                        local start_local_ts = os.time({ year=historical_start_time_input.year, month=historical_start_time_input.month, day=historical_start_time_input.day, hour=historical_start_time_input.hour, min=historical_start_time_input.min, sec=0 })
                        local end_local_ts = os.time({ year=historical_end_time_input.year, month=historical_end_time_input.month, day=historical_end_time_input.day, hour=historical_end_time_input.hour, min=historical_end_time_input.min, sec=59 })
                        if not start_local_ts or not end_local_ts then
                             if mq and mq.printf then mq.printf("\20XPTrackUI: \arInvalid date/time input for historical view.") end
                             debug_log(function() return "Invalid date/time input for historical view." end)
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
                            view_mode = "historical"
                            historical_plot_start_time_epoch = start_local_ts
                            historical_plot_end_time_epoch = end_local_ts
                            if mq and mq.printf then mq.printf("\20XPTrackUI: \agFetched %d historical points with granularity %d.", #historical_data, historical_data_granularity) end
                        end
                    else
                        if mq and mq.printf then mq.printf("\20XPTrackUI: \arDB not connected, cannot fetch historical data.") end
                        debug_log(function() return "Cannot fetch historical data, DB not connected." end)
                    end
                else
                    if mq and mq.printf then mq.printf("\20XPTrackUI: \ayPlease select a profile first.") end
                    debug_log(function() return "Fetch historical data: No profile selected." end)
                end
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
                if old_horizon ~= settings.Horizon then
                    HorizonChanged = true
                    debug_log(function() return string.format("Live View Window changed to: %d seconds.", settings.Horizon) end)
                end
            end

            local old_multiplier = multiplier
            settings.GraphMultiplier, pressed = ImGui.SliderInt("Scaleup for regular XP", settings.GraphMultiplier, 1, 20, "%d x")
            if pressed then
                if settings.GraphMultiplier < 5 then settings.GraphMultiplier = 1
                elseif settings.GraphMultiplier < 15 then settings.GraphMultiplier = 10
                else settings.GraphMultiplier = 20 end
                multiplier = tonumber(settings.GraphMultiplier)
                if old_multiplier ~= multiplier then
                    live_data_last_fetch_time = 0
                    debug_log(function() return string.format("Graph Multiplier changed to: %d.", multiplier) end)
                end
            end
            settings.ExpPlotFillLines = ImGui.Checkbox("Shade Plot Lines", settings.ExpPlotFillLines)
            ImGui.SameLine()
            local debug_toggled
            DEBUG_MODE, debug_toggled = ImGui.Checkbox("Enable Debug Logging", DEBUG_MODE)
            if debug_toggled then
                if mq and mq.printf then mq.printf("\20XPTrackUI: \ayDebug Logging %s.", DEBUG_MODE and "ENABLED" or "DISABLED") end
                debug_log(function() return string.format("Debug mode toggled via UI to: %s", DEBUG_MODE and "ON" or "OFF") end)
            end
        end
    end
    ImGui.Spacing()
    ImGui.End()
end

local function CommandHandler(...)
    local args = { ..., }
    if args[1] == "reset" then
        ClearStats()
        if mq and mq.printf then mq.printf("\20XPTrackUI: \aoPlot Cleared.") end
    elseif args[1] == 'exit' then
        openGUI = false
        if db then db:close() end
    end
end

mq.bind("/xptui", CommandHandler)
if mq and mq.printf then mq.printf("\20XPTrackUI: \aoCommand: \ay/xptui \aoArguments: \aw[\ayreset\aw|\ayexit\aw]") end
debug_log(function() return "/xptui command bound." end)

local function SimplifiedGiveTime()
    if get_current_local_time() - LastExtentsCheck > 0.5 then
        LastExtentsCheck = get_current_local_time()
        if CurMaxExpPerSec < GoalMaxExpPerSec then
            CurMaxExpPerSec = CurMaxExpPerSec + (GoalMaxExpPerSec - CurMaxExpPerSec) * 0.1
            if GoalMaxExpPerSec - CurMaxExpPerSec < 1 then CurMaxExpPerSec = GoalMaxExpPerSec end
        elseif CurMaxExpPerSec > GoalMaxExpPerSec then
            CurMaxExpPerSec = CurMaxExpPerSec - (CurMaxExpPerSec - GoalMaxExpPerSec) * 0.1
            if CurMaxExpPerSec - GoalMaxExpPerSec < 1 then CurMaxExpPerSec = GoalMaxExpPerSec end
        end
    end
end

mq.imgui.init('xptrackui', DrawMainWindow)
debug_log(function() return "ImGui initialized for xptrackui. Starting main loop. DEBUG_MODE is " .. (DEBUG_MODE and "ON" or "OFF") end)

while openGUI do
    if not db then
        debug_log(function() return "Main loop: DB not connected. Attempting to connect." end)
        if connect_and_init_db() then
            debug_log(function() return "Main loop: DB reconnected. Refreshing profiles." end)
            refresh_available_profiles()
        else
            debug_log(function() return "Main loop: DB reconnection failed." end)
        end
    end
    SimplifiedGiveTime()
    mq.delay(100)
end

if db then
    db:close()
    if mq and mq.printf then mq.printf("\20XPTrackUI: \agDatabase connection closed.") end
    debug_log(function() return "Script ending. Database connection closed." end)
end
