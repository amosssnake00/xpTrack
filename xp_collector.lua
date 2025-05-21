-- xp_collector.lua
-- Collects XP and AA XP data and stores it in an SQLite database using per-profile tables.
-- Also includes aggregation logic to roll up data to 30-minute and 1-hour intervals within the profile's table.

-- To enable verbose logging for debugging, set DEBUG_MODE to true below.
local DEBUG_MODE = false

--[[
  Development Note:
  This script is intended to run within a MacroQuest (MQ) environment.
  Features like `mq.TLO`, `mq.delay`, `mq.bind`, `printf` are specific to MQ.
  If running outside MQ, these will need to be stubbed or replaced.
]]

-- Require necessary modules
local mq = require('mq')
local db_utils = require('db_utils')
local sqlite3 = require('lsqlite3') -- For sqlite3.OK

-- --- Global Variable for Character-Specific Table Name ---
local CHARACTER_TABLE_NAME = nil -- Will be set after DB connection and profile identification

-- --- Debug Logging Helper ---
local function debug_log(message_supplier)
    if DEBUG_MODE then
        local prefix = CHARACTER_TABLE_NAME and string.format("XPTracker(%s) DEBUG: ", CHARACTER_TABLE_NAME) or "XPTracker DEBUG: "
        if mq and printf then
            printf("\20%s\ao%s", prefix, message_supplier())
        else
            print(prefix .. message_supplier())
        end
    end
end

-- --- Logging Helper (for non-debug messages) ---
local function log_message(level, message)
    local color_prefix = ""
    if level == "info" then color_prefix = "\ag"
    elseif level == "warn" then color_prefix = "\ay"
    elseif level == "error" then color_prefix = "\ar"
    end
    local prefix = CHARACTER_TABLE_NAME and string.format("XPTracker(%s): ", CHARACTER_TABLE_NAME) or "XPTracker: "

    if mq and printf then
        printf("\20%s%s%s", prefix, color_prefix, message)
    else
        print(string.format("%s[%s] %s", prefix, string.upper(level), message))
    end
end

-- --- Configuration ---
local db_path = "xp_data.sqlite"
local collection_interval_seconds = 1
local aggregation_granularity_seconds = 60

local thirty_min_aggregation_interval_seconds = 1800
local one_hour_aggregation_interval_seconds = 3600
local aggregation_run_frequency_seconds = 3600

-- --- Database Initialization & Profile Table Setup ---
debug_log(function() return "Attempting database connection to: " .. db_path end)
local db = db_utils.get_db_connection(db_path)
if not db then
  if mq and printf then printf("\20XPTracker: \arFatal Error: Could not connect to database at %s. Exiting.", db_path)
  else print("XPTracker: Fatal Error: Could not connect to database at " .. db_path .. ". Exiting.") end
  return
end
debug_log(function() return "Database connection successful." end)

-- Get Server and Character Name (using existing functions)
-- These are now called early to determine the table name.
local current_server_name = "UnknownServer"
local current_character_name = "UnknownCharacter"

local function update_current_profile_names()
    if mq and mq.TLO and mq.TLO.EverQuest and mq.TLO.EverQuest.Server then
        local server = mq.TLO.EverQuest.Server()
        if server and #server > 0 then current_server_name = server end
    end
    if mq and mq.TLO and mq.TLO.Me and mq.TLO.Me.Name then
        local charName = mq.TLO.Me.Name()
        if charName and #charName > 0 then current_character_name = charName end
    end
    debug_log(function() return string.format("Updated profile names: Server=%s, Character=%s", current_server_name, current_character_name) end)
end
update_current_profile_names() -- Initial call

CHARACTER_TABLE_NAME = db_utils.get_table_name(current_server_name, current_character_name)
debug_log(function() return string.format("Determined character-specific table name: %s", CHARACTER_TABLE_NAME) end)

debug_log(function() return string.format("Attempting database initialization for table: %s", CHARACTER_TABLE_NAME) end)
local ok, err_msg = db_utils.init_db(db, current_server_name, current_character_name)
if not ok then
  log_message("error", string.format("Fatal Error: Could not initialize database table %s: %s. Exiting.", CHARACTER_TABLE_NAME, err_msg or "Unknown error"))
  db:close()
  return
end
debug_log(function() return string.format("Database table %s initialized successfully.", CHARACTER_TABLE_NAME) end)
log_message("info", string.format("Database and table '%s' initialized successfully at %s", CHARACTER_TABLE_NAME, db_path))


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

-- --- XP/AA Tracking Logic ---
local TrackXP = {
    Experience = {Base = 0, Gained = 0, Last = 0, Time = os.time()},
    AAExperience = {Base = 0, Gained = 0, Last = 0, Time = os.time()},
    Initialized = false,
    Paused = false
}
local XPTotalPerLevel = {}
local XPTotalDivider = 330

local function InitializeXPTrackers()
    debug_log(function() return "InitializeXPTrackers() called." end)
    update_current_profile_names() -- Ensure profile names are current before initializing
    -- Re-get table name and re-init DB in case character changed (e.g. persona swap)
    local new_table_name = db_utils.get_table_name(current_server_name, current_character_name)
    if new_table_name ~= CHARACTER_TABLE_NAME then
        log_message("info", string.format("Profile changed from %s to %s. Initializing new table.", CHARACTER_TABLE_NAME, new_table_name))
        CHARACTER_TABLE_NAME = new_table_name
        local init_ok, init_err = db_utils.init_db(db, current_server_name, current_character_name)
        if not init_ok then
            log_message("error", string.format("Failed to initialize new profile table %s: %s. Collector may be unstable.", CHARACTER_TABLE_NAME, init_err or "Unknown"))
            -- Decide if we should pause or exit. For now, continue but data might go to wrong table or fail.
        else
            log_message("info", string.format("Successfully initialized new profile table: %s", CHARACTER_TABLE_NAME))
        end
    end


    if mq and mq.TLO and mq.TLO.Me and mq.TLO.Me.PctExp and mq.TLO.Me.PctAAExp then
        TrackXP.Experience.Base = mq.TLO.Me.PctExp()
        TrackXP.AAExperience.Base = mq.TLO.Me.PctAAExp()
        TrackXP.Initialized = true
        log_message("info", string.format("XP and AA XP trackers initialized. Current XP: %.3f%%, Current AA XP: %.3f%%", TrackXP.Experience.Base, TrackXP.AAExperience.Base))
    else
        log_message("warn", "Could not initialize XP trackers. MQ TLOs for PctExp/PctAAExp not available.")
        TrackXP.Experience.Base = 0; TrackXP.AAExperience.Base = 0; TrackXP.Initialized = false
    end
end

local function CheckExpChanged()
    if not TrackXP.Initialized or TrackXP.Paused or not (mq and mq.TLO and mq.TLO.Me and mq.TLO.Me.PctExp and mq.TLO.Me.Level and mq.TLO.Me.MaxExp) then return 0 end
    local currentExp = mq.TLO.Me.PctExp()
    local gained = 0
    if currentExp < TrackXP.Experience.Base then
        local currentLevel = mq.TLO.Me.Level()
        local prevLevel = currentLevel > 1 and currentLevel -1 or currentLevel
        local totalForPrevLevel = XPTotalPerLevel[prevLevel] or (mq.TLO.Me.MaxExp() / XPTotalDivider)
        gained = totalForPrevLevel * ( (100 - TrackXP.Experience.Base) / 100) + (totalForPrevLevel * (currentExp / 100))
    elseif currentExp > TrackXP.Experience.Base then
        gained = currentExp - TrackXP.Experience.Base
    end
    if gained > 0 then
        TrackXP.Experience.Gained = TrackXP.Experience.Gained + gained; TrackXP.Experience.Last = gained
        TrackXP.Experience.Time = get_current_utc_timestamp(); TrackXP.Experience.Base = currentExp
        return gained
    end
    return 0
end

local function CheckAAExpChanged()
    if not TrackXP.Initialized or TrackXP.Paused or not (mq and mq.TLO and mq.TLO.Me and mq.TLO.Me.PctAAExp) then return 0 end
    local currentAAExp = mq.TLO.Me.PctAAExp()
    local gained = 0
    if currentAAExp < TrackXP.AAExperience.Base then gained = (100 - TrackXP.AAExperience.Base) + currentAAExp
    elseif currentAAExp > TrackXP.AAExperience.Base then gained = currentAAExp - TrackXP.AAExperience.Base end
    if gained > 0 then
        TrackXP.AAExperience.Gained = TrackXP.AAExperience.Gained + gained; TrackXP.AAExperience.Last = gained
        TrackXP.AAExperience.Time = get_current_utc_timestamp(); TrackXP.AAExperience.Base = currentAAExp
        return gained
    end
    return 0
end

-- --- Aggregation Functions ---
local function execute_sql_in_transaction(db_conn, sql_statements)
    debug_log(function() return "execute_sql_in_transaction called with " .. #sql_statements .. " statements." end)
    local status, err = pcall(function()
        db_conn:exec("BEGIN TRANSACTION;")
        for i, sql in ipairs(sql_statements) do
            debug_log(function() return "Executing SQL (" .. i .. "/" .. #sql_statements .. "): " .. sql end)
            if db_conn:exec(sql) ~= sqlite3.OK then error(db_conn:errmsg()) end
        end
        db_conn:exec("COMMIT;")
    end)
    if not status then
        debug_log(function() return "Transaction failed: " .. (err or "Unknown error") .. ". Attempting rollback." end)
        pcall(function() db_conn:exec("ROLLBACK;") end)
        return false, err
    end
    return true
end

function aggregate_to_30_min(db_conn, table_name_to_aggregate)
    log_message("info", string.format("Starting 30-minute aggregation process for table '%s'.", table_name_to_aggregate))
    debug_log(function() return string.format("aggregate_to_30_min(%s) called.", table_name_to_aggregate) end)
    local twenty_four_hours_ago = get_current_utc_timestamp() - (24 * 60 * 60)
    local source_granularity = 60
    local target_granularity = 1800

    local query_sql = string.format([[
        SELECT CAST(timestamp / %d AS INTEGER) * %d AS interval_start, SUM(xp_gain) AS total_xp, SUM(aa_xp_gain) AS total_aa_xp, COUNT(id) AS num_records_to_aggregate
        FROM %s WHERE granularity = %d AND timestamp < %d
        GROUP BY interval_start HAVING SUM(xp_gain) > 0 OR SUM(aa_xp_gain) > 0;
    ]], target_granularity, target_granularity, table_name_to_aggregate, source_granularity, twenty_four_hours_ago)
    debug_log(function() return "30-min aggregation SELECT SQL: " .. query_sql end)

    local aggregated_count, deleted_count, total_rows_queried = 0, 0, 0
    local stmt, err_msg_prepare = db_conn:prepare(query_sql)
    if not stmt then
        log_message("error", string.format("Failed to prepare 30-min aggregation query for %s: %s", table_name_to_aggregate, err_msg_prepare or db_conn:errmsg()))
        return
    end

    for interval_start, total_xp, total_aa_xp, num_recs in stmt:nrows() do
        total_rows_queried = total_rows_queried + 1
        local transaction_statements = {}
        table.insert(transaction_statements, string.format(
            "INSERT INTO %s (timestamp, xp_gain, aa_xp_gain, granularity) VALUES (%d, %f, %f, %d);",
            table_name_to_aggregate, interval_start, total_xp, total_aa_xp, target_granularity
        ))
        local interval_end = interval_start + target_granularity - 1
        table.insert(transaction_statements, string.format(
            "DELETE FROM %s WHERE granularity = %d AND timestamp >= %d AND timestamp <= %d AND timestamp < %d;",
            table_name_to_aggregate, source_granularity, interval_start, interval_end, twenty_four_hours_ago
        ))
        
        local success, err = execute_sql_in_transaction(db_conn, transaction_statements)
        if success then
            aggregated_count = aggregated_count + 1; deleted_count = deleted_count + num_recs
            log_message("info", string.format("Aggregated 1-min data to 30-min at %s. %d source records processed.", os.date("%Y-%m-%d %H:%M:%S", interval_start), num_recs))
        else
            log_message("error", string.format("Failed to aggregate 30-min data at %s: %s", os.date("%Y-%m-%d %H:%M:%S", interval_start), err))
        end
    end
    stmt:finalize()
    log_message("info", string.format("30-minute aggregation for %s complete. %d new records created, approx %d source records deleted.", table_name_to_aggregate, aggregated_count, deleted_count))
end

function aggregate_to_1_hour(db_conn, table_name_to_aggregate)
    log_message("info", string.format("Starting 1-hour aggregation process for table '%s'.", table_name_to_aggregate))
    debug_log(function() return string.format("aggregate_to_1_hour(%s) called.", table_name_to_aggregate) end)
    local seven_days_ago = get_current_utc_timestamp() - (7 * 24 * 60 * 60)
    local source_granularity = 1800
    local target_granularity = 3600

    local query_sql = string.format([[
        SELECT CAST(timestamp / %d AS INTEGER) * %d AS interval_start, SUM(xp_gain) AS total_xp, SUM(aa_xp_gain) AS total_aa_xp, COUNT(id) AS num_records_to_aggregate
        FROM %s WHERE granularity = %d AND timestamp < %d
        GROUP BY interval_start HAVING SUM(xp_gain) > 0 OR SUM(aa_xp_gain) > 0;
    ]], target_granularity, target_granularity, table_name_to_aggregate, source_granularity, seven_days_ago)
    debug_log(function() return "1-hour aggregation SELECT SQL: " .. query_sql end)

    local aggregated_count, deleted_count, total_rows_queried = 0, 0, 0
    local stmt, err_msg_prepare = db_conn:prepare(query_sql)
    if not stmt then
        log_message("error", string.format("Failed to prepare 1-hour aggregation query for %s: %s", table_name_to_aggregate, err_msg_prepare or db_conn:errmsg()))
        return
    end

    for interval_start, total_xp, total_aa_xp, num_recs in stmt:nrows() do
        total_rows_queried = total_rows_queried + 1
        local transaction_statements = {}
        table.insert(transaction_statements, string.format(
            "INSERT INTO %s (timestamp, xp_gain, aa_xp_gain, granularity) VALUES (%d, %f, %f, %d);",
            table_name_to_aggregate, interval_start, total_xp, total_aa_xp, target_granularity
        ))
        local interval_end = interval_start + target_granularity - 1
        table.insert(transaction_statements, string.format(
            "DELETE FROM %s WHERE granularity = %d AND timestamp >= %d AND timestamp <= %d AND timestamp < %d;",
            table_name_to_aggregate, source_granularity, interval_start, interval_end, seven_days_ago
        ))

        local success, err = execute_sql_in_transaction(db_conn, transaction_statements)
        if success then
            aggregated_count = aggregated_count + 1; deleted_count = deleted_count + num_recs
            log_message("info", string.format("Aggregated 30-min data to 1-hour at %s. %d source records processed.", os.date("%Y-%m-%d %H:%M:%S", interval_start), num_recs))
        else
            log_message("error", string.format("Failed to aggregate 1-hour data at %s: %s", os.date("%Y-%m-%d %H:%M:%S", interval_start), err))
        end
    end
    stmt:finalize()
    log_message("info", string.format("1-hour aggregation for %s complete. %d new records created, approx %d source records deleted.", table_name_to_aggregate, aggregated_count, deleted_count))
end

-- --- Main Data Collection Variables ---
local current_minute_start_time = math.floor(get_current_utc_timestamp() / aggregation_granularity_seconds) * aggregation_granularity_seconds
local current_minute_xp_gain = 0
local current_minute_aa_xp_gain = 0
local last_aggregation_run_time = 0

-- --- Main Loop ---
log_message("info", string.format("Starting main collection loop. Interval: %d sec, DB Aggregation: %d sec. DEBUG_MODE is %s", collection_interval_seconds, aggregation_granularity_seconds, DEBUG_MODE and "ON" or "OFF"))

while true do
    local current_timestamp_loop = get_current_utc_timestamp() -- Moved to the top of the loop

    debug_log(function() return "Main loop iteration started. Timestamp: " .. current_timestamp_loop end)

    if not CHARACTER_TABLE_NAME then
        log_message("error", "CHARACTER_TABLE_NAME is not set. Collector cannot proceed. Check TLOs for server/char name at startup.")
        mq.delay(5000) -- Wait before retrying to avoid spam
        update_current_profile_names() -- Attempt to re-fetch profile names
        CHARACTER_TABLE_NAME = db_utils.get_table_name(current_server_name, current_character_name)
        if CHARACTER_TABLE_NAME then
            local init_ok, init_err = db_utils.init_db(db, current_server_name, current_character_name)
            if not init_ok then 
                CHARACTER_TABLE_NAME = nil; 
                log_message("error", "Re-initialization of profile table failed.") 
            end
        end
        goto continue_loop -- This goto now does not jump over the declaration of current_timestamp_loop
    end

    if mq and mq.TLO and mq.TLO.EverQuest and mq.TLO.EverQuest.GameState then
        local gameState = mq.TLO.EverQuest.GameState()
        if gameState == "INGAME" then
            if not TrackXP.Initialized or (mq.TLO.Me.Name() ~= current_character_name) or (mq.TLO.EverQuest.Server() ~= current_server_name) then
                -- Re-initialize if not initialized, or if character/server changed (persona swap or server bug)
                log_message("info", string.format("Player state change: Old: %s@%s. New: %s@%s. Re-initializing trackers.", current_character_name, current_server_name, mq.TLO.Me.Name() or "N/A", mq.TLO.EverQuest.Server() or "N/A"))
                InitializeXPTrackers() -- This will update current_server_name, current_character_name, and CHARACTER_TABLE_NAME
            end
            TrackXP.Paused = false
            if TrackXP.Initialized then
                local xp_gained_this_cycle = CheckExpChanged()
                if xp_gained_this_cycle > 0 then current_minute_xp_gain = current_minute_xp_gain + xp_gained_this_cycle end
                local aa_xp_gained_this_cycle = CheckAAExpChanged()
                if aa_xp_gained_this_cycle > 0 then current_minute_aa_xp_gain = current_minute_aa_xp_gain + aa_xp_gained_this_cycle end
            end
        else -- Not INGAME
            if TrackXP.Initialized then
                log_message("warn", "Not in game. Pausing XP tracking until back in game.")
                TrackXP.Initialized = false; TrackXP.Paused = true
            end
        end
    else
        log_message("warn", "MQ TLO for GameState not available. Tracking paused.")
        TrackXP.Paused = true
    end

    -- current_timestamp_loop is already defined at the start of the loop.
    -- Its value here will be from the beginning of this loop iteration.
    -- This is fine for the minute rollover check as we only need a consistent timestamp for the current iteration.
    if current_timestamp_loop >= current_minute_start_time + aggregation_granularity_seconds then
        debug_log(function() return string.format("Minute rollover. Current TS: %d, Minute Start TS: %d", current_timestamp_loop, current_minute_start_time) end)
        if (current_minute_xp_gain > 0 or current_minute_aa_xp_gain > 0) and not TrackXP.Paused and TrackXP.Initialized then
            debug_log(function() return string.format("Preparing to insert data into %s: XP=%.2f, AA_XP=%.2f, Granularity=%d, Timestamp=%d", CHARACTER_TABLE_NAME, current_minute_xp_gain, current_minute_aa_xp_gain, aggregation_granularity_seconds, current_minute_start_time) end)
            local insert_sql = string.format(
                "INSERT INTO %s (timestamp, xp_gain, aa_xp_gain, granularity) VALUES (%d, %f, %f, %d);",
                CHARACTER_TABLE_NAME, current_minute_start_time, current_minute_xp_gain, current_minute_aa_xp_gain, aggregation_granularity_seconds
            )
            local exec_ok, exec_err = pcall(function() if db:exec(insert_sql) ~= sqlite3.OK then error(db:errmsg()) end end)
            if not exec_ok then log_message("error", string.format("Error inserting 1-min data into %s: %s", CHARACTER_TABLE_NAME, exec_err))
            else log_message("info", string.format("Data for minute starting %s inserted into %s. XP: %.3f, AA_XP: %.3f", os.date("%Y-%m-%d %H:%M:%S", current_minute_start_time), CHARACTER_TABLE_NAME, current_minute_xp_gain, current_minute_aa_xp_gain)) end
        else
            debug_log(function() return "No XP/AA gain this minute, or tracking paused/uninitialized. No data inserted." end)
        end
        current_minute_xp_gain = 0; current_minute_aa_xp_gain = 0
        current_minute_start_time = math.floor(current_timestamp_loop / aggregation_granularity_seconds) * aggregation_granularity_seconds
        
        if current_timestamp_loop - last_aggregation_run_time >= aggregation_run_frequency_seconds then
            log_message("info", "Attempting scheduled aggregation tasks.")
            local agg_30_success, agg_30_err = pcall(aggregate_to_30_min, db, CHARACTER_TABLE_NAME)
            if not agg_30_success then log_message("error", string.format("Error during 30-minute aggregation for %s: %s", CHARACTER_TABLE_NAME, agg_30_err)) end
            local agg_1hr_success, agg_1hr_err = pcall(aggregate_to_1_hour, db, CHARACTER_TABLE_NAME)
            if not agg_1hr_success then log_message("error", string.format("Error during 1-hour aggregation for %s: %s", CHARACTER_TABLE_NAME, agg_1hr_err)) end
            last_aggregation_run_time = current_timestamp_loop
        end
    end

    ::continue_loop::
    if mq and mq.delay then mq.delay(collection_interval_seconds * 1000)
    else local wait_until = os.time() + collection_interval_seconds; while os.time() < wait_until do end end
end

return {}
