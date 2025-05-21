-- xp_collector.lua
-- Collects XP and AA XP data and stores it in an SQLite database.
-- Also includes aggregation logic to roll up data to 30-minute and 1-hour intervals.

-- To enable verbose logging for debugging, set DEBUG_MODE to true below.
local DEBUG_MODE = false

--[[
  Development Note:
  This script is intended to run within a MacroQuest (MQ) environment.
  Features like `mq.TLO`, `mq.delay`, `mq.bind`, `mq.printf` are specific to MQ.
  If running outside MQ, these will need to be stubbed or replaced.
  The TLO paths for server and character name are based on common MQ usage but might need verification.
]]

-- Require necessary modules
local mq = require('mq') -- Presumed to be available in the MQ environment
local db_utils = require('db_utils') -- From the previously created file
local sqlite3 = require('lsqlite3') -- For sqlite3.OK

-- --- Debug Logging Helper ---
local function debug_log(message_supplier)
    if DEBUG_MODE then
        if mq and mq.printf then
            mq.printf("\20XPTracker DEBUG: \ao%s", message_supplier())
        else
            print("XPTracker DEBUG: " .. message_supplier())
        end
    end
end

-- --- Configuration ---
local db_path = "xp_data.sqlite" -- Path to the SQLite database file
local collection_interval_seconds = 1 -- How often to check for XP changes
local aggregation_granularity_seconds = 60 -- How often to write to DB (1-minute data)

local thirty_min_aggregation_interval_seconds = 1800 -- 30 minutes
local one_hour_aggregation_interval_seconds = 3600   -- 1 hour

local aggregation_run_frequency_seconds = 3600 -- How often to attempt to run aggregation tasks (e.g., every hour)

-- --- Database Initialization ---
debug_log(function() return "Attempting database connection to: " .. db_path end)
local db = db_utils.get_db_connection(db_path)
if not db then
  if mq and mq.printf then
    mq.printf("\20XPTracker: \arFatal Error: Could not connect to database at %s. Exiting.", db_path)
  else
    print("XPTracker: Fatal Error: Could not connect to database at " .. db_path .. ". Exiting.")
  end
  return -- Stop script execution if DB connection fails
end
debug_log(function() return "Database connection successful." end)

debug_log(function() return "Attempting database initialization." end)
local ok, err_msg = db_utils.init_db(db)
if not ok then
  if mq and mq.printf then
    mq.printf("\20XPTracker: \arFatal Error: Could not initialize database: %s. Exiting.", err_msg or "Unknown error")
  else
    print("XPTracker: FatalError: Could not initialize database: " .. (err_msg or "Unknown error") .. ". Exiting.")
  end
  db:close()
  return
end
debug_log(function() return "Database initialization successful." end)

if mq and mq.printf then
  mq.printf("\20XPTracker: \agDatabase initialized successfully at %s", db_path)
else
  print("XPTracker: Database initialized successfully at " .. db_path)
end

-- --- UTC Offset Calculation ---
local utc_now_os = os.time(os.date("!*t", os.time()))
local local_now_os = os.time(os.date("*t", os.time()))
local utc_offset = local_now_os - utc_now_os
if os.date("*t", os.time())["isdst"] then
  utc_offset = utc_offset + 3600
end
debug_log(function() return string.format("UTC offset calculated: %d seconds.", utc_offset) end)

local function get_current_utc_timestamp()
  return os.time() + utc_offset
end

-- --- Logging Helper (for non-debug messages) ---
local function log_message(level, message)
    local color_prefix = ""
    if level == "info" then color_prefix = "\ag" -- green
    elseif level == "warn" then color_prefix = "\ay" -- yellow
    elseif level == "error" then color_prefix = "\ar" -- red
    end

    if mq and mq.printf then
        mq.printf("\20XPTracker: %s%s", color_prefix, message)
    else
        print(string.format("XPTracker: [%s] %s", string.upper(level), message))
    end
end

-- --- Server and Character Information ---
local function get_server_name()
  if mq and mq.TLO and mq.TLO.EverQuest and mq.TLO.EverQuest.Server then
    local server = mq.TLO.EverQuest.Server()
    local final_server = server and #server > 0 and server or "UnknownServer"
    debug_log(function() return "get_server_name() returning: " .. final_server end)
    return final_server
  end
  log_message("warn", "mq.TLO.EverQuest.Server() not available. Using 'UnknownServer'.")
  debug_log(function() return "get_server_name() TLO not available, returning 'UnknownServer'." end)
  return "UnknownServer"
