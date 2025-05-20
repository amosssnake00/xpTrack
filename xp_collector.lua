-- xp_collector.lua
-- Collects XP and AA XP data and stores it in an SQLite database.
-- Also includes aggregation logic to roll up data to 30-minute and 1-hour intervals.

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

-- --- Configuration ---
local db_path = "xp_data.sqlite" -- Path to the SQLite database file
local collection_interval_seconds = 1 -- How often to check for XP changes
local aggregation_granularity_seconds = 60 -- How often to write to DB (1-minute data)

local thirty_min_aggregation_interval_seconds = 1800 -- 30 minutes
local one_hour_aggregation_interval_seconds = 3600   -- 1 hour

local aggregation_run_frequency_seconds = 3600 -- How often to attempt to run aggregation tasks (e.g., every hour)

-- --- Database Initialization ---
local db = db_utils.get_db_connection(db_path)
if not db then
  if mq and mq.printf then
    mq.printf("\20XPTracker: \arFatal Error: Could not connect to database at %s. Exiting.", db_path)
  else
    print("XPTracker: Fatal Error: Could not connect to database at " .. db_path .. ". Exiting.")
  end
  return -- Stop script execution if DB connection fails
end

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

local function get_current_utc_timestamp()
  return os.time() + utc_offset
end

-- --- Logging Helper ---
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
    return server and #server > 0 and server or "UnknownServer"
  end
  log_message("warn", "mq.TLO.EverQuest.Server() not available. Using 'UnknownServer'.")
  return "UnknownServer"
end

local function get_character_name()
  if mq and mq.TLO and mq.TLO.Me and mq.TLO.Me.Name then
    local charName = mq.TLO.Me.Name()
    return charName and #charName > 0 and charName or "UnknownCharacter"
  end
  log_message("warn", "mq.TLO.Me.Name() not available. Using 'UnknownCharacter'.")
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
    if mq and mq.TLO and mq.TLO.Me and mq.TLO.Me.PctExp and mq.TLO.Me.PctAAExp then
        TrackXP.Experience.Base = mq.TLO.Me.PctExp()
        TrackXP.AAExperience.Base = mq.TLO.Me.PctAAExp()
        TrackXP.Initialized = true
        log_message("info", string.format("XP and AA XP trackers initialized. Current XP: %.3f%%, Current AA XP: %.3f%%", TrackXP.Experience.Base, TrackXP.AAExperience.Base))
    else
        log_message("warn", "Could not initialize XP trackers. MQ TLOs for PctExp/PctAAExp not available.")
        TrackXP.Experience.Base = 0
        TrackXP.AAExperience.Base = 0
        TrackXP.Initialized = false
    end
end

local function CheckExpChanged()
    if not TrackXP.Initialized or TrackXP.Paused or not (mq and mq.TLO and mq.TLO.Me and mq.TLO.Me.PctExp and mq.TLO.Me.Level and mq.TLO.Me.MaxExp) then
        return 0
    end
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
        return 0
    end
    local currentAAExp = mq.TLO.Me.PctAAExp()
    local gained = 0
    if currentAAExp < TrackXP.AAExperience.Base then
        gained = (100 - TrackXP.AAExperience.Base) + currentAAExp
    elseif currentAAExp > TrackXP.AAExperience.Base then
        gained = currentAAExp - TrackXP.AAExperience.Base
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
    local status, err = pcall(function()
        local exec_err = db_conn:exec("BEGIN TRANSACTION;")
        if exec_err ~= sqlite3.OK then
            error("Failed to begin transaction: " .. db_conn:errmsg())
        end

        for _, sql in ipairs(sql_statements) do
            exec_err = db_conn:exec(sql)
            if exec_err ~= sqlite3.OK then
                error(string.format("SQL error: %s (Query: %s)", db_conn:errmsg(), sql))
            end
        end

        exec_err = db_conn:exec("COMMIT;")
        if exec_err ~= sqlite3.OK then
            error("Failed to commit transaction: " .. db_conn:errmsg())
        end
    end)
    if not status then
        pcall(function() db_conn:exec("ROLLBACK;") end) -- Attempt rollback on error
        return false, err
    end
    return true
end

