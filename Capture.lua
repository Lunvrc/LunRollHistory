-- LunRollHistory :: Capture.lua
-- Turns three unrelated data sources into one uniform record stream:
--   1. Group loot Need/Greed/Transmog rolls  (C_LootHistory)
--   2. Manual /roll                          (CHAT_MSG_SYSTEM)
--   3. Actual loot receipt                   (CHAT_MSG_LOOT)

local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Global-string pattern compiler
--------------------------------------------------------------------------------
-- We never hardcode English. Blizzard ships the sentence templates as globals
-- (RANDOM_ROLL_RESULT, LOOT_ITEM, ...) so compiling those keeps every locale
-- working. Some locales use positional specifiers (%2$s), which reorder the
-- captures; AnalyzeFormat records the true argument order so we can remap.

local function AnalyzeFormat(fmt)
    local order = {}
    local normalized = fmt:gsub("%%(%d+)%$([sd])", function(idx, kind)
        order[#order + 1] = tonumber(idx)
        return "%" .. kind
    end)
    if #order == 0 then
        local seq = 0
        for _ in fmt:gmatch("%%[sd]") do
            seq = seq + 1
            order[seq] = seq
        end
    end
    return normalized, order
end

local function BuildPattern(fmt)
    local p = fmt:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    p = p:gsub("%%%%s", "(.+)")
    p = p:gsub("%%%%d", "(%%d+)")
    return "^" .. p .. "$"
end

-- Compile(GLOBAL_STRING) -> matcher(text) -> arg1, arg2, ... in logical order
local function Compile(fmt)
    if type(fmt) ~= "string" then return nil end
    local normalized, order = AnalyzeFormat(fmt)
    local pattern = BuildPattern(normalized)
    return function(text)
        local caps = { string.match(text, pattern) }
        if caps[1] == nil then return nil end
        local out = {}
        for i = 1, #caps do
            out[order[i] or i] = caps[i]
        end
        return unpack(out)
    end
end
ns.Compile = Compile   -- exposed for the test harness


--------------------------------------------------------------------------------
-- Item filter
--------------------------------------------------------------------------------
-- Loot awards fire for everything: reagents, cooking mats, grey vendor trash.
-- Quality comes from the hyperlink's own colour code, which is present the
-- moment the message arrives. GetItemInfo needs the item cached and returns nil
-- until it is, so the link is both faster and more reliable here.
local qualityByHex, qualityColors

local function BuildQualityMap()
    qualityByHex, qualityColors = {}, {}
    if type(ITEM_QUALITY_COLORS) ~= "table" then return end
    for q = 0, 10 do
        local c = ITEM_QUALITY_COLORS[q]
        if type(c) == "table" and c.r then
            -- Blizzard ships a ready-made hex string on each entry; prefer it,
            -- since deriving one from the floats can round a channel off by one.
            local hex = type(c.hex) == "string" and c.hex:match("(%x%x%x%x%x%x)%s*$")
            qualityByHex[(hex or ns.Theme.RGBtoHex(c.r, c.g, c.b)):upper()] = q
            qualityColors[#qualityColors + 1] = { q = q, r = c.r, g = c.g, b = c.b }
        end
    end
end

-- Nearest match in RGB space. Exact string comparison is too brittle: a link
-- and the colour table can disagree by one unit in a channel.
local function NearestQuality(r, g, b)
    local best, bestDist
    for _, c in ipairs(qualityColors or {}) do
        local dr, dg, db = r - c.r, g - c.g, b - c.b
        local dist = dr * dr + dg * dg + db * db
        if not bestDist or dist < bestDist then best, bestDist = c.q, dist end
    end
    if bestDist and bestDist < 0.01 then return best end
    return nil
end

function ns:ItemQuality(link, itemID)
    if type(link) == "string" then
        local hex = link:match("|c%x%x(%x%x%x%x%x%x)")
        if hex then
            if not qualityByHex then BuildQualityMap() end
            local q = qualityByHex[hex:upper()]
            if q then return q end
            local r, g, b = ns.Theme.HexToRGB(hex)
            if r then
                q = NearestQuality(r, g, b)
                if q then return q end
            end
        end
    end
    -- Fallback for links that arrived without colour markup.
    local getter = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo
    if getter and itemID then
        local ok, _, _, quality = pcall(getter, itemID)
        if ok and type(quality) == "number" then return quality end
    end
    return nil
end

local function ItemClassID(itemID)
    local fn = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
    if not fn or not itemID then return nil end
    local ok, _, _, _, _, _, classID = pcall(fn, itemID)
    if ok and type(classID) == "number" then return classID end
    return nil
end

local CLASS_WEAPON, CLASS_ARMOR = 2, 4

function ns:PassesLootFilter(link, itemID)
    local db = LunRollHistoryDB
    local s = db and db.settings
    if not s then return true end

    local minQ = s.minLootQuality or 3
    if minQ > 0 then
        local q = ns:ItemQuality(link, itemID)
        -- Unknown quality is kept: silently dropping a roll would be worse than
        -- logging one extra reagent.
        if q and q < minQ then return false end
    end

    if s.lootGearOnly then
        local classID = ItemClassID(itemID)
        if classID and classID ~= CLASS_WEAPON and classID ~= CLASS_ARMOR then
            return false
        end
    end

    if type(s.ignoreItems) == "table" and itemID and s.ignoreItems[itemID] then
        return false
    end

    return true
end

-- Repairs a log that already contains duplicates, from a build that appended a
-- fresh record on every sweep. Drops sharing an item and an identical set of
-- roll values are the same drop; their rolls are merged and the extra records
-- dropped.
function ns:DeduplicateLog()
    local db = LunRollHistoryDB
    if not db then return 0, 0 end

    local function RollIdentity(r)
        return r.key or ((r.guid or r.name or "?") .. ":" .. tostring(r.roll))
    end

    local byFingerprint, kept = {}, {}
    local removedDrops, mergedRolls = 0, 0

    for i = 1, #db.log do
        local e = db.log[i]
        local fp = (e.t == "drop" and e.itemID) and ns.DropFingerprint(e.itemID, e.rolls) or nil
        local first = fp and byFingerprint[fp]

        if first then
            local existing = {}
            first.rolls = first.rolls or {}
            for _, r in ipairs(first.rolls) do existing[RollIdentity(r)] = r end

            for _, r in ipairs(e.rolls or {}) do
                local prior = existing[RollIdentity(r)]

                -- A copy recorded while the player names were unreadable keys
                -- off a placeholder. Match it on the roll value instead, or the
                -- repair leaves behind the very duplicates it came to remove.
                if not prior and not r.guid and not r.name and r.roll then
                    for _, candidate in ipairs(first.rolls) do
                        if candidate.roll == r.roll then prior = candidate break end
                    end
                end

                if prior then
                    -- Keep the richer of the two records.
                    prior.name  = prior.name or r.name
                    prior.realm = prior.realm or r.realm
                    prior.class = prior.class or r.class
                    prior.guid  = prior.guid or r.guid
                    prior.state = prior.state or r.state
                    prior.key   = prior.key or r.key
                    if r.winner then prior.winner = true end
                    mergedRolls = mergedRolls + 1
                else
                    first.rolls[#first.rolls + 1] = r
                    existing[RollIdentity(r)] = r
                end
            end

            first.encName = first.encName or e.encName
            first.inst    = first.inst or e.inst
            first.diffID  = first.diffID or e.diffID
            first.winner  = first.winner or e.winner
            first.key     = first.key or e.key
            removedDrops = removedDrops + 1
        else
            if fp then byFingerprint[fp] = e end
            kept[#kept + 1] = e
        end
    end

    db.log = kept
    ns.ResetTransientState()
    return removedDrops, mergedRolls
end

-- How many duplicate drops are sitting in the log right now, without changing
-- anything. Reported by /lrh diag.
function ns:CountDuplicates()
    local db = LunRollHistoryDB
    if not db then return 0 end
    local seen, duplicates = {}, 0
    for i = 1, #db.log do
        local e = db.log[i]
        if e.t == "drop" and e.itemID then
            local fp = ns.DropFingerprint(e.itemID, e.rolls)
            if fp then
                if seen[fp] then duplicates = duplicates + 1 else seen[fp] = true end
            end
        end
    end
    return duplicates
end

-- Applies the current filter to entries already on record.
function ns:PruneLog()
    local db = LunRollHistoryDB
    if not db then return 0 end
    local kept, removed = {}, 0
    for i = 1, #db.log do
        local e = db.log[i]
        if e.t == "loot" and not ns:PassesLootFilter(e.link, e.itemID) then
            removed = removed + 1
        else
            kept[#kept + 1] = e
        end
    end
    db.log = kept
    return removed
end

--------------------------------------------------------------------------------
-- 1. Group loot history
--------------------------------------------------------------------------------
local rollStateName = {}   -- numeric enum value -> readable name
local function BuildEnumMap()
    if type(Enum) ~= "table" then return end
    local src = Enum.EncounterLootDropRollState or Enum.LootRollState
    if type(src) ~= "table" then return end
    for name, value in pairs(src) do
        if type(value) == "number" then rollStateName[value] = name end
    end
end

local function DescribeRollState(v)
    local n = ns:SafeNum(v, nil)
    if n == nil then return nil end
    return rollStateName[n] or ("State" .. n)
end

-- Player identity can arrive as a name, a GUID, or a secret. Try in order.
local function ResolvePlayer(rollInfo)
    local name = ns:SafeStr(ns:Field(rollInfo, "playerName", "name"), nil)
    local guid = ns:SafeStr(ns:Field(rollInfo, "playerGUID", "guid", "player"), nil)
    local class = ns:SafeStr(ns:Field(rollInfo, "playerClass", "class", "classFilename"), nil)
    local realm

    if (not name or name == "") and guid and guid:match("^Player%-") then
        local ok, _, engClass, _, _, _, gName, gRealm = pcall(GetPlayerInfoByGUID, guid)
        if ok then
            name  = ns:SafeStr(gName, name)
            realm = ns:SafeStr(gRealm, nil)
            class = class or ns:SafeStr(engClass, nil)
        end
    end

    if name and name:find("-", 1, true) then
        local short, r = name:match("^(.-)%-(.+)$")
        if short then name, realm = short, realm or r end
    end

    return name, realm, class, guid
end

-- Transient, session-scoped. Keyed "encounterID:lootListID" so repeated
-- LOOT_HISTORY_UPDATE_DROP events mutate one record instead of appending
-- a new one for every incoming roll.
local dropRecords = {}

-- Content key -> record, so a drop already in the log is found again after a
-- reload, when the session-scoped IDs have all been renumbered.
local keyIndex

-- A drop identified without reference to where the player is standing now.
-- The encounter name is only knowable while the encounter is the current one,
-- so a key built from live context stops matching the moment you leave the
-- instance, which is precisely when a manual sweep tends to happen.
-- Roll values only, deliberately. Including who rolled looks more precise but
-- is less reliable: a name that comes back secret changes the fingerprint, so
-- the same drop stops matching itself and gets recorded twice. Roll values are
-- the field that survives.
local function Fingerprint(itemID, rolls)
    if not itemID or type(rolls) ~= "table" or #rolls == 0 then return nil end
    local values = {}
    for _, r in ipairs(rolls) do
        if r.roll then values[#values + 1] = r.roll end
    end
    if #values == 0 then return nil end
    table.sort(values)
    return tostring(itemID) .. "|" .. table.concat(values, ",")
end
ns.DropFingerprint = Fingerprint

local fingerprintIndex

local function FingerprintIndex()
    if fingerprintIndex then return fingerprintIndex end
    fingerprintIndex = {}
    local db = LunRollHistoryDB
    if db then
        local from = math.max(1, #db.log - (ns.MAX_SCAN or 100000) + 1)
        for i = from, #db.log do
            local e = db.log[i]
            if e.t == "drop" and e.itemID then
                local fp = Fingerprint(e.itemID, e.rolls)
                if fp then fingerprintIndex[fp] = e end
            end
        end
    end
    return fingerprintIndex
end

local function KeyIndex()
    if keyIndex then return keyIndex end
    keyIndex = {}
    local db = LunRollHistoryDB
    if db then
        local from = math.max(1, #db.log - (ns.MAX_SCAN or 100000) + 1)
        for i = from, #db.log do
            local e = db.log[i]
            if e.t == "drop" and e.key then keyIndex[e.key] = e end
        end
    end
    return keyIndex
end

local function ReadDrop(encounterID, lootListID)
    if not LunRollHistoryDB or not LunRollHistoryDB.settings.captureLootHistory then return end
    if not ns:ShouldCapture() then return end
    if type(C_LootHistory) ~= "table" or not C_LootHistory.GetSortedInfoForDrop then return end

    local ok, info = pcall(C_LootHistory.GetSortedInfoForDrop, encounterID, lootListID)
    if not ok or type(info) ~= "table" then
        ns:Debug("no drop info for", tostring(encounterID), tostring(lootListID))
        return
    end

    local sessionKey = tostring(encounterID) .. ":" .. tostring(lootListID)
    local rec = dropRecords[sessionKey]

    local link, itemID, itemName = ns:ParseItemLink(
        ns:Field(info, "itemHyperlink", "itemLink", "hyperlink"))

    -- Sweeping the same history twice, or reloading mid-raid, used to append a
    -- second copy of every drop. Looking the content key up first makes a
    -- sweep idempotent, which is what allows sweeping often.
    if not rec then
        local candidate = ns:DropKey({
            itemID = itemID, item = itemName,
            diffID = ns.context.difficultyID,
            encName = ns.context.encounterName, inst = ns.context.instance,
        })
        if candidate then
            rec = KeyIndex()[candidate]
        end

        -- Context key missed. Fall back to the roll set, which every sweep of
        -- the same drop reproduces identically no matter where the player is.
        if not rec then
            local incoming = {}
            local infos = ns:Field(info, "rollInfos", "playerRollInfos", "rolls")
            if type(infos) == "table" then
                for i = 1, #infos do
                    local name, _, _, guid = ResolvePlayer(infos[i])
                    incoming[#incoming + 1] = {
                        name = name, guid = guid,
                        roll = ns:SafeNum(ns:Field(infos[i], "roll", "rollValue"), nil),
                    }
                end
            end
            local fp = Fingerprint(itemID, incoming)
            if fp then rec = FingerprintIndex()[fp] end
        end

        if not rec then
            rec = ns:Append({ t = "drop", enc = ns:SafeNum(encounterID, nil),
                              list = ns:SafeNum(lootListID, nil) })
        end
        dropRecords[sessionKey] = rec
    end

    rec.link      = link
    rec.itemID    = itemID
    rec.item      = itemName
    rec.tradeable = ns:SafeBool(ns:Field(info, "isTradeable", "tradeable"))
    rec.allPassed = ns:SafeBool(ns:Field(info, "allPassed"))
    rec.updated   = GetServerTime()

    rec.key = ns:DropKey(rec)
    if rec.key then KeyIndex()[rec.key] = rec end

    -- Rolls are merged by key rather than replaced wholesale, so a client that
    -- saw only part of the roster does not wipe out what another pass caught.
    local rollInfos = ns:Field(info, "rollInfos", "playerRollInfos", "rolls")
    local existing = {}
    rec.rolls = rec.rolls or {}
    for _, r in ipairs(rec.rolls) do
        if r.key then existing[r.key] = r end
    end

    if type(rollInfos) == "table" then
        for i = 1, #rollInfos do
            local ri = rollInfos[i]
            local name, realm, class, guid = ResolvePlayer(ri)
            local isWinner = ns:SafeBool(ns:Field(ri, "isWinner", "winner"))
            local entry = {
                name   = name,
                realm  = realm,
                class  = class,
                guid   = guid,
                roll   = ns:SafeNum(ns:Field(ri, "roll", "rollValue"), nil),
                state  = DescribeRollState(ns:Field(ri, "state", "rollState", "rollType")),
                winner = isWinner,
            }
            entry.key = ns:RollKey(rec.key, entry)

            local prior = entry.key and existing[entry.key]

            -- A roll whose player we cannot read at all keys off a placeholder,
            -- which would not match the same roll seen with a readable name and
            -- would show up as a phantom second roller. Fall back to matching on
            -- the roll value within this drop.
            if not prior and not entry.guid and not entry.name and entry.roll then
                for _, r in ipairs(rec.rolls) do
                    if r.roll == entry.roll then prior = r break end
                end
            end

            if prior then
                -- Fill gaps without discarding anything already known.
                prior.name   = prior.name or entry.name
                prior.realm  = prior.realm or entry.realm
                prior.class  = prior.class or entry.class
                prior.guid   = prior.guid or entry.guid
                prior.state  = prior.state or entry.state
                if entry.winner then prior.winner = true end
            else
                rec.rolls[#rec.rolls + 1] = entry
                if entry.key then existing[entry.key] = entry end
            end
            if isWinner and name then rec.winner = name end
        end
    end
    local rolls = rec.rolls

    local fp = Fingerprint(rec.itemID, rec.rolls)
    if fp then FingerprintIndex()[fp] = rec end
    ns:Debug("drop updated", rec.item or "?", #rolls, "rolls")
end

ns:On("LOOT_HISTORY_UPDATE_DROP", function(encounterID, lootListID)
    ReadDrop(encounterID, lootListID)
end)

ns:On("LOOT_HISTORY_UPDATE_ENCOUNTER", function(encounterID)
    if type(C_LootHistory) ~= "table" then return end
    local getter = C_LootHistory.GetSortedDropsForEncounter
    if not getter then return end
    local ok, drops = pcall(getter, encounterID)
    if not ok or type(drops) ~= "table" then return end
    for i = 1, #drops do
        local listID = ns:Field(drops[i], "lootListID", "listID") or i
        ReadDrop(encounterID, listID)
    end
end)

-- Sweep every known encounter. Cheap insurance against a missed event, and
-- how we backfill rolls that resolved while restrictions were active.
local function SweepAll()
    if type(C_LootHistory) ~= "table" or not C_LootHistory.GetAllEncounterInfos then return end
    local ok, encounters = pcall(C_LootHistory.GetAllEncounterInfos)
    if not ok or type(encounters) ~= "table" then return end
    for i = 1, #encounters do
        local encID = ns:Field(encounters[i], "encounterID", "encounter", "id")
        if encID then
            local getter = C_LootHistory.GetSortedDropsForEncounter
            if getter then
                local ok2, drops = pcall(getter, encID)
                if ok2 and type(drops) == "table" then
                    for j = 1, #drops do
                        ReadDrop(encID, ns:Field(drops[j], "lootListID", "listID") or j)
                    end
                end
            end
        end
    end
end
ns.SweepAll = SweepAll

--------------------------------------------------------------------------------
-- 2. Group loot roll windows (START_LOOT_ROLL)
--------------------------------------------------------------------------------
-- This fires on our own client only, but it is the one place we reliably get
-- the item link plus the roll timer, even if loot history is unavailable.
ns:On("START_LOOT_ROLL", function(rollID)
    if not LunRollHistoryDB or not LunRollHistoryDB.settings.captureRollStarts then return end
    if not ns:ShouldCapture() then return end
    local ok, link = pcall(GetLootRollItemLink, rollID)
    if not ok then return end
    local parsed, itemID, itemName = ns:ParseItemLink(link)
    if not parsed then return end
    ns:Append({ t = "rollstart", rollID = ns:SafeNum(rollID, nil),
                link = parsed, itemID = itemID, item = itemName })
end)

--------------------------------------------------------------------------------
-- Sweep scheduling
--------------------------------------------------------------------------------
-- The client holds loot history for a while and then discards it. Reading it
-- only when the window happens to be opened means anything missed while the
-- window was shut can be gone by the time anyone looks. These triggers read it
-- close to when it appears instead.
--
-- Repeating a sweep is free now that drops merge on their content key, so the
-- schedule can be generous rather than careful.
local lastSweep = 0
local SWEEP_THROTTLE = 2

local function SweepNow()
    local now = GetServerTime()
    if now - lastSweep < SWEEP_THROTTLE then return end
    lastSweep = now
    -- Through the public entry point, so anything that replaces or wraps the
    -- sweep is honoured rather than quietly bypassed.
    pcall(ns.SweepAll)
end
ns.SweepNow = SweepNow

-- Loot history settles over several seconds after a kill, so one read is not
-- enough; these fire at spread intervals rather than all at once.
local function SweepSoon(delays)
    if not (C_Timer and C_Timer.After) then
        SweepNow()
        return
    end
    for _, delay in ipairs(delays) do
        C_Timer.After(delay, function()
            lastSweep = 0        -- scheduled sweeps bypass the throttle
            SweepNow()
        end)
    end
end
ns.SweepSoon = SweepSoon

local function InGroupContent()
    local ok, inInstance = pcall(IsInInstance)
    if not ok or not inInstance then return false end
    local okGroup, grouped = pcall(IsInGroup)
    return okGroup and grouped
end

ns:On("LOOT_ROLLS_COMPLETE", function() SweepNow() end)
ns:On("ENCOUNTER_END", function() SweepSoon({ 2, 6, 15 }) end)
ns:On("BOSS_KILL", function() SweepSoon({ 3, 10 }) end)
ns:On("LOOT_CLOSED", function() SweepSoon({ 1 }) end)

-- Leaving combat is when anything missed during the pull becomes readable.
ns:On("PLAYER_REGEN_ENABLED", function()
    if InGroupContent() then SweepSoon({ 1, 5 }) end
end)

-- Backstop for events that never arrive at all.
local ticker
local function StartTicker()
    if ticker or not (C_Timer and C_Timer.NewTicker) then return end
    local ok, handle = pcall(C_Timer.NewTicker, 30, function()
        if InGroupContent() then SweepNow() end
    end)
    if ok then ticker = handle end
end
ns:On("PLAYER_ENTERING_WORLD", StartTicker)

--------------------------------------------------------------------------------
-- 3. Manual /roll
--------------------------------------------------------------------------------
local matchRandomRoll

ns:On("CHAT_MSG_SYSTEM", function(msg)
    if not LunRollHistoryDB or not LunRollHistoryDB.settings.captureManualRolls then return end
    if not ns:ShouldCapture() then return end
    if not matchRandomRoll then return end

    -- msg can be a secret value during an active encounter or M+ run, in which
    -- case string.match throws. pcall means we skip it instead of erroring out.
    local ok, name, roll, low, high = pcall(matchRandomRoll, msg)
    if not ok or not name then return end

    local realm
    if name:find("-", 1, true) then
        local short, r = name:match("^(.-)%-(.+)$")
        if short then name, realm = short, r end
    end

    ns:Append({
        t = "manualroll",
        name = name, realm = realm,
        roll = tonumber(roll), low = tonumber(low), high = tonumber(high),
    })
end)

--------------------------------------------------------------------------------
-- 4. Loot awards (who actually ended up holding the item)
--------------------------------------------------------------------------------
local lootMatchers = {}

local function BuildLootMatchers()
    -- Order matters: the "xN" variants must be tried before the plain ones,
    -- and self variants have no player capture.
    local specs = {
        { fmt = LOOT_ITEM_MULTIPLE,          self = false, qty = true  },
        { fmt = LOOT_ITEM,                   self = false, qty = false },
        { fmt = LOOT_ITEM_PUSHED_SELF_MULTIPLE, self = true, qty = true  },
        { fmt = LOOT_ITEM_SELF_MULTIPLE,     self = true,  qty = true  },
        { fmt = LOOT_ITEM_PUSHED_SELF,       self = true,  qty = false },
        { fmt = LOOT_ITEM_SELF,              self = true,  qty = false },
    }
    for _, spec in ipairs(specs) do
        local matcher = Compile(spec.fmt)
        if matcher then
            lootMatchers[#lootMatchers + 1] = {
                match = matcher, isSelf = spec.self, hasQty = spec.qty,
            }
        end
    end
end

ns:On("CHAT_MSG_LOOT", function(msg)
    if not LunRollHistoryDB or not LunRollHistoryDB.settings.captureLootAwards then return end
    if not ns:ShouldCapture() then return end

    for i = 1, #lootMatchers do
        local m = lootMatchers[i]
        local ok, a, b, c = pcall(m.match, msg)
        if ok and a ~= nil then
            local player, link, qty
            if m.isSelf then
                player = UnitName("player")
                link, qty = a, b
            else
                player, link, qty = a, b, c
            end
            local parsed, itemID, itemName = ns:ParseItemLink(link)
            if parsed and ns:PassesLootFilter(parsed, itemID) then
                local realm
                if player and player:find("-", 1, true) then
                    local short, r = player:match("^(.-)%-(.+)$")
                    if short then player, realm = short, r end
                end
                local rec = ns:Append({
                    t = "loot", name = player, realm = realm,
                    link = parsed, itemID = itemID, item = itemName,
                    qty = tonumber(qty) or 1,
                })
                -- If a Mythic+ run just finished, this may be chest loot.
                if ns.Mythic then ns.Mythic:NoteLoot(rec) end
            end
            return
        end
    end
end)

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------
-- Full reset. Only for when the log itself is thrown away: the loot-history
-- session IDs stay valid for the whole client session, so discarding this map
-- on a zone change made every drop look new again on the next sweep.
function ns.ResetTransientState()
    dropRecords = {}
    keyIndex = nil
    fingerprintIndex = nil
end

-- Zoning invalidates the derived indexes but not the session map.
function ns.InvalidateIndexes()
    keyIndex = nil
    fingerprintIndex = nil
end

local prevOnDBReady = ns.OnDBReady
function ns.OnDBReady()
    if prevOnDBReady then prevOnDBReady() end
    BuildEnumMap()
    matchRandomRoll = Compile(RANDOM_ROLL_RESULT)
    BuildLootMatchers()
    if not matchRandomRoll then
        ns:Debug("RANDOM_ROLL_RESULT unavailable; /roll capture disabled")
    end
end