end

local function get_character_name()
  if mq and mq.TLO and mq.TLO.Me and mq.TLO.Me.Name then
    local charName = mq.TLO.Me.Name()
    local final_charName = charName and #charName > 0 and charName or "UnknownCharacter"
    debug_log(function() return "get_character_name() returning: " .. final_charName end)
    return final_charName
  end
  log_message("warn", "mq.TLO.Me.Name() not available. Using 'UnknownCharacter'.")
  debug_log(function() return "get_character_name() TLO not available, returning 'UnknownCharacter'." end)
  return "UnknownCharacter"
end

-- --- XP/AA Tracking Logic ---
local TrackXP = {
    Experience = {Base = 0, Gained = 0, Last = 0, Time = os.time()},
    AAExperience = {Base = 0, Gained = 0, Last = 0, Time = os.time()},
    Initialized = false,
    Paused = false
}
local XPTotalPerLevel = {} -- Example, replace with actuals
local XPTotalDivider = 330

local function InitializeXPTrackers()
    debug_log(function() return "InitializeXPTrackers() called." end)
    if mq and mq.TLO and mq.TLO.Me and mq.TLO.Me.PctExp and mq.TLO.Me.PctAAExp then
        TrackXP.Experience.Base = mq.TLO.Me.PctExp()
        TrackXP.AAExperience.Base = mq.TLO.Me.PctAAExp()
        TrackXP.Initialized = true
        log_message("info", string.format("XP and AA XP trackers initialized. Current XP: %.3f%%, Current AA XP: %.3f%%", TrackXP.Experience.Base, TrackXP.AAExperience.Base))
        debug_log(function() return string.format("Trackers Initialized. Base XP: %.3f, Base AA: %.3f", TrackXP.Experience.Base, TrackXP.AAExperience.Base) end)
    else
        log_message("warn", "Could not initialize XP trackers. MQ TLOs for PctExp/PctAAExp not available.")
        TrackXP.Experience.Base = 0
        TrackXP.AAExperience.Base = 0
        TrackXP.Initialized = false
        debug_log(function() return "Failed to initialize trackers due to unavailable TLOs." end)
    end
end

local function CheckExpChanged()
    if not TrackXP.Initialized or TrackXP.Paused or not (mq and mq.TLO and mq.TLO.Me and mq.TLO.Me.PctExp and mq.TLO.Me.Level and mq.TLO.Me.MaxExp) then
        debug_log(function() return "CheckExpChanged() skipped: Not initialized, paused, or TLOs missing." end)
        return 0
    end
    local currentExp = mq.TLO.Me.PctExp()
    local gained = 0
    if currentExp < TrackXP.Experience.Base then -- Level up or delevel
        local currentLevel = mq.TLO.Me.Level()
        local prevLevel = currentLevel > 1 and currentLevel -1 or currentLevel
        local totalForPrevLevel = XPTotalPerLevel[prevLevel] or (mq.TLO.Me.MaxExp() / XPTotalDivider)
        gained = totalForPrevLevel * ( (100 - TrackXP.Experience.Base) / 100) + (totalForPrevLevel * (currentExp / 100))
        debug_log(function() return string.format("XP Level up/delevel detected. OldBase: %.3f, NewPct: %.3f, Gained: %.3f", TrackXP.Experience.Base, currentExp, gained) end)
    elseif currentExp > TrackXP.Experience.Base then
        gained = currentExp - TrackXP.Experience.Base
        debug_log(function() return string.format("XP Gain detected. OldBase: %.3f, NewPct: %.3f, Gained: %.3f", TrackXP.Experience.Base, currentExp, gained) end)
    end

    if gained > 0 then
        TrackXP.Experience.Gained = TrackXP.Experience.Gained + gained
        TrackXP.Experience.Last = gained
        TrackXP.Experience.Time = get_current_utc_timestamp()
        TrackXP.Experience.Base = currentExp
        return gained
    end
    return 0
end

