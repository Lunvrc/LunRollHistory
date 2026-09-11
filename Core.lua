-- LunRollHistory :: Core.lua
-- Saved variables, event dispatch, defensive value handling, append-only log.

local ADDON, ns = ...

ns.ADDON        = ADDON
ns.VERSION      = "1.2.5"
ns.DB_VERSION   = 1
ns.MAX_ENTRIES  = 20000     -- oldest entries are pruned past this
ns.MAX_CAP      = 1000000   -- highest the History size setting allows
ns.MAX_SCAN     = 100000    -- newest entries the stats pages will walk
ns.PRUNE_SLACK  = 0.02      -- prune this much extra so it happens rarely
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
    if s.sweepOnOpen        == nil then s.sweepOnOpen        = true  end
    if s.maxEntries         == nil then s.maxEntries         = ns.MAX_ENTRIES end
    s.maxEntries = math.max(1000, math.min(ns.MAX_CAP, s.maxEntries))
    if s.accent             == nil then s.accent             = "orchid" end
    if s.accentColor        == nil then s.accentColor        = { ns.Theme.DEFAULT_ACCENT[1],
                                                                ns.Theme.DEFAULT_ACCENT[2],
                                                                ns.Theme.DEFAULT_ACCENT[3] } end
    if s.fontScale          == nil then s.fontScale          = 1.0 end
    if s.minLootQuality     == nil then s.minLootQuality     = 3 end
    if s.lootGearOnly       == nil then s.lootGearOnly       = false end
    if s.ignoreItems        == nil then s.ignoreItems        = {} end
    if s.minimapHide        == nil then s.minimapHide        = false end
    if s.mplusShowNonGear   == nil then s.mplusShowNonGear   = false end
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

    -- table.remove(log, 1) shifts every remaining element, which is 2.8ms at
    -- 200k entries and worse beyond. Doing it once per append past the cap put
    -- a frame hitch on every loot event. Pruning a batch instead makes it rare
    -- and amortises to nothing.
    local count = #log
    if count > ns.MAX_ENTRIES then
        local target = math.max(1, math.floor(ns.MAX_ENTRIES * (1 - ns.PRUNE_SLACK)))
        local drop = count - target
        for i = 1, count - drop do log[i] = log[i + drop] end
        for i = count - drop + 1, count do log[i] = nil end
    end
    return rec
end

-- Rough serialised size of the log. Measured against the real serialiser: a
-- 20-roll drop entry comes to about 4.85 KB, which this reproduces to within a
-- couple of percent.
function ns:EstimateBytes(entries)
    local db = LunRollHistoryDB
    local sampleEntries, sampleRolls = 0, 0
    if db then
        local log = db.log
        local from = math.max(1, #log - 500)
        for i = from, #log do
            local e = log[i]
            sampleEntries = sampleEntries + 1
            if e.t == "drop" and type(e.rolls) == "table" then
                sampleRolls = sampleRolls + #e.rolls
            end
        end
    end
    local avgRolls = (sampleEntries > 0) and (sampleRolls / sampleEntries) or 10
    return math.floor((420 + 225 * avgRolls) * (entries or ns.MAX_ENTRIES))
end

function ns:FormatBytes(bytes)
    if bytes >= 1024 * 1024 * 1024 then
        return string.format("%.1f GB", bytes / 1024 / 1024 / 1024)
    elseif bytes >= 1024 * 1024 then
        return string.format("%.0f MB", bytes / 1024 / 1024)
    end
    return string.format("%.0f KB", bytes / 1024)
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
-- Item classification
--------------------------------------------------------------------------------
-- Weapons and armour. Trinkets are armour, so they count; recipes, patterns,
-- reagents and the rest do not. An item the client has not cached is treated
-- as gear, erring toward showing something rather than hiding a real drop.
local CLASS_WEAPON, CLASS_ARMOR = 2, 4

function ns:IsGearItem(itemID)
    local fn = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
    if not fn or not itemID then return true end
    local ok, _, _, _, _, _, classID = pcall(fn, itemID)
    if not ok or type(classID) ~= "number" then return true end
    return classID == CLASS_WEAPON or classID == CLASS_ARMOR
end

--------------------------------------------------------------------------------
-- Module integrity
--------------------------------------------------------------------------------
-- Updating file by file leaves a mix of versions, and the first symptom is an
-- "attempt to call a nil value" pointing at a line that looks fine. Checking
-- up front turns that into a message naming the file that is out of date.
local REQUIRED = {
    { file = "Theme.lua",   get = function() return ns.Theme and ns.Theme.SetAccent end },
    { file = "Widgets.lua", get = function() return ns.Widgets and ns.Widgets.ColumnHeader end },
    { file = "Luck.lua",    get = function() return ns.Luck and ns.Luck.Compute end },
    { file = "Mythic.lua",  get = function() return ns.Mythic and ns.Mythic.IsGearItem end },
    { file = "UI.lua",      get = function() return ns.UI and ns.UI.Toggle end },
    { file = "Capture.lua", get = function() return ns.SweepAll end },
    { file = "Export.lua",  get = function() return ns.BuildCSV end },
}

function ns:CheckModules()
    local stale = {}
    for _, entry in ipairs(REQUIRED) do
        local ok, value = pcall(entry.get)
        if not ok or not value then stale[#stale + 1] = entry.file end
    end
    ns.staleModules = (#stale > 0) and stale or nil
    return stale
end

--------------------------------------------------------------------------------
-- Deterministic keys
--------------------------------------------------------------------------------
-- Two clients watching the same roll must derive the same key from it, or
-- merging their logs is impossible. That rules out anything the client
-- assigns: the loot-history encounter and list IDs are session-scoped
-- counters, numbered independently per client and restarted on reload, so
-- they identify nothing outside the session that produced them.
--
-- What every witness agrees on is the content: the encounter, the item, who
-- rolled, and what they rolled. Keys are built from that.
--
-- Residual collision: the same player rolling the same number on the same item
-- twice within one encounter produces one key, and the two roles merge into
-- one. That needs a duplicate drop of the same item in a single kill plus a
-- repeated roll value, and the cost when it happens is one undercounted roll.
local function KeyPart(v)
    if v == nil then return "?" end
    return (tostring(v):gsub("[:|%s]", "_"))
end

function ns:DropKey(rec)
    if type(rec) ~= "table" then return nil end
    local item = rec.itemID or rec.item
    if not item then return nil end
    return table.concat({
        "d",
        KeyPart(rec.diffID or 0),
        KeyPart(rec.encName or rec.inst or "?"),
        KeyPart(item),
    }, ":")
end

function ns:RollKey(dropKey, roll)
    if not dropKey or type(roll) ~= "table" or roll.roll == nil then return nil end
    -- GUID where we have it. The name fallback is fine inside a guild but will
    -- not merge cleanly across realms, which is worth knowing rather than
    -- pretending otherwise.
    local who = roll.guid
    if not who or who == "" then
        who = (roll.name or "?") .. "-" .. (roll.realm or "")
    end
    return dropKey .. ":" .. KeyPart(who) .. ":" .. KeyPart(roll.roll)
end

-- Existing logs get keys computed from what they already store, so nothing
-- needs re-recording and no history is lost.
function ns:BackfillKeys()
    local db = LunRollHistoryDB
    if not db or db.keysBackfilled then return 0 end
    local filled = 0
    for i = 1, #db.log do
        local e = db.log[i]
        if e.t == "drop" then
            e.key = e.key or ns:DropKey(e)
            if e.key and type(e.rolls) == "table" then
                for _, r in ipairs(e.rolls) do
                    if not r.key then
                        r.key = ns:RollKey(e.key, r)
                        if r.key then filled = filled + 1 end
                    end
                end
            end
        end
    end
    db.keysBackfilled = true
    return filled
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
    local stale = ns:CheckModules()
    if #stale > 0 then
        ns:Print("|cffff6666Some files are out of date:|r " .. table.concat(stale, ", ")
            .. ". Replace the whole addon folder rather than individual files.")
    end

    local filled = ns:BackfillKeys()
    if filled > 0 then
        ns:Debug("backfilled", filled, "roll keys")
    end
    if ns.OnDBReady then ns.OnDBReady() end
    if ns.migrated then
        ns:Print(("Imported %d entries from the previous RollLedger database."):format(ns.migrated))
    end
end)

ns:On("PLAYER_ENTERING_WORLD", function()
    ApplyDefaults()
    RefreshInstanceContext()
    -- Not a full reset: the client's loot-history IDs remain valid across a
    -- zone change, and forgetting them makes the next sweep re-add every drop.
    if ns.InvalidateIndexes then ns.InvalidateIndexes() end
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