function aggregate_to_30_min(db_conn)
    log_message("info", "Starting 30-minute aggregation process.")
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
            COUNT(id) AS num_records_to_aggregate -- For logging/verification
        FROM xp_data
        WHERE granularity = %d AND timestamp < %d
        GROUP BY server_name, character_name, interval_start
        HAVING SUM(xp_gain) > 0 OR SUM(aa_xp_gain) > 0; -- Only aggregate if there's data
    ]], target_granularity, target_granularity, source_granularity, twenty_four_hours_ago)

    local aggregated_count = 0
    local deleted_count = 0

    local stmt, err_msg_prepare = db_conn:prepare(query_sql)
    if not stmt then
        log_message("error", string.format("Failed to prepare 30-min aggregation query: %s", err_msg_prepare or db_conn:errmsg()))
        return
    end

    for interval_start, server_name, character_name, total_xp, total_aa_xp, num_recs in stmt:nrows() do
        local transaction_statements = {}
        table.insert(transaction_statements, string.format(
            "INSERT INTO xp_data (timestamp, server_name, character_name, xp_gain, aa_xp_gain, granularity) VALUES (%d, '%s', '%s', %f, %f, %d);",
            interval_start,
            server_name:gsub("'", "''"),
            character_name:gsub("'", "''"),
            total_xp,
            total_aa_xp,
            target_granularity
        ))

        -- Define the time range for deletion for this specific group
        local interval_end = interval_start + target_granularity -1 -- up to the second before the next interval
        table.insert(transaction_statements, string.format(
            "DELETE FROM xp_data WHERE granularity = %d AND server_name = '%s' AND character_name = '%s' AND timestamp >= %d AND timestamp <= %d AND timestamp < %d;",
            source_granularity,
            server_name:gsub("'", "''"),
            character_name:gsub("'", "''"),
            interval_start, -- Delete records that fall into this aggregated interval
            interval_end,
            twenty_four_hours_ago -- Ensure we only delete records older than 24h
        ))
        
        local success, err = execute_sql_in_transaction(db_conn, transaction_statements)
        if success then
            aggregated_count = aggregated_count + 1
            deleted_count = deleted_count + num_recs -- Assuming num_recs is accurate for what's deleted
            log_message("info", string.format("Aggregated 1-min data to 30-min for %s on %s at %s. %d source records processed.", character_name, server_name, os.date("%Y-%m-%d %H:%M:%S", interval_start), num_recs))
        else
            log_message("error", string.format("Failed to aggregate 30-min data for %s at %s: %s", character_name, os.date("%Y-%m-%d %H:%M:%S", interval_start), err))
        end
    end
    stmt:finalize()
    log_message("info", string.format("30-minute aggregation complete. %d new records created, approx %d source records deleted.", aggregated_count, deleted_count))
end


function aggregate_to_1_hour(db_conn)
    log_message("info", "Starting 1-hour aggregation process.")
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

    local aggregated_count = 0
    local deleted_count = 0
    
    local stmt, err_msg_prepare = db_conn:prepare(query_sql)
    if not stmt then
        log_message("error", string.format("Failed to prepare 1-hour aggregation query: %s", err_msg_prepare or db_conn:errmsg()))
        return
    end

    for interval_start, server_name, character_name, total_xp, total_aa_xp, num_recs in stmt:nrows() do
        local transaction_statements = {}
        table.insert(transaction_statements, string.format(
            "INSERT INTO xp_data (timestamp, server_name, character_name, xp_gain, aa_xp_gain, granularity) VALUES (%d, '%s', '%s', %f, %f, %d);",
            interval_start,
            server_name:gsub("'", "''"),
            character_name:gsub("'", "''"),
            total_xp,
            total_aa_xp,
            target_granularity
        ))
        
        local interval_end = interval_start + target_granularity -1
        table.insert(transaction_statements, string.format(
            "DELETE FROM xp_data WHERE granularity = %d AND server_name = '%s' AND character_name = '%s' AND timestamp >= %d AND timestamp <= %d AND timestamp < %d;",
            source_granularity,
            server_name:gsub("'", "''"),
            character_name:gsub("'", "''"),
            interval_start,
            interval_end,
            seven_days_ago
        ))

        local success, err = execute_sql_in_transaction(db_conn, transaction_statements)
        if success then
            aggregated_count = aggregated_count + 1
            deleted_count = deleted_count + num_recs
            log_message("info", string.format("Aggregated 30-min data to 1-hour for %s on %s at %s. %d source records processed.", character_name, server_name, os.date("%Y-%m-%d %H:%M:%S", interval_start), num_recs))
        else
            log_message("error", string.format("Failed to aggregate 1-hour data for %s at %s: %s", character_name, os.date("%Y-%m-%d %H:%M:%S", interval_start), err))
        end
    end
    stmt:finalize()
    log_message("info", string.format("1-hour aggregation complete. %d new records created, approx %d source records deleted.", aggregated_count, deleted_count))
end


-- --- Main Data Collection Variables ---
local current_minute_start_time = math.floor(get_current_utc_timestamp() / aggregation_granularity_seconds) * aggregation_granularity_seconds
local current_minute_xp_gain = 0
local current_minute_aa_xp_gain = 0
local last_aggregation_run_time = 0

-- --- Main Loop ---
log_message("info", string.format("Starting main collection loop. Interval: %d sec, DB Aggregation: %d sec.", collection_interval_seconds, aggregation_granularity_seconds))

while true do
    if mq and mq.TLO and mq.TLO.EverQuest and mq.TLO.EverQuest.GameState then
        if mq.TLO.EverQuest.GameState() == "INGAME" then
            if not TrackXP.Initialized then
                InitializeXPTrackers()
            end
            TrackXP.Paused = false -- Ensure not paused when in game

            if TrackXP.Initialized then
                local xp_gained_this_cycle = CheckExpChanged()
                local aa_xp_gained_this_cycle = CheckAAExpChanged()

                if xp_gained_this_cycle > 0 then
                    current_minute_xp_gain = current_minute_xp_gain + xp_gained_this_cycle
                    -- log_message("info", string.format("XP Gained: %.3f%% (Total this minute: %.3f%%)", xp_gained_this_cycle, current_minute_xp_gain))
                end

                if aa_xp_gained_this_cycle > 0 then
                    current_minute_aa_xp_gain = current_minute_aa_xp_gain + aa_xp_gained_this_cycle
                    -- log_message("info", string.format("AA XP Gained: %.3f%% (Total this minute: %.3f%%)", aa_xp_gained_this_cycle, current_minute_aa_xp_gain))
                end
            end
        else -- Not INGAME
            if TrackXP.Initialized then
                log_message("warn", "Not in game. Pausing XP tracking until back in game.")
                TrackXP.Initialized = false -- Reset to re-init when back in game
                TrackXP.Paused = true
            end
        end
    else
        log_message("warn", "MQ TLO for GameState not available. Cannot determine if in game. Tracking will be effectively paused.")
        TrackXP.Paused = true
    end

    local current_timestamp = get_current_utc_timestamp()
    if current_timestamp >= current_minute_start_time + aggregation_granularity_seconds then
        if (current_minute_xp_gain > 0 or current_minute_aa_xp_gain > 0) and not TrackXP.Paused and TrackXP.Initialized then
            local server_name = get_server_name()
            local character_name = get_character_name()

            local insert_sql = string.format(
                "INSERT INTO xp_data (timestamp, server_name, character_name, xp_gain, aa_xp_gain, granularity) VALUES (%d, '%s', '%s', %f, %f, %d);",
                current_minute_start_time,
                server_name:gsub("'", "''"),
                character_name:gsub("'", "''"),
                current_minute_xp_gain,
                current_minute_aa_xp_gain,
                aggregation_granularity_seconds
            )

            local exec_ok, exec_err = pcall(function()
                local err_code = db:exec(insert_sql)
                if err_code ~= sqlite3.OK then
                    error(db:errmsg())
                end
            end)

            if not exec_ok then
                log_message("error", string.format("Error inserting 1-min data into database: %s (SQL: %s)", exec_err, insert_sql))
            else
                log_message("info", string.format("Data for minute starting %s inserted. XP: %.3f, AA_XP: %.3f", os.date("%Y-%m-%d %H:%M:%S", current_minute_start_time), current_minute_xp_gain, current_minute_aa_xp_gain))
            end
        end

        current_minute_xp_gain = 0
        current_minute_aa_xp_gain = 0
        current_minute_start_time = math.floor(current_timestamp / aggregation_granularity_seconds) * aggregation_granularity_seconds

        -- --- Run Aggregation Tasks ---
        if current_timestamp - last_aggregation_run_time >= aggregation_run_frequency_seconds then
            log_message("info", "Attempting scheduled aggregation tasks.")
            local agg_30_success, agg_30_err = pcall(aggregate_to_30_min, db)
            if not agg_30_success then
                log_message("error", string.format("Error during 30-minute aggregation: %s", agg_30_err))
            end

            local agg_1hr_success, agg_1hr_err = pcall(aggregate_to_1_hour, db)
            if not agg_1hr_success then
                log_message("error", string.format("Error during 1-hour aggregation: %s", agg_1hr_err))
            end
            last_aggregation_run_time = current_timestamp
        end
    end

    if mq and mq.delay then
        mq.delay(collection_interval_seconds * 1000)
    else
        local wait_until = os.time() + collection_interval_seconds
        while os.time() < wait_until do end
    end
end

-- Cleanup (This part of the script is typically not reached in a continuous loop)
-- Consider adding a shutdown hook or command if running in MQ to call db:close()
-- db:close()
-- log_message("info", "XP Collector script ended and database connection closed.")

return {}