local function CheckAAExpChanged()
    if not TrackXP.Initialized or TrackXP.Paused or not (mq and mq.TLO and mq.TLO.Me and mq.TLO.Me.PctAAExp) then
        debug_log(function() return "CheckAAExpChanged() skipped: Not initialized, paused, or TLOs missing." end)
        return 0
    end
    local currentAAExp = mq.TLO.Me.PctAAExp()
    local gained = 0
    if currentAAExp < TrackXP.AAExperience.Base then
        gained = (100 - TrackXP.AAExperience.Base) + currentAAExp
        debug_log(function() return string.format("AA XP wrap-around (point earned) detected. OldBase: %.3f, NewPct: %.3f, Gained: %.3f", TrackXP.AAExperience.Base, currentAAExp, gained) end)
    elseif currentAAExp > TrackXP.AAExperience.Base then
        gained = currentAAExp - TrackXP.AAExperience.Base
        debug_log(function() return string.format("AA XP Gain detected. OldBase: %.3f, NewPct: %.3f, Gained: %.3f", TrackXP.AAExperience.Base, currentAAExp, gained) end)
    end

    if gained > 0 then
        TrackXP.AAExperience.Gained = TrackXP.AAExperience.Gained + gained
        TrackXP.AAExperience.Last = gained
        TrackXP.AAExperience.Time = get_current_utc_timestamp()
        TrackXP.AAExperience.Base = currentAAExp
        return gained
    end
    return 0
end

-- --- Aggregation Functions ---
local function execute_sql_in_transaction(db_conn, sql_statements)
    debug_log(function() return "execute_sql_in_transaction called with " .. #sql_statements .. " statements." end)
    local status, err = pcall(function()
        local exec_err = db_conn:exec("BEGIN TRANSACTION;")
        if exec_err ~= sqlite3.OK then
            error("Failed to begin transaction: " .. db_conn:errmsg())
        end
        debug_log(function() return "Transaction begun." end)

        for i, sql in ipairs(sql_statements) do
            debug_log(function() return "Executing SQL (" .. i .. "/" .. #sql_statements .. "): " .. sql end)
            exec_err = db_conn:exec(sql)
            if exec_err ~= sqlite3.OK then
                error(string.format("SQL error: %s (Query: %s)", db_conn:errmsg(), sql))
            end
        end

        exec_err = db_conn:exec("COMMIT;")
        if exec_err ~= sqlite3.OK then
            error("Failed to commit transaction: " .. db_conn:errmsg())
        end
        debug_log(function() return "Transaction committed." end)
    end)
    if not status then
        debug_log(function() return "Transaction failed: " .. (err or "Unknown error") .. ". Attempting rollback." end)
        pcall(function() db_conn:exec("ROLLBACK;") end)
        return false, err
    end
    return true
end

function aggregate_to_30_min(db_conn)
    log_message("info", "Starting 30-minute aggregation process.")
    debug_log(function() return "aggregate_to_30_min() called." end)
    local twenty_four_hours_ago = get_current_utc_timestamp() - (24 * 60 * 60)
    local source_granularity = 60
    local target_granularity = 1800 -- 30 minutes

    local query_sql = string.format([[
        SELECT
            CAST(timestamp / %d AS INTEGER) * %d AS interval_start,
            server_name,
            character_name,
            SUM(xp_gain) AS total_xp,
            SUM(aa_xp_gain) AS total_aa_xp,
            COUNT(id) AS num_records_to_aggregate
        FROM xp_data
        WHERE granularity = %d AND timestamp < %d
        GROUP BY server_name, character_name, interval_start
        HAVING SUM(xp_gain) > 0 OR SUM(aa_xp_gain) > 0;
    ]], target_granularity, target_granularity, source_granularity, twenty_four_hours_ago)
    debug_log(function() return "30-min aggregation SELECT SQL: " .. query_sql end)

    local aggregated_count = 0
    local deleted_count = 0
    local total_rows_queried = 0

    local stmt, err_msg_prepare = db_conn:prepare(query_sql)
    if not stmt then
        log_message("error", string.format("Failed to prepare 30-min aggregation query: %s", err_msg_prepare or db_conn:errmsg()))
        debug_log(function() return "Failed to prepare 30-min aggregation query: " .. (err_msg_prepare or db_conn:errmsg()) end)
        return
    end

    for interval_start, server_name, character_name, total_xp, total_aa_xp, num_recs in stmt:nrows() do
        total_rows_queried = total_rows_queried + 1
        debug_log(function() return string.format("Processing aggregation group: IntervalStart=%d, Server=%s, Char=%s, XP=%.2f, AA_XP=%.2f, NumRecs=%d", interval_start, server_name, character_name, total_xp, total_aa_xp, num_recs) end)
        local transaction_statements = {}
        table.insert(transaction_statements, string.format(
            "INSERT INTO xp_data (timestamp, server_name, character_name, xp_gain, aa_xp_gain, granularity) VALUES (%d, '%s', '%s', %f, %f, %d);",
            interval_start, server_name:gsub("'", "''"), character_name:gsub("'", "''"), total_xp, total_aa_xp, target_granularity
        ))
        local interval_end = interval_start + target_granularity -1
        table.insert(transaction_statements, string.format(
            "DELETE FROM xp_data WHERE granularity = %d AND server_name = '%s' AND character_name = '%s' AND timestamp >= %d AND timestamp <= %d AND timestamp < %d;",
            source_granularity, server_name:gsub("'", "''"), character_name:gsub("'", "''"), interval_start, interval_end, twenty_four_hours_ago
        ))
        
        local success, err = execute_sql_in_transaction(db_conn, transaction_statements)
        if success then
            aggregated_count = aggregated_count + 1
            deleted_count = deleted_count + num_recs
            log_message("info", string.format("Aggregated 1-min data to 30-min for %s on %s at %s. %d source records processed.", character_name, server_name, os.date("%Y-%m-%d %H:%M:%S", interval_start), num_recs))
        else
            log_message("error", string.format("Failed to aggregate 30-min data for %s at %s: %s", character_name, os.date("%Y-%m-%d %H:%M:%S", interval_start), err))
            debug_log(function() return string.format("Aggregation transaction failed for %s at %s: %s", character_name, os.date("%Y-%m-%d %H:%M:%S", interval_start), err) end)
        end
    end
    stmt:finalize()
    debug_log(function() return string.format("30-min aggregation query processed %d groups.", total_rows_queried) end)
    log_message("info", string.format("30-minute aggregation complete. %d new records created, approx %d source records deleted.", aggregated_count, deleted_count))
    debug_log(function() return "aggregate_to_30_min() finished." end)
end

function aggregate_to_1_hour(db_conn)
    log_message("info", "Starting 1-hour aggregation process.")
    debug_log(function() return "aggregate_to_1_hour() called." end)
    local seven_days_ago = get_current_utc_timestamp() - (7 * 24 * 60 * 60)
    local source_granularity = 1800 -- 30 minutes
    local target_granularity = 3600 -- 1 hour

    local query_sql = string.format([[
        SELECT
            CAST(timestamp / %d AS INTEGER) * %d AS interval_start,
            server_name,
            character_name,
            SUM(xp_gain) AS total_xp,
            SUM(aa_xp_gain) AS total_aa_xp,
            COUNT(id) AS num_records_to_aggregate
        FROM xp_data
        WHERE granularity = %d AND timestamp < %d
        GROUP BY server_name, character_name, interval_start
        HAVING SUM(xp_gain) > 0 OR SUM(aa_xp_gain) > 0;
    ]], target_granularity, target_granularity, source_granularity, seven_days_ago)
    debug_log(function() return "1-hour aggregation SELECT SQL: " .. query_sql end)

    local aggregated_count = 0
    local deleted_count = 0
    local total_rows_queried = 0
    
    local stmt, err_msg_prepare = db_conn:prepare(query_sql)
    if not stmt then
        log_message("error", string.format("Failed to prepare 1-hour aggregation query: %s", err_msg_prepare or db_conn:errmsg()))
        debug_log(function() return "Failed to prepare 1-hour aggregation query: " .. (err_msg_prepare or db_conn:errmsg()) end)
        return
    end

    for interval_start, server_name, character_name, total_xp, total_aa_xp, num_recs in stmt:nrows() do
        total_rows_queried = total_rows_queried + 1
        debug_log(function() return string.format("Processing aggregation group: IntervalStart=%d, Server=%s, Char=%s, XP=%.2f, AA_XP=%.2f, NumRecs=%d", interval_start, server_name, character_name, total_xp, total_aa_xp, num_recs) end)
        local transaction_statements = {}
        table.insert(transaction_statements, string.format(
            "INSERT INTO xp_data (timestamp, server_name, character_name, xp_gain, aa_xp_gain, granularity) VALUES (%d, '%s', '%s', %f, %f, %d);",
            interval_start, server_name:gsub("'", "''"), character_name:gsub("'", "''"), total_xp, total_aa_xp, target_granularity
        ))
        local interval_end = interval_start + target_granularity -1
        table.insert(transaction_statements, string.format(
            "DELETE FROM xp_data WHERE granularity = %d AND server_name = '%s' AND character_name = '%s' AND timestamp >= %d AND timestamp <= %d AND timestamp < %d;",
            source_granularity, server_name:gsub("'", "''"), character_name:gsub("'", "''"), interval_start, interval_end, seven_days_ago
        ))

        local success, err = execute_sql_in_transaction(db_conn, transaction_statements)
        if success then
            aggregated_count = aggregated_count + 1
            deleted_count = deleted_count + num_recs
            log_message("info", string.format("Aggregated 30-min data to 1-hour for %s on %s at %s. %d source records processed.", character_name, server_name, os.date("%Y-%m-%d %H:%M:%S", interval_start), num_recs))
        else
            log_message("error", string.format("Failed to aggregate 1-hour data for %s at %s: %s", character_name, os.date("%Y-%m-%d %H:%M:%S", interval_start), err))
            debug_log(function() return string.format("Aggregation transaction failed for %s at %s: %s", character_name, os.date("%Y-%m-%d %H:%M:%S", interval_start), err) end)
        end
    end
    stmt:finalize()
    debug_log(function() return string.format("1-hour aggregation query processed %d groups.", total_rows_queried) end)
    log_message("info", string.format("1-hour aggregation complete. %d new records created, approx %d source records deleted.", aggregated_count, deleted_count))
    debug_log(function() return "aggregate_to_1_hour() finished." end)
end

-- --- Main Data Collection Variables ---
local current_minute_start_time = math.floor(get_current_utc_timestamp() / aggregation_granularity_seconds) * aggregation_granularity_seconds
local current_minute_xp_gain = 0
local current_minute_aa_xp_gain = 0
local last_aggregation_run_time = 0

-- --- Main Loop ---
log_message("info", string.format("Starting main collection loop. Interval: %d sec, DB Aggregation: %d sec. DEBUG_MODE is %s", collection_interval_seconds, aggregation_granularity_seconds, DEBUG_MODE and "ON" or "OFF"))

while true do
    debug_log(function() return "Main loop iteration started. Timestamp: " .. get_current_utc_timestamp() end)
    if mq and mq.TLO and mq.TLO.EverQuest and mq.TLO.EverQuest.GameState then
        local gameState = mq.TLO.EverQuest.GameState()
        debug_log(function() return "Current GameState: " .. (gameState or "nil") end)
        if gameState == "INGAME" then
            if not TrackXP.Initialized then
                InitializeXPTrackers()
            end
            TrackXP.Paused = false

            if TrackXP.Initialized then
                local xp_gained_this_cycle = CheckExpChanged()
                local aa_xp_gained_this_cycle = CheckAAExpChanged()

                if xp_gained_this_cycle > 0 then
                    current_minute_xp_gain = current_minute_xp_gain + xp_gained_this_cycle
                    debug_log(function() return string.format("XP Gained This Cycle: %.3f%%. Total for current minute: %.3f%%", xp_gained_this_cycle, current_minute_xp_gain) end)
                end

                if aa_xp_gained_this_cycle > 0 then
                    current_minute_aa_xp_gain = current_minute_aa_xp_gain + aa_xp_gained_this_cycle
                    debug_log(function() return string.format("AA XP Gained This Cycle: %.3f%%. Total for current minute: %.3f%%", aa_xp_gained_this_cycle, current_minute_aa_xp_gain) end)
                end
            end
        else -- Not INGAME
            if TrackXP.Initialized then
                log_message("warn", "Not in game. Pausing XP tracking until back in game.")
                debug_log(function() return "Not INGAME. Pausing tracking." end)
                TrackXP.Initialized = false
                TrackXP.Paused = true
            end
        end
    else
        log_message("warn", "MQ TLO for GameState not available. Cannot determine if in game. Tracking will be effectively paused.")
        debug_log(function() return "GameState TLO not available. Pausing tracking." end)
        TrackXP.Paused = true
    end

    local current_timestamp_loop = get_current_utc_timestamp()
    if current_timestamp_loop >= current_minute_start_time + aggregation_granularity_seconds then
        debug_log(function() return string.format("Minute rollover detected. Current TS: %d, Minute Start TS: %d", current_timestamp_loop, current_minute_start_time) end)
        if (current_minute_xp_gain > 0 or current_minute_aa_xp_gain > 0) and not TrackXP.Paused and TrackXP.Initialized then
            local server_name = get_server_name()
            local character_name = get_character_name()
            debug_log(function() return string.format("Preparing to insert data: Server=%s, Char=%s, XP=%.2f, AA_XP=%.2f, Granularity=%d, Timestamp=%d", server_name, character_name, current_minute_xp_gain, current_minute_aa_xp_gain, aggregation_granularity_seconds, current_minute_start_time) end)

            local insert_sql = string.format(
                "INSERT INTO xp_data (timestamp, server_name, character_name, xp_gain, aa_xp_gain, granularity) VALUES (%d, '%s', '%s', %f, %f, %d);",
                current_minute_start_time, server_name:gsub("'", "''"), character_name:gsub("'", "''"), current_minute_xp_gain, current_minute_aa_xp_gain, aggregation_granularity_seconds
            )
            debug_log(function() return "Insert SQL: " .. insert_sql end)

            local exec_ok, exec_err = pcall(function()
                local err_code = db:exec(insert_sql)
                if err_code ~= sqlite3.OK then error(db:errmsg()) end
            end)

            if not exec_ok then
                log_message("error", string.format("Error inserting 1-min data into database: %s (SQL: %s)", exec_err, insert_sql))
                debug_log(function() return string.format("DB Insert Error: %s", exec_err) end)
            else
                log_message("info", string.format("Data for minute starting %s inserted. XP: %.3f, AA_XP: %.3f", os.date("%Y-%m-%d %H:%M:%S", current_minute_start_time), current_minute_xp_gain, current_minute_aa_xp_gain))
                debug_log(function() return "Data insertion successful." end)
            end
        else
            debug_log(function() return "No XP/AA gain this minute, or tracking paused/uninitialized. No data inserted." end)
        end

        current_minute_xp_gain = 0
        current_minute_aa_xp_gain = 0
        current_minute_start_time = math.floor(current_timestamp_loop / aggregation_granularity_seconds) * aggregation_granularity_seconds
        debug_log(function() return "Minute accumulators reset. New minute_start_time: " .. current_minute_start_time end)
        
        if current_timestamp_loop - last_aggregation_run_time >= aggregation_run_frequency_seconds then
            log_message("info", "Attempting scheduled aggregation tasks.")
            debug_log(function() return "Aggregation run frequency met. Starting aggregation tasks." end)
            local agg_30_success, agg_30_err = pcall(aggregate_to_30_min, db)
            if not agg_30_success then
                log_message("error", string.format("Error during 30-minute aggregation: %s", agg_30_err))
                debug_log(function() return string.format("30-min aggregation pcall failed: %s", agg_30_err) end)
            end

            local agg_1hr_success, agg_1hr_err = pcall(aggregate_to_1_hour, db)
            if not agg_1hr_success then
                log_message("error", string.format("Error during 1-hour aggregation: %s", agg_1hr_err))
                debug_log(function() return string.format("1-hour aggregation pcall failed: %s", agg_1hr_err) end)
            end
            last_aggregation_run_time = current_timestamp_loop
            debug_log(function() return "Aggregation tasks finished. last_aggregation_run_time updated to: " .. last_aggregation_run_time end)
        end
    end

    if mq and mq.delay then
        mq.delay(collection_interval_seconds * 1000)
    else
        local wait_until = os.time() + collection_interval_seconds
        while os.time() < wait_until do end
    end
end

return {}
