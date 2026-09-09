-- LunRollHistory :: Core.lua
-- Saved variables, event dispatch, defensive value handling, append-only log.

local ADDON, ns = ...

ns.ADDON        = ADDON
ns.VERSION      = "1.0.0"
ns.DB_VERSION   = 1
ns.MAX_ENTRIES  = 20000   -- oldest entries are pruned past this
ns.debug        = false

--------------------------------------------------------------------------------
-- Secret / restricted value handling
--------------------------------------------------------------------------------
-- Midnight's addon restrictions can hand us "secret" values. Touching one the
-- wrong way throws. We never trust a value straight out of an API: everything
-- goes through Safe* below, and every event handler runs inside pcall.
--
-- If your build exposes a secret-check global under a different name, add it to
-- this list rather than removing the pcall fallbacks.
local isSecret = _G.issecretvalue or _G.issecret or nil

local function Stringify(v)
    return string.format("%s", v)
end

-- Returns a plain string, or `fallback` if the value is secret/unreadable.
function ns:SafeStr(v, fallback)
    if v == nil then return fallback end
    if type(v) == "string" then
        -- Even a string can be secret; format() on it is the cheap probe.
        local ok, s = pcall(Stringify, v)
        return ok and s or fallback
    end
    if isSecret then
        local ok, secret = pcall(isSecret, v)
        if ok and secret then return fallback end
    end
    local ok, s = pcall(Stringify, v)
    if ok and type(s) == "string" then return s end
    return fallback
end

-- Returns a number, or `fallback`.
function ns:SafeNum(v, fallback)
    if v == nil then return fallback end
    if isSecret then
        local ok, secret = pcall(isSecret, v)
        if ok and secret then return fallback end
    end
    local ok, n = pcall(tonumber, v)
    if ok and type(n) == "number" then return n end
    return fallback
end

function ns:SafeBool(v)
    if v == nil then return nil end
    if isSecret then
        local ok, secret = pcall(isSecret, v)
        if ok and secret then return nil end
    end
    return v and true or false
end

-- Reads t[key] for the first key that yields a non-nil value. Blizzard renames
-- struct fields between patches; this survives that without a code change.
function ns:Field(t, ...)
    if type(t) ~= "table" then return nil end
    for i = 1, select("#", ...) do
        local key = select(i, ...)
        local ok, v = pcall(function() return t[key] end)
        if ok and v ~= nil then return v end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------
function ns:Print(...)
    local parts = { "|cff33ff99LunRollHistory|r:" }
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(i, ...)))
    end
    DEFAULT_CHAT_FRAME:AddMessage(table.concat(parts, " "))
end

function ns:Debug(...)
    if ns.debug then ns:Print("[debug]", ...) end
end

--------------------------------------------------------------------------------
-- Event dispatch
--------------------------------------------------------------------------------
local handlers = {}
local frame = CreateFrame("Frame", "LunRollHistoryEventFrame")

-- Registering an event that does not exist in this client version throws;
-- pcall keeps one bad event name from killing the whole addon.
function ns:On(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        local ok = pcall(frame.RegisterEvent, frame, event)
        if not ok then
            ns:Debug("could not register event", event)
        end
    end
    table.insert(handlers[event], fn)
end

frame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then return end
    for i = 1, #list do
        local ok, err = pcall(list[i], ...)
        if not ok then ns:Debug("handler error in", event, err) end
    end
end)

--------------------------------------------------------------------------------
-- Database
--------------------------------------------------------------------------------
local function ApplyDefaults()
    LunRollHistoryDB = LunRollHistoryDB or {}
    local db = LunRollHistoryDB
    db.version  = db.version or ns.DB_VERSION
    db.log      = db.log or {}
    db.nextUID  = db.nextUID or 1
    db.settings = db.settings or {}

    local s = db.settings
    if s.captureLootHistory == nil then s.captureLootHistory = true  end
    if s.captureManualRolls == nil then s.captureManualRolls = true  end
    if s.captureLootAwards  == nil then s.captureLootAwards  = true  end
    if s.captureRollStarts  == nil then s.captureRollStarts  = true  end
    if s.groupOnly          == nil then s.groupOnly          = false end
    if s.maxEntries         == nil then s.maxEntries         = ns.MAX_ENTRIES end
    if s.accent             == nil then s.accent             = "orchid" end
    if s.accentColor        == nil then s.accentColor        = { ns.Theme.DEFAULT_ACCENT[1],
                                                                ns.Theme.DEFAULT_ACCENT[2],
                                                                ns.Theme.DEFAULT_ACCENT[3] } end
    if s.fontScale          == nil then s.fontScale          = 1.0 end
    if s.minLootQuality     == nil then s.minLootQuality     = 3 end
    if s.lootGearOnly       == nil then s.lootGearOnly       = false end
    if s.ignoreItems        == nil then s.ignoreItems        = {} end
    if s.minimapHide        == nil then s.minimapHide        = false end
    if s.minimapAngle       == nil then s.minimapAngle       = 198 end
    ns.MAX_ENTRIES = s.maxEntries

    -- Carry over data from the addon's previous name.
    if type(RollLedgerDB) == "table" and type(RollLedgerDB.log) == "table"
        and #db.log == 0 and #RollLedgerDB.log > 0 then
        db.log = RollLedgerDB.log
        db.nextUID = RollLedgerDB.nextUID or (#db.log + 1)
        ns.migrated = #db.log
    end
end

-- Current instance / encounter context, stamped onto every record.
ns.context = { instance = nil, difficultyID = nil, difficulty = nil,
               encounterID = nil, encounterName = nil }

local function RefreshInstanceContext()
    local ok, name, _, difficultyID, difficultyName = pcall(GetInstanceInfo)
    if ok then
        ns.context.instance     = ns:SafeStr(name, nil)
        ns.context.difficultyID = ns:SafeNum(difficultyID, nil)
        ns.context.difficulty   = ns:SafeStr(difficultyName, nil)
    end
end
ns.RefreshInstanceContext = RefreshInstanceContext

-- Appends a record and returns the same table, so callers can keep the
-- reference and mutate it later (loot history arrives in pieces).
function ns:Append(rec)
    local db = LunRollHistoryDB
    if not db then return rec end

    rec.uid  = db.nextUID
    db.nextUID = db.nextUID + 1
    rec.ts   = rec.ts or GetServerTime()
    rec.inst = rec.inst or ns.context.instance
    rec.diff = rec.diff or ns.context.difficulty
    rec.diffID = rec.diffID or ns.context.difficultyID
    if rec.encName == nil then rec.encName = ns.context.encounterName end

    local log = db.log
    log[#log + 1] = rec

    while #log > ns.MAX_ENTRIES do
        table.remove(log, 1)
    end
    return rec
end

function ns:ShouldCapture()
    if not LunRollHistoryDB then return false end
    if LunRollHistoryDB.settings.groupOnly and not IsInGroup() then return false end
    return true
end

--------------------------------------------------------------------------------
-- Item helpers
--------------------------------------------------------------------------------
-- Splits a hyperlink into the bits worth storing. Never stores a raw value we
-- have not proven to be a readable string.
function ns:ParseItemLink(link)
    local s = ns:SafeStr(link, nil)
    if not s then return nil, nil, nil end
    local itemID = tonumber(s:match("item:(%d+)"))
    local name   = s:match("%[(.-)%]")
    return s, itemID, name
end

--------------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------------
ns:On("ADDON_LOADED", function(name)
    if name ~= ADDON then return end
    ApplyDefaults()
    ns.loaded = true
    ns.Theme:Init()
    ns.Theme:LoadFromSettings(LunRollHistoryDB.settings)
    if ns.OnDBReady then ns.OnDBReady() end
    if ns.migrated then
        ns:Print(("Imported %d entries from the previous RollLedger database."):format(ns.migrated))
    end
end)

ns:On("PLAYER_ENTERING_WORLD", function()
    ApplyDefaults()
    RefreshInstanceContext()
    if ns.ResetTransientState then ns.ResetTransientState() end
end)

ns:On("ZONE_CHANGED_NEW_AREA", RefreshInstanceContext)

ns:On("ENCOUNTER_START", function(encounterID, encounterName, difficultyID, groupSize)
    RefreshInstanceContext()
    ns.context.encounterID   = ns:SafeNum(encounterID, nil)
    ns.context.encounterName = ns:SafeStr(encounterName, nil)
    ns.context.groupSize     = ns:SafeNum(groupSize, nil)
    ns:Debug("encounter start", ns.context.encounterName)
end)

ns:On("ENCOUNTER_END", function(encounterID, encounterName, difficultyID, groupSize, success)
    ns.context.encounterID   = ns:SafeNum(encounterID, ns.context.encounterID)
    ns.context.encounterName = ns:SafeStr(encounterName, ns.context.encounterName)
    ns.context.success       = ns:SafeBool(success)
    ns:Debug("encounter end", ns.context.encounterName, tostring(ns.context.success))
    -- The encounter name stays set: loot rolls resolve after ENCOUNTER_END and
    -- we want them attributed to the boss that just died. It is cleared on the
    -- next ENCOUNTER_START or zone change.
end)
