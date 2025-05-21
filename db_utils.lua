-- db_utils.lua
-- Utility functions for interacting with the SQLite database,
-- now supporting profile-specific tables.

local sqlite3 = require('lsqlite3')

local M = {} -- Module table

--[[
sanitize_name_component(name_part)
Description: Sanitizes a part of a name for use in table or index names.
             Removes non-alphanumeric characters. If the result is empty,
             returns a default string "default".
Parameters:
  name_part (string): The string to sanitize.
Returns:
  Sanitized string.
--]]
local function sanitize_name_component(name_part)
    if not name_part or type(name_part) ~= "string" then
        return "invalid"
    end
    local sanitized = name_part:gsub("[^A-Za-z0-9]", "") -- Remove non-alphanumeric
    if #sanitized == 0 then
        return "default" -- Prevent empty name parts
    end
    return sanitized
end

--[[
M.get_table_name(server_name, character_name)
Description: Generates a sanitized table name for a given server and character.
Parameters:
  server_name (string): The name of the server.
  character_name (string): The name of the character.
Returns:
  string: The generated table name (e.g., "xp_data_ServerName_CharacterName").
--]]
function M.get_table_name(server_name, character_name)
    assert(server_name, "Server name cannot be nil for get_table_name")
    assert(character_name, "Character name cannot be nil for get_table_name")

    local san_server = sanitize_name_component(server_name)
    local san_char = sanitize_name_component(character_name)
    
    return string.format("xp_data_%s_%s", san_server, san_char)
end

--[[
M.get_db_connection(db_path)
Description: Establishes a connection to an SQLite database.
Parameters:
  db_path (string): The file path to the SQLite database.
Returns:
  Database connection object if successful, otherwise nil and an error message.
--]]
function M.get_db_connection(db_path)
  assert(db_path, "Database path cannot be nil")
  local db, err = sqlite3.open(db_path)
  if not db then
    print("Error opening database: " .. (err or "Unknown error")) -- Safe concatenation
    return nil, err
  end
  print("Database connection successful: " .. db_path)
  return db
end

--[[
M.init_db(db, server_name, character_name)
Description: Initializes the database by creating a profile-specific table and its indices if they don't already exist.
Parameters:
  db (object): The database connection object.
  server_name (string): The name of the server for the profile.
  character_name (string): The name of the character for the profile.
Returns:
  boolean, string: true if successful or table already exists, false and error message otherwise.
--]]
function M.init_db(db, server_name, character_name)
  assert(db, "Database connection object cannot be nil")
  assert(server_name, "Server name cannot be nil for init_db")
  assert(character_name, "Character name cannot be nil for init_db")

  local table_name = M.get_table_name(server_name, character_name)
  print(string.format("Ensuring table '%s' for %s@%s", table_name, character_name, server_name))

  local create_table_sql = string.format([[
    CREATE TABLE IF NOT EXISTS %s (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      timestamp INTEGER NOT NULL,
      xp_gain REAL DEFAULT 0,
      aa_xp_gain REAL DEFAULT 0,
      granularity INTEGER NOT NULL
    );
  ]], table_name)

  local err_exec = db:exec(create_table_sql)
  if err_exec ~= sqlite3.OK then
    local errmsg = db:errmsg()
    print(string.format("Error creating table '%s': %s", table_name, errmsg or "Unknown SQLite error")) -- Fixed
    return false, errmsg or "Unknown SQLite error"
  end
  print(string.format("Table '%s' ensured.", table_name))

  local create_indices_sql = {
    string.format("CREATE INDEX IF NOT EXISTS idx_%s_timestamp ON %s (timestamp);", table_name, table_name),
    string.format("CREATE INDEX IF NOT EXISTS idx_%s_granularity ON %s (granularity);", table_name, table_name)
  }

  for _, sql in ipairs(create_indices_sql) do
    err_exec = db:exec(sql)
    if err_exec ~= sqlite3.OK then
      local errmsg = db:errmsg()
      print(string.format("Error creating index (%s): %s", sql, errmsg or "Unknown SQLite error")) -- Fixed
    else
      -- Assuming this is line 87 if the error message is accurate
      print(string.format("Index ensured: %s", tostring(sql))) -- Speculative fix: ensure sql is string
    end
  end
  print(string.format("Database initialization complete for table '%s'.", table_name))
  return true
end

--[[
M.list_profile_tables(db)
Description: Queries sqlite_master to find all tables matching the xp_data_Server_Char pattern.
Parameters:
  db (object): The database connection object.
Returns:
  list: A list of tables, where each element is {server="ServerName", character="CharacterName", table_name="full_table_name"}.
--]]
function M.list_profile_tables(db)
    assert(db, "Database connection object cannot be nil for list_profile_tables")
    local profiles = {}
    local sql = "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'xp_data_%_%';"

    local stmt, err_prepare = db:prepare(sql)
    if not stmt then
        -- Ensure db:errmsg() is also guarded if it can be nil
        local prep_errmsg = db:errmsg()
        print("Error preparing list_profile_tables query: " .. (err_prepare or prep_errmsg or "Unknown SQLite error")) -- Fixed
        return profiles
    end

    for row_table_name in stmt:nrows() do
        local table_name = row_table_name.name
        local _, _, s_server, s_char = string.match(table_name, "^xp_data_([^_]+)_([^_]+)$")
        print(string.format("Found table name '%s', server '%s', char '%s'", table_name, s_server, s_char))
        if s_server and s_char then
            table.insert(profiles, { server = s_server, character = s_char, table_name = table_name })
        else
            print(string.format("Warning: Table name '%s' did not match expected pattern xp_data_Server_Char", table_name))
        end
    end
    stmt:finalize()
    print(string.format("Found %d profile tables.", #profiles))
    return profiles
end

return M
