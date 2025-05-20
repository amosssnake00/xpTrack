-- db_utils.lua
-- Utility functions for interacting with the SQLite database.

-- Load the SQLite3 library
local sqlite3 = require('lsqlite3')

--[[
get_db_connection(db_path)
Description: Establishes a connection to an SQLite database.
Parameters:
  db_path (string): The file path to the SQLite database.
Returns:
  Database connection object if successful, otherwise nil and an error message.
--]]
function get_db_connection(db_path)
  assert(db_path, "Database path cannot be nil")
  local db, err = sqlite3.open(db_path)
  if not db then
    print("Error opening database: " .. (err or "Unknown error"))
    return nil, err
  end
  print("Database connection successful: " .. db_path)
  return db
end

--[[
init_db(db)
Description: Initializes the database by creating the xp_data table and its indices if they don't already exist.
Parameters:
  db (object): The database connection object.
--]]
function init_db(db)
  assert(db, "Database connection object cannot be nil")

  -- SQL statement to create the xp_data table
  local create_table_sql = [[
    CREATE TABLE IF NOT EXISTS xp_data (
      id INTEGER PRIMARY KEY AUTOINCREMENT,  -- Unique identifier for each record
      timestamp INTEGER NOT NULL,            -- Unix timestamp in UTC when the data was recorded
      server_name TEXT NOT NULL,             -- Name of the server where the XP was gained
      character_name TEXT NOT NULL,          -- Name of the character who gained the XP
      xp_gain INTEGER DEFAULT 0,             -- Amount of regular XP gained
      aa_xp_gain INTEGER DEFAULT 0,          -- Amount of AA XP gained
      granularity INTEGER NOT NULL           -- Time window in seconds for data aggregation (e.g., 60, 1800, 3600)
    );
  ]]

  -- Execute the create table statement
  local err = db:exec(create_table_sql)
  if err ~= sqlite3.OK then
    print("Error creating xp_data table: " .. db:errmsg())
    return false, db:errmsg()
  end
  print("xp_data table ensured.")

  -- SQL statements to create indices for performance
  local create_indices_sql = {
    "CREATE INDEX IF NOT EXISTS idx_xp_data_timestamp ON xp_data (timestamp);",
    "CREATE INDEX IF NOT EXISTS idx_xp_data_server_name ON xp_data (server_name);",
    "CREATE INDEX IF NOT EXISTS idx_xp_data_character_name ON xp_data (character_name);",
    "CREATE INDEX IF NOT EXISTS idx_xp_data_granularity ON xp_data (granularity);"
  }

  -- Execute each create index statement
  for _, sql in ipairs(create_indices_sql) do
    err = db:exec(sql)
    if err ~= sqlite3.OK then
      print("Error creating index (" .. sql .. "): " .. db:errmsg())
      -- It's not necessarily a fatal error if one index fails, so we continue
    else
      print("Index ensured: " .. sql)
    end
  end
  print("Database initialization complete.")
  return true
end

-- Example usage (optional, can be commented out or removed)
-- local db_path = "xp_tracker.db"
-- local db = get_db_connection(db_path)
-- if db then
--   init_db(db)
--   db:close() -- Close the database connection when done
--   print("Database initialized and closed.")
-- else
--   print("Failed to initialize database.")
-- end

return {
  get_db_connection = get_db_connection,
  init_db = init_db
}
