-- Reworking SoloLootManager to be a Spawn Checker ~thank you Jackalo~
-- Basically LUA version of MQ2SpawnMaster using Sql Lite.
--[[ 
Goals for this project. 
  * have the lua scan the zone for all mobs, populate them into a table on the gui 
  * allow the user to search for npcs by name and navigate to them 
  * allow the user to flag an NPC for tracking, this will move them to the other tab. 
  * I would like to have the flags for tracking stay saved in a database by that can be filtered by zone (since some npc's can be in multiple zones.)
  * If an npc is flagged for tracking, and it isn't up, the entry shouldnt appear inthe tracking tab. 
  * if the npc spawns while in the zone it should appear in the tracking tab, and notifications can be configured 
  * any changes to flagging should be saved to the database. and only spawns flagged either track or ignore should be written, we don't want a HUGE list of "a snake"'s appearing
  * setting a spawn to ingnore should keep it in the database but not activly search for it
  * on load or changing zone we should query the database for the npcs in the current zone and then refresh the zone for spawns in the zone to compare to.

 Current Status
    Working
    * Pooling the zone for spawns and displaying them works. 
    * toggling the track and ignore radio buttons does move the entry onto and off of the tracking tab
    * NavTo button is functioning.
    * Searching the sone tab works 
    Not Working
    * writing and reading from the database  currently you lose all data when the script is reloaded. 
    * doesn't automatically refresh the zone on zoning, it does change the name on tab to current zone. but the data is stale and you need to press refresh button
    Future 
    * all of the other items not listed in working and not working.
    ]]
local SpawnMasterCheck = { _version = '1.0', author = 'Grimmier' }
--- @type Mq
local mq = require('mq')
--- @type ImGui
require('ImGui')
local ImguiHelper = require('mq/ImguiHelper')
-- https://gitlab.com/Knightly1/knightlinc
local Write = require('libraries/Write')
Write.prefix = 'SMC'
Write.loglevel = 'info'
local PackageMan = require('mq/PackageMan')
local zoned = true
local zoneA = ""
local zoneB = ""
if zoned then 
zoneA = mq.TLO.Zone.Name 
zoned = false
end

local lsql = PackageMan.Require('lsqlite3') do
  Write.Debug("lsqlite version: %s", lsql.version())
end
local DBPath = string.format('%s\\%s', mq.configDir, 'SpawnChecker.sqlite3')
local Table_Cache = {
  Rules = {},
  Filtered = {},
  Unhandled = {},
  Mobs = {},
}
local Lookup = {
  Rules = {},
}
local GUI_Main = {
  Open  = true,
  Show  = true,
  -- Flags = bit32.bor(ImGuiWindowFlags.NoResize, ImGuiWindowFlags.AlwaysAutoResize),
  --Flags = bit32.bor(0),
  Refresh = {
    Sort = {
      Rules     = true,
      Filtered  = true,
      Unhandled = true,
      Mobs = false,
    },
    Table = {
      Rules     = true,
      Filtered  = true,
      Unhandled = false,
      Mobs = false,
    },
  },
  Search = '',
  Table = {
    Column_ID = {
      ID          = 1,
      MobName     = 2,
      MobLoc      = 3,
      MobZoneName = 4,
      MobID       = 5,
      Action      = 6,
      Remove      = 7,
    },
    Flags = bit32.bor(
      ImGuiTableFlags.AlwaysAutoResize,
      ImGuiTableFlags.Resizable,
      ImGuiTableFlags.Sortable,
      ImGuiTableFlags.RowBg,
      ImGuiTableFlags.BordersV,
      ImGuiTableFlags.BordersOuter,
      --ImGuiTableFlags.SizingStretchProp,
      ImGuiTableFlags.ScrollY,
      ImGuiTableFlags.ScrollX,
      ImGuiTableFlags.Hideable
    ),
    SortSpecs = {
      Rules     = nil,
      Unhandled = nil,
      Filtered = nil,
      Mobs = nil,
    },
  },
}
---@class Database
---@field private version integer
---@field private connection any lsqlite3.open() object
local Database = {version = 1} do
  ---@param dbpath string
  ---@return Database object
  function Database:new(dbpath)
    local obj = {}
    setmetatable(obj, self)
    self.__index = self
    self.connection = lsql.open(dbpath)
    self.connection:exec('PRAGMA primary_keys=on')
    self:Initialize()
    self:CheckDatabase()
    return obj
  end
  ---@package
  function Database:CheckDatabase()
    local dbVersion = Database:GetConfig('version')
    local lastZone = Database:GetConfig('lastzone')
    -- If there's a revision, upgrade here in steps to each successive version and recurse this function
    if dbVersion == '1' then
      Write.Debug("dbVersion is current: v%s", dbVersion)
    elseif dbVersion ~= nil then
      Write.Fatal("unknown database version: %s", dbVersion)
      mq.exit()
    end
    if lastZone ~= nil then
      zoneA = lastZone
     Database:AddConfig('lastzone', zoneA)
    elseif lastZone == zoneA then
      Write.Debug("lastzone was saved in database: %s", lastZone)
    end
    
  end
  ---@package
  ---Initializes a database with the default tables and values.
  function Database:Initialize()
    self.connection:exec([[
      CREATE TABLE IF NOT EXISTS config(
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
      INSERT INTO config (key, value) VALUES ("version", "1")
        ON CONFLICT DO NOTHING;
      CREATE TABLE IF NOT EXISTS enum_action(
        enum TEXT PRIMARY KEY
      );
      INSERT INTO enum_action (enum) VALUES ("unhandled")
        ON CONFLICT DO NOTHING;
      INSERT INTO enum_action (enum) VALUES ("track")
        ON CONFLICT DO NOTHING;
      CREATE TABLE IF NOT EXISTS rule(
        id INTEGER PRIMARY KEY NOT NULL,
        mobname TEXT NOT NULL,
        mobzonename TEXT NOT NULL,
        enum_action TEXT DEFAULT "unhandled",
        CONSTRAINT fk_enum_action
          FOREIGN KEY (enum_action)
          REFERENCES enum_action (enum)
      );
    ]])
  end
  ---@package
  ---Called before Initialize() to wipe the database first.
  function Database:Reinitialize()
    self.connection:exec([[
      DROP TABLE IF EXISTS config;
      DROP TABLE IF EXISTS rule;
      DROP TABLE IF EXISTS enum_action;
    ]])
    self:Initialize()
  end
  ---@package
  ---@param key string
  ---@param value string
  function Database:AddConfig(key, value)
    local spc = self.connection:prepare([[INSERT INTO config (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value]])
    spc:bind_values(key, value)
    spc:step()
    spc:finalize()
  end
  ---@package
  ---@param key string
  function Database:RemoveConfig(key)
    local spc = self.connection:prepare([[DELETE FROM config WHERE key = ?]])
    spc:bind_values(key)
    spc:step()
    spc:finalize()
  end
  ---@package
  ---@param key string
  ---@return string
  function Database:GetConfig(key)
    local spc = self.connection:prepare([[SELECT value FROM config WHERE key = ?]])
    spc:bind_values(key)
    for row in spc:nrows() do
      spc:finalize()
      return row.value
    end
  end
  ---@private
  function RuleToEntry(rule)
    local entry = {
      MobName = rule.mobname,
      MobZoneName = rule.mobzonename,
      Enum_Action = rule.enum_action,
    }
    return entry
  end
  ---@private
local function EntryToRule(entry)
    -- Ensure all fields are present and not nil
    return {
        mobname = entry.MobName,
        mobzonename = entry.MobZoneName,
        enum_action = entry.Enum_Action,
    }
end

function Database:AddRule(entry)
    local keys = {}
    local placeholders = {}
    local conflicts = {}
    local fieldsOrder = {'mobname', 'mobzonename', 'enum_action'}  -- Fields to insert
    local entryRule = EntryToRule(entry)

    -- Build keys and conflict resolution
    for k, v in pairs(entryRule) do
        table.insert(keys, k) -- add the key
        table.insert(placeholders, '?') -- add a placeholder

        -- Assuming mobname and mobzonename are conflict columns, skip them for conflict resolution
        if k ~= 'mobname' and k ~= 'mobzonename' then
            table.insert(conflicts, string.format("%s = excluded.%s", k, k))
        end
    end

    -- Construct the binds in the order of columns specified in the INSERT statement
    local binds = {}
    for _, k in ipairs({"mobname", "mobzonename", "enum_action"}) do
        local v = entryRule[k]
        table.insert(binds, v)
    end

    -- Construct the query string
    local query = string.format(
        "INSERT INTO rule (%s) VALUES (%s) ON CONFLICT(mobname, mobzonename) DO UPDATE SET %s",
        table.concat(fieldsOrder, ", "),
        table.concat(placeholders, ", "), -- placeholders for values
        table.concat(conflicts, ", ")
    )

    -- Debug: Print the constructed query
        -- For debugging: construct a string of the query with values inserted
        local debugQuery = query
        for i, bind in ipairs(binds) do
            debugQuery = debugQuery:gsub("%?", tostring(bind), 1) -- replace the first occurrence of ? with the bind value
        end
       
    -- Debug: Print the constructed query
    -- mq.cmd("/echo Query: ", query)
    -- mq.cmd("/echo Debug Query: ", debugQuery)
    
    
    -- Prepare, bind, and execute the SQL statement
    local spc, err = self.connection:prepare(query)
    if not spc then
        Write.Debug("Statement preparation failed: %s", err)
        return -- handle the error appropriately
    end
    spc:bind_values(unpack(binds))
    spc:step()
    spc:finalize()

end
---@package
  ---@param id any
  function Database:RemoveRule(id, entry)
    -- Prepare the columns and values for the Deletion operation
    local columns = {"mobname", "mobzonename", "enum_action"}
    local valuesPlaceholders = {}
    local updates = {}
    local binds = {}
    -- Fill the valuesPlaceholders and updates arrays
    for _, col in ipairs(columns) do
        table.insert(valuesPlaceholders, "?")
        if col ~= "mobname" and col ~= "mobzonename" and col ~= "enum_action" then
            table.insert(updates, string.format("%s = excluded.%s", col, col))
        end
    end
    -- Fill the binds array with the entry values in the same order as columns
    for _, col in ipairs(columns) do
        table.insert(binds, entry[col])
    end
    -- Convert the arrays to comma-separated strings
    local keys = table.concat(columns, ", ")
    local values = table.concat(valuesPlaceholders, ", ")
    local conflict = table.concat(updates, ", ")
    -- Construct the query string
    local query = string.format([[
        DELETE FROM rule (%s) VALUES (%s) 
    ]], keys, values)
    -- Prepare, bind, execute, and finalize the SQL statement
    local spc, err = self.connection:prepare(query)
    if not spc then
        Write.Debug("Statement preparation failed: %s", err)
        return -- handle the error appropriately
    end
    spc:bind_values(unpack(binds))
    spc:step()
    spc:finalize()
  end
  ---@package
  ---@param id string
  ---@return table
  function Database:GetRule(id)
    local spc = self.connection:prepare([[SELECT * FROM rule WHERE id = ?]])
    spc:bind_values(id)
    for row in spc:nrows() do
      spc:finalize()
      return RuleToEntry(row)
    end
  end
  ---@package
  ---@return table
  function Database:GetAllRules()
    local spc = self.connection:prepare([[SELECT * FROM rule]])
    local newTable = {}
    for row in spc:nrows() do
      table.insert(newTable, RuleToEntry(row))
    end
    return newTable
  end
end
local DB = Database:new(DBPath)
local function ReinitializeDB()
  local title = "SMC > Reinitialize Warning"
  local text = "Are you really sure you want to wipe the database?"
  if ImguiHelper.Popup.Modal(title, text, { "Yes", "Cancel" }) == 1 then
    Database:Reinitialize()
  end
end
local function AddRule(entry)
  Write.Debug('AddRule [%s] %s', entry.Enum_Action, entry.MobName)
  Database:AddRule(entry)
  GUI_Main.Refresh.Table.Rules = true
  GUI_Main.Refresh.Table.Filtered = true
  GUI_Main.Refresh.Table.Unhandled = true
end
local function RemoveRule(entry)
  Write.Debug('RemoveRule [%s] %s', entry.Enum_Action, entry.MobName)
  Database:RemoveRule(entry.MobName, entry)
  GUI_Main.Refresh.Table.Rules = true
  GUI_Main.Refresh.Table.Filtered = true
  GUI_Main.Refresh.Table.Unhandled = true
end
local function CheckRule(entry)
  if Lookup.Rules[entry.MobName] then
    return true
  else
    return false
  end
end
local function Compare(entryValue, wantedValue)
  if entryValue == wantedValue then
    return true
  else
    return false
  end
end
local function SpawnToEntry(spawn, row)
  local entry = {
    ID = row,
    MobName = spawn.CleanName(),
    MobZoneName = mq.TLO.Zone.Name,
    MobLoc = spawn.Loc(),
    MobID = spawn.ID(), -- If you want to include MobID, keep it here
    Enum_Action = 'unhandled',
  }
  return entry
end
local function InsertTableSpawn(dataTable, spawn, row, opts)
  local entry = SpawnToEntry(spawn, row)
  if opts then
    for k,v in pairs(opts) do
        entry[k] = v
    end
  end
  table.insert(dataTable, entry)
end
local function TableSortSpecs(a, b)
  for i = 1, GUI_Main.Table.SortSpecs.SpecsCount do
    local spec = GUI_Main.Table.SortSpecs:Specs(i)
    local delta = 0
    if spec.ColumnUserID == GUI_Main.Table.Column_ID.MobName then
      if a.MobName and b.MobName then
        if a.MobName < b.MobName then
         delta = -1
        elseif a.MobName> b.MobName then
          delta = 1
        end
      else
        return  0
      end
    elseif spec.ColumnUserID == GUI_Main.Table.Column_ID.MobID then
      if a.MobID and b.MobID then
      if a.MobID < b.MobID then
        delta = -1
      elseif a.MobID > b.MobID then
        delta = 1
      end
    else
      return  0
    end
    elseif spec.ColumnUserID == GUI_Main.Table.Column_ID.Action then
      if a.Enum_Action < b.Enum_Action then
        delta = -1
      elseif a.Enum_Action > b.Enum_Action then
        delta = 1
      end
    end
    if delta ~= 0 then
      if spec.SortDirection == ImGuiSortDirection.Ascending then
        return delta < 0
      else
        return delta > 0
      end
    end
  end
  return a.MobName < b.MobName
end
local function RefreshRules()
  Table_Cache.Rules = Database:GetAllRules()
  local newTable = {}
  for k,v in ipairs(Table_Cache.Rules) do
    table.insert(newTable, v.ID, k)
  end
  Lookup.Rules = newTable
  GUI_Main.Refresh.Table.Filtered = true
  GUI_Main.Refresh.Table.Unhandled = true
  GUI_Main.Refresh.Table.Rules = false
end
local function RefreshUnhandled()
  local splitSearch = {}
  for part in string.gmatch(GUI_Main.Search, '[^%s]+') do
    table.insert(splitSearch, part)
  end
  local newTable = {}
  for k,v in ipairs(Table_Cache.Rules) do
    local found = 0
    for _,search in ipairs(splitSearch) do
      if string.find(string.lower(v.MobName), string.lower(search)) then
        found = found + 1
      end
    end
    if #splitSearch == found then
      table.insert(newTable, v)
    end
  end
  Table_Cache.Unhandled = newTable
  GUI_Main.Refresh.Sort.Rules = true
  GUI_Main.Refresh.Table.Unhandled = false
end
local function RefreshFiltered()
  local newTable = {}
  for k,v in ipairs(Table_Cache.Rules) do
    if v.Enum_Action == 'track' then
      table.insert(newTable, v)
    end
  end
  Table_Cache.Filtered = newTable
  GUI_Main.Refresh.Sort.Filtered = true
  GUI_Main.Refresh.Table.Filtered = false
end
local function RefreshZone()
  local newTable = {}
  local zoneName = mq.TLO.Zone.Name
  local npcs = mq.getFilteredSpawns(function(spawn) return spawn.Type() == 'NPC' end)
  mq.cmd('/echo MobCount: Iinit', #npcs)
  for i = 1, #npcs do
    local spawn = npcs[i]

    InsertTableSpawn(newTable, spawn, i)
  end
  --debug: --mq.cmd('/echo MobCount: A', #npcs)
   Table_Cache.Rules = newTable
   -- debug: mq.cmd('/echo TableCount: Rules', #Table_Cache.Rules)
   ---mq.cmd('/echo key: Mobs', Table_Cache.Mobs)
   for k, v in pairs(Table_Cache.Rules) do
    --Debug: -- mq.cmd('/echo ipairs:', k,  v)
    if not CheckRule(v) then
      AddRule(v)
    end
  end
  GUI_Main.Refresh.Sort.Mobs = true
  GUI_Main.Refresh.Table.Mobs = false
end
local function DrawRuleRow(entry)
    ImGui.TableNextColumn()
  ImGui.Text('%s', entry.MobName)
  ImGui.TableNextColumn()
  ImGui.Text('%s', (entry.MobLoc))
  ImGui.TableNextColumn()
  ImGui.Text('%s', (entry.MobZoneName))
  ImGui.TableNextColumn()
  ImGui.Text('%s', (entry.MobID))
  ImGui.TableNextColumn()
  ImGui.SameLine()
    if ImGui.RadioButton("Track##" .. entry.ID, entry.Enum_Action == 'track') then
        entry.Enum_Action = 'track'
        AddRule(entry)
    end
    ImGui.SameLine()
    if ImGui.RadioButton("Ignore##" .. entry.ID, entry.Enum_Action == 'unhandled') then
        entry.Enum_Action = 'unhandled'
        AddRule(entry)
    end
    ImGui.TableNextColumn()
    if ImGui.SmallButton("NavTo##" .. entry.ID) then
       mq.cmd('/nav id ',entry.MobID)
       printf('\ayMoving to \ag%s',entry.MobName)
    end
end
local function DrawMainGUI()
  if GUI_Main.Open then
    GUI_Main.Open = ImGui.Begin("Spawn Master Checker", GUI_Main.Open, GUI_Main.Flags)
    ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, 2, 2)
    if #Table_Cache.Unhandled > 0 then
      ImGui.PushStyleColor(ImGuiCol.Button, ImVec4(1, 0.3, 0.3, 1))
      ImGui.PushStyleColor(ImGuiCol.ButtonHovered, ImVec4(1, 0.4, 0.4, 1))
      ImGui.PushStyleColor(ImGuiCol.ButtonActive, ImVec4(1, 0.5, 0.5, 1))
    end
    if #Table_Cache.Unhandled > 0 then
      ImGui.PopStyleColor(3)
    end
    ImGui.SameLine()
    if ImGui.SmallButton("Refresh Zone") then RefreshZone() end
    ImGui.SameLine()
    if ImGui.SmallButton("...") then  end
    ImGui.PopStyleVar()
    ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, 2, 2)
    if ImGui.BeginTabBar('##TabBar') then
      if ImGui.BeginTabItem(string.format('%s', zoneB)) then
        ImGui.PushItemWidth(-95)
        local searchText, selected = ImGui.InputText("Search##RulesSearch", GUI_Main.Search)
        ImGui.PopItemWidth()
        if selected and GUI_Main.Search ~= searchText then
          GUI_Main.Search = searchText
          GUI_Main.Refresh.Sort.Rules = true
          GUI_Main.Refresh.Table.Unhandled = true
        end
        ImGui.SameLine()
        if ImGui.Button("Clear##ClearRulesSearch") then
          GUI_Main.Search = ''
          GUI_Main.Refresh.Sort.Rules = true
          GUI_Main.Refresh.Table.Unhandled = true
        end
        ImGui.Separator()
        if ImGui.BeginTable('##RulesTable', 6, GUI_Main.Table.Flags) then
          ImGui.TableSetupScrollFreeze(0, 1)

           ImGui.TableSetupColumn("Name", ImGuiTableColumnFlags.DefaultSort, 8, GUI_Main.Table.Column_ID.MobName)
          ImGui.TableSetupColumn("Loc (x,y,z)", ImGuiTableColumnFlags.NoSort, 8, GUI_Main.Table.Column_ID.MobLoc) 
          ImGui.TableSetupColumn("Zone", ImGuiTableColumnFlags.DefaultSort, 8, GUI_Main.Table.Column_ID.MobZoneName)
          ImGui.TableSetupColumn("MobID", ImGuiTableColumnFlags.DefaultSort, 8, GUI_Main.Table.Column_ID.MobID)
          ImGui.TableSetupColumn("Action", ImGuiTableColumnFlags.DefaultSort, 8, GUI_Main.Table.Column_ID.Action)
          ImGui.TableSetupColumn("NavTO", ImGuiTableColumnFlags.DefaultSort, 2, GUI_Main.Table.Column_ID.Remove)
          ImGui.TableHeadersRow()
          local sortSpecs = ImGui.TableGetSortSpecs()
          if sortSpecs and (sortSpecs.SpecsDirty or GUI_Main.Refresh.Sort.Rules) then
            if #Table_Cache.Unhandled > 1 then
              GUI_Main.Table.SortSpecs = sortSpecs
              table.sort(Table_Cache.Unhandled, TableSortSpecs)
              GUI_Main.Table.SortSpecs = nil
            end
            sortSpecs.SpecsDirty = false
            GUI_Main.Refresh.Sort.Rules = false
          end
          local clipper = ImGuiListClipper.new()
          clipper:Begin(#Table_Cache.Unhandled)
          while clipper:Step() do
            for i = clipper.DisplayStart, clipper.DisplayEnd - 1, 1 do
              local entry = Table_Cache.Unhandled[i + 1]
              ImGui.PushID(entry.ID)
              ImGui.TableNextRow()
              DrawRuleRow(entry)
              ImGui.PopID()
            end
          end
          clipper:End()
          ImGui.EndTable()
        end
        ImGui.EndTabItem()
      end
      if #Table_Cache.Filtered > 0 then
        ImGui.PushStyleColor(ImGuiCol.Tab, ImVec4(1, 0.3, 0.3, 1))
        ImGui.PushStyleColor(ImGuiCol.TabHovered, ImVec4(1, 0.4, 0.4, 1))
        ImGui.PushStyleColor(ImGuiCol.TabActive, ImVec4(1, 0.5, 0.5, 1))
      end
      if ImGui.BeginTabItem("Tracking") then
        if ImGui.BeginTable('##FilteredRulesTable', 6, GUI_Main.Table.Flags) then
          ImGui.TableSetupScrollFreeze(0, 1)

           ImGui.TableSetupColumn("Name", ImGuiTableColumnFlags.DefaultSort, 8, GUI_Main.Table.Column_ID.MobName)
          ImGui.TableSetupColumn("Loc (x,y,z)", ImGuiTableColumnFlags.NoSort, 8, GUI_Main.Table.Column_ID.MobLoc) 
          ImGui.TableSetupColumn("Zone", ImGuiTableColumnFlags.DefaultSort, 8, GUI_Main.Table.Column_ID.MobZoneName)
          ImGui.TableSetupColumn("MobID", ImGuiTableColumnFlags.DefaultSort, 8, GUI_Main.Table.Column_ID.MobID)
          ImGui.TableSetupColumn("Action", ImGuiTableColumnFlags.DefaultSort, 8, GUI_Main.Table.Column_ID.Action)
          ImGui.TableSetupColumn("NavTO", ImGuiTableColumnFlags.DefaultSort, 2, GUI_Main.Table.Column_ID.Remove)
          ImGui.TableHeadersRow()
          local sortSpecs = ImGui.TableGetSortSpecs()
          if sortSpecs and (sortSpecs.SpecsDirty or GUI_Main.Refresh.Sort.Filtered) then
            if #Table_Cache.Filtered > 1 then
              GUI_Main.Table.SortSpecs = sortSpecs
              table.sort(Table_Cache.Filtered, TableSortSpecs)
              GUI_Main.Table.SortSpecs = nil
            end
            sortSpecs.SpecsDirty = false
            GUI_Main.Refresh.Sort.Filtered = false
          end
          local clipper = ImGuiListClipper.new()
          clipper:Begin(#Table_Cache.Filtered)
          while clipper:Step() do
            for i = clipper.DisplayStart, clipper.DisplayEnd - 1, 1 do
              local entry = Table_Cache.Filtered[i + 1]
              ImGui.PushID(entry.ID)
              ImGui.TableNextRow()
              DrawRuleRow(entry)
              ImGui.PopID()
            end
          end
          clipper:End()
          ImGui.EndTable()
        end
        ImGui.EndTabItem()
      end
      if #Table_Cache.Filtered > 0 then
        ImGui.PopStyleColor(3)
      end
      ImGui.EndTabBar()
    end
    ImGui.PopStyleVar()
    ImGui.End()
  end
end
local function DrawGUI()
  DrawMainGUI()
end
-- Kickstart the data
RefreshZone()

GUI_Main.Refresh.Table.Rules = true
GUI_Main.Refresh.Table.Filtered = true
GUI_Main.Refresh.Table.Unhandled = true
mq.imgui.init('DrawMainGUI', DrawGUI)
--/commands
mq.bind("/smcreinitialize", ReinitializeDB)
mq.bind("/smcquit", function() GUI_Main.Open = not GUI_Main.Open end)
while GUI_Main.Open do
 zoneB = mq.TLO.Zone.Name
-- Check if the zone has changed
--mq.cmd('/echo ', zoneA, zoneB)
if zoneA ~= zoneB then
    mq.cmd('/echo ', zoneA, zoneB)
    -- Trigger data refresh
    RefreshZone()  
    zoneA = zoneB -- Update zoneA to the new zone

end

  mq.delay(50)
  if GUI_Main.Refresh.Table.Mobs then RefreshRules() end
  if GUI_Main.Refresh.Table.Filtered then RefreshFiltered() end
  if GUI_Main.Refresh.Table.Unhandled then RefreshUnhandled() end
end