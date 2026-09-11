-- LunRollHistory :: Mythic.lua
-- Mythic+ run tracking.
--
-- The end-of-run chest hands out a number of items that has changed between
-- expansions and differs for untimed runs. Rather than hardcode a rule that
-- will quietly go stale, every run records how many items the chest actually
-- gave the group. Your expected share of a run is then items/party, summed
-- across runs, which is the same expectation model the raid page already uses
-- and needs no constants at all.

local ADDON, ns = ...

local M = {}
ns.Mythic = M

M.LOOT_WINDOW = 45         -- seconds after completion to attribute chest loot
M.MIN_RUNS = 3             -- below this a per-dungeon rating means nothing

--------------------------------------------------------------------------------
-- Current character
--------------------------------------------------------------------------------
-- "You opened X chests" has to mean this character's chests. Runs are stamped
-- with who ran them; anything recorded before this existed carries no stamp and
-- is still shown, since hiding a player's existing history without explanation
-- would be worse than pooling it.
function M:CharacterKey()
    local ok, name = pcall(UnitName, "player")
    if not ok or type(name) ~= "string" or name == "" then return nil end
    local okRealm, realm = pcall(GetRealmName)
    if okRealm and type(realm) == "string" and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

--------------------------------------------------------------------------------
-- Season dungeon list
--------------------------------------------------------------------------------
-- Read from the client, so a new season needs no code change. The override
-- table below is the only thing worth touching by hand, and only when the
-- generated abbreviation is not the one your group actually says out loud.
M.ABBREVIATIONS = {
    -- [mapChallengeModeID] = "RLP",
}

local MINOR_WORDS = {
    ["of"] = true, ["the"] = true, ["and"] = true, ["to"] = true,
    ["in"] = true, ["a"] = true, ["at"] = true,
}

function M:Abbreviate(mapID, name)
    local override = self.ABBREVIATIONS[mapID]
    if override then return override end
    if type(name) ~= "string" or name == "" then return "?" end

    local words = {}
    for word in name:gmatch("[%w']+") do words[#words + 1] = word end
    if #words == 0 then return "?" end
    if #words == 1 then return words[1]:sub(1, 3):upper() end

    local out = {}
    for i, word in ipairs(words) do
        local lower = word:lower()
        -- Minor words stay lowercase, matching how these get written in chat:
        -- "Throne of the Tides" reads better as TotT than TOTT. The first word
        -- is always capitalised though, or "The Nokhud Offensive" comes out as
        -- tNO with a lowercase leading letter.
        if i > 1 and MINOR_WORDS[lower] then
            out[#out + 1] = lower:sub(1, 1)
        else
            out[#out + 1] = word:sub(1, 1):upper()
        end
    end
    local abbr = table.concat(out)
    return (#abbr > 4) and abbr:sub(1, 4) or abbr
end

local mapInfoCache = {}

function M:MapInfo(mapID)
    if not mapID then return nil end
    local cached = mapInfoCache[mapID]
    if cached then return cached end
    if type(C_ChallengeMode) ~= "table" or not C_ChallengeMode.GetMapUIInfo then return nil end

    local ok, name, id, timeLimit, texture, background =
        pcall(C_ChallengeMode.GetMapUIInfo, mapID)
    if not ok or not name then return nil end

    local info = {
        mapID = mapID,
        name = ns:SafeStr(name, "Unknown"),
        timeLimit = ns:SafeNum(timeLimit, nil),
        texture = texture,
        background = background,
    }
    info.abbr = self:Abbreviate(mapID, info.name)
    mapInfoCache[mapID] = info
    return info
end

-- Current season's dungeons, falling back to whatever has actually been run if
-- the client will not tell us.
function M:SeasonMaps()
    local maps, seen = {}, {}

    if type(C_ChallengeMode) == "table" and C_ChallengeMode.GetMapTable then
        local ok, list = pcall(C_ChallengeMode.GetMapTable)
        if ok and type(list) == "table" then
            for _, mapID in ipairs(list) do
                if not seen[mapID] then
                    seen[mapID] = true
                    maps[#maps + 1] = mapID
                end
            end
        end
    end

    local db = LunRollHistoryDB
    if db then
        for i = 1, #db.log do
            local e = db.log[i]
            if e.t == "mplus" and e.mapID and not seen[e.mapID] then
                seen[e.mapID] = true
                maps[#maps + 1] = e.mapID
            end
        end
    end

    table.sort(maps, function(a, b)
        local ia, ib = self:MapInfo(a), self:MapInfo(b)
        return (ia and ia.name or tostring(a)) < (ib and ib.name or tostring(b))
    end)
    return maps
end

--------------------------------------------------------------------------------
-- Warbound detection
--------------------------------------------------------------------------------
-- Read off the tooltip, since there is no field for it. Wrapped tightly: under
-- Midnight's restrictions tooltip data can come back unreadable, and an item
-- we cannot classify is simply recorded as not warbound rather than dropped.
function M:IsWarbound(link)
    local marker = _G.ITEM_ACCOUNTBOUND_UNTIL_EQUIP
    if type(marker) ~= "string" or type(link) ~= "string" then return nil end
    if type(C_TooltipInfo) ~= "table" or not C_TooltipInfo.GetHyperlink then return nil end

    local ok, data = pcall(C_TooltipInfo.GetHyperlink, link)
    if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then return nil end

    for _, line in ipairs(data.lines) do
        local text = ns:SafeStr(line and line.leftText, nil)
        if text and text:find(marker, 1, true) then return true end
    end
    return false
end

--------------------------------------------------------------------------------
-- Run capture
--------------------------------------------------------------------------------
local activeRun          -- the run record currently accepting chest loot
local windowClosesAt

local function PartySize()
    local ok, n = pcall(GetNumGroupMembers)
    if ok and type(n) == "number" and n > 0 then return n end
    return 5
end

function M:IsWindowOpen()
    if not activeRun then return false end
    if windowClosesAt and GetServerTime() > windowClosesAt then
        activeRun = nil
        return false
    end
    return true
end

function M:CloseWindow()
    activeRun = nil
    windowClosesAt = nil
end

-- Two sources feed this: parsed chat, and ENCOUNTER_LOOT_RECEIVED. Chat
-- wording varies and can be missing entirely; the event is structured but does
-- not fire everywhere. Taking both and de-duplicating is more reliable than
-- betting on either.
-- Matching on the item id where there is one, falling back to the name. An
-- unparsable link used to mean no id, which meant no match, which meant the
-- same item counted once from chat and once from the event.
local function AlreadyRecorded(run, player, itemID, itemName)
    for _, item in ipairs(run.items or {}) do
        if item.name == player then
            -- Ids match when both sides have one...
            if itemID and item.itemID and item.itemID == itemID then return true end
            -- ...and otherwise the name settles it. One source having an id and
            -- the other not is the normal case, not an edge case: comparing
            -- only ids let the same item through twice.
            if itemName and item.item and item.item == itemName then return true end
        end
    end
    return false
end

-- Lives in Core, where every file can reach it regardless of load order.
local function IsGear(itemID)
    return ns:IsGearItem(itemID)
end

function M:IsGearItem(itemID)
    return IsGear(itemID)
end

function M:AddItem(player, itemID, itemName, link, source)
    if not self:IsWindowOpen() or not player then return false end
    -- A keystone chest hands out gear. Anything else picked up while the window
    -- is open is someone looting in the dungeon, not the chest.
    if not IsGear(itemID) then return false end
    if AlreadyRecorded(activeRun, player, itemID, itemName) then return false end

    activeRun.items = activeRun.items or {}
    activeRun.items[#activeRun.items + 1] = {
        name = player,
        itemID = itemID,
        item = itemName,
        link = link,
        warbound = self:IsWarbound(link),
        source = source,
    }
    ns:Debug("mythic+ chest item", player, itemName or itemID, source)
    return true
end

-- Called by the loot capture for every item award while a run window is open.
function M:NoteLoot(rec)
    if not rec or not self:IsWindowOpen() then return end
    if not rec.name then return end

    if self:AddItem(rec.name, rec.itemID, rec.item, rec.link, "chat") then
        rec.runUID = activeRun.uid
        rec.mapID = activeRun.mapID
    end
end

-- Raw record of what arrives during a run window, before any pattern matching
-- or quality filtering. When nothing is attributed to a run this is the only
-- way to tell whether the messages never came, or came in a shape we did not
-- recognise.
M.rawLoot = {}

ns:On("CHAT_MSG_LOOT", function(msg)
    if not M:IsWindowOpen() then return end
    local text = ns:SafeStr(msg, "<unreadable value>")
    M.rawLoot[#M.rawLoot + 1] = text
    while #M.rawLoot > 40 do table.remove(M.rawLoot, 1) end
end)

ns:On("ENCOUNTER_LOOT_RECEIVED", function(encounterID, itemID, itemLink, quantity, playerName)
    M.lastEncounterLoot = GetServerTime()
    if not M:IsWindowOpen() then return end
    local name = ns:SafeStr(playerName, nil)
    if name and name:find("-", 1, true) then name = name:match("^(.-)%-") or name end
    local link, parsedID, itemName = ns:ParseItemLink(itemLink)
    M:AddItem(name, ns:SafeNum(itemID, parsedID), itemName, link, "event")
end)

-- Which dungeon is being run, and at what key level. Tracked continuously,
-- because the completion data is not always readable at the moment the run
-- ends. Both must be declared above OnCompleted: a local declared below it
-- would be a different, always-nil global as far as that function is
-- concerned.
local activeMapID
local activeLevel

local function ReadActiveMap()
    if type(C_ChallengeMode) ~= "table" then return nil end
    local ok, id = pcall(C_ChallengeMode.GetActiveChallengeMapID)
    if ok and type(id) == "number" and id > 0 then return id end
    return nil
end

-- Last resort: match the instance we are standing in against the season list.
local function MapIDFromInstanceName()
    local name = ns.context and ns.context.instance
    if type(name) ~= "string" or name == "" then return nil end
    for _, mapID in ipairs(M:SeasonMaps()) do
        local info = M:MapInfo(mapID)
        if info and info.name == name then return mapID end
    end
    return nil
end

-- Completion data has been returned both as a flat tuple and as a struct
-- across versions, and the function has carried more than one name. Reading
-- only the tuple form meant a struct-returning client resolved nothing: the
-- dungeon still came from a fallback, so a run looked recorded while its key
-- level and timed flag were quietly missing.
local COMPLETION_GETTERS = { "GetCompletionInfo", "GetChallengeCompletionInfo" }

local function ReadCompletion()
    if type(C_ChallengeMode) ~= "table" then return nil end
    for _, fname in ipairs(COMPLETION_GETTERS) do
        local fn = C_ChallengeMode[fname]
        if type(fn) == "function" then
            local packed = { pcall(fn) }
            if packed[1] then
                local first = packed[2]
                if type(first) == "table" then
                    local mapID = first.mapChallengeModeID or first.mapID
                        or first.challengeModeID
                    if type(mapID) == "number" and mapID > 0 then
                        return {
                            mapID = mapID,
                            level = first.level,
                            time = first.time or first.totalTime or first.durationMS,
                            onTime = first.onTime,
                            upgrades = first.keystoneUpgradeLevels,
                            shape = fname .. "/struct",
                        }
                    end
                elseif type(first) == "number" and first > 0 then
                    return {
                        mapID = first, level = packed[3], time = packed[4],
                        onTime = packed[5], upgrades = packed[6],
                        shape = fname .. "/tuple",
                    }
                end
            end
        end
    end
    return nil
end

-- Fills in whatever the client will tell us. Returns true once the map is
-- known, which is the only field the statistics actually require.
local function ResolveCompletion(run)
    local info = ReadCompletion()
    if info then
        M.lastCompletionShape = info.shape
        run.mapID = info.mapID
        run.level = ns:SafeNum(info.level, run.level)
        run.durationMS = ns:SafeNum(info.time, run.durationMS)
        run.timed = ns:SafeBool(info.onTime)
        run.upgrades = ns:SafeNum(info.upgrades, run.upgrades)
    end

    -- Last resort for the timer: compare the run against the map's own limit.
    if run.timed == nil and run.durationMS and run.mapID then
        local mapInfo = M:MapInfo(run.mapID)
        if mapInfo and mapInfo.timeLimit and mapInfo.timeLimit > 0 then
            run.timed = (run.durationMS / 1000) <= mapInfo.timeLimit
            run.timedInferred = true
        end
    end

    if not run.mapID or run.mapID == 0 then
        run.mapID = activeMapID or ReadActiveMap() or MapIDFromInstanceName()
    end

    if run.mapID then
        local info = M:MapInfo(run.mapID)
        if info then run.mapName = info.name end
        return true
    end
    return false
end

local function OnCompleted()
    M.lastCompletionAt = GetServerTime()

    -- The record is created immediately, before the completion data is known.
    -- Waiting for it meant a run where GetCompletionInfo was not ready yet was
    -- dropped entirely and silently, and the chest loot went with it.
    activeRun = ns:Append({
        t = "mplus",
        mapID = activeMapID or ReadActiveMap() or MapIDFromInstanceName(),
        level = activeLevel,
        party = PartySize(),
        char = M:CharacterKey(),
        items = {},
    })
    windowClosesAt = GetServerTime() + M.LOOT_WINDOW

    local attempts = 0
    local function Try()
        attempts = attempts + 1
        local resolved = ResolveCompletion(activeRun or {})
        M.lastResolveAttempts = attempts
        M.lastResolved = resolved
        ns:Debug("mythic+ completion attempt", attempts,
            resolved and (activeRun and activeRun.mapName or "?") or "unresolved")
        if resolved or attempts >= 12 then return end
        if C_Timer and C_Timer.After then
            C_Timer.After(0.5, Try)
        end
    end
    Try()
end

ns:On("CHALLENGE_MODE_COMPLETED", OnCompleted)
ns:On("CHALLENGE_MODE_START", function()
    M:CloseWindow()
    activeMapID = ReadActiveMap()
    if type(C_ChallengeMode) == "table" and C_ChallengeMode.GetActiveKeystoneInfo then
        local ok, level = pcall(C_ChallengeMode.GetActiveKeystoneInfo)
        if ok then activeLevel = ns:SafeNum(level, nil) end
    end
end)
ns:On("CHALLENGE_MODE_RESET", function() M:CloseWindow() end)
ns:On("PLAYER_LEAVING_WORLD", function() M:CloseWindow() end)
-- Keep the tracked map current, and clear it on the way out. Holding a stale
-- ID meant the next run could be attributed to the previous dungeon, which is
-- a far worse failure than not knowing at all.
local function RefreshActiveMap()
    local live = ReadActiveMap()
    if live then
        activeMapID = live
    elseif not M:IsWindowOpen() then
        -- Keep it while chest loot is still arriving; the client clears the
        -- active map before the chest is looted.
        activeMapID = nil
    end
end

ns:On("PLAYER_ENTERING_WORLD", RefreshActiveMap)
ns:On("ZONE_CHANGED_NEW_AREA", RefreshActiveMap)

-- Manual recovery for a run the client never announced.
function M:RecordRunManually()
    -- Manual recovery trusts where you are standing now over anything cached.
    local mapID = ReadActiveMap() or MapIDFromInstanceName() or activeMapID
    if not mapID then return nil end
    activeRun = ns:Append({
        t = "mplus", mapID = mapID,
        mapName = (self:MapInfo(mapID) or {}).name,
        party = PartySize(), char = M:CharacterKey(),
        items = {}, manual = true,
    })
    windowClosesAt = GetServerTime() + self.LOOT_WINDOW
    return activeRun
end

function M:ActiveMapID()
    return ReadActiveMap() or activeMapID or MapIDFromInstanceName()
end

--------------------------------------------------------------------------------
-- Statistics
--------------------------------------------------------------------------------
-- Per dungeon: how often you ran it, how the chest treated you, and every item
-- the group has seen drop there.
function M:Compute(playerName)
    local db = LunRollHistoryDB
    local byMap, order = {}, {}
    local totals = { runs = 0, timed = 0, mine = 0, expected = 0, expVar = 0,
                     warbound = 0, groupItems = 0 }
    if not db then return order, byMap, totals end

    local function Bucket(mapID)
        local bucket = byMap[mapID]
        if not bucket then
            local info = (mapID ~= "unknown") and self:MapInfo(mapID) or nil
            bucket = {
                mapID = mapID,
                name = info and info.name
                    or (mapID == "unknown" and "Unrecognised runs")
                    or ("Map " .. tostring(mapID)),
                abbr = info and info.abbr or "???",
                texture = info and info.texture or nil,
                runs = 0, timed = 0, mine = 0, groupItems = 0,
                expected = 0, expVar = 0, warbound = 0,
                levelSum = 0, items = {}, itemOrder = {},
            }
            byMap[mapID] = bucket
            order[#order + 1] = bucket
        end
        return bucket
    end

    -- Seed a bucket for every dungeon in the season, so the grid shows all of
    -- them including the ones never run.
    for _, mapID in ipairs(self:SeasonMaps()) do Bucket(mapID) end

    local me = self:CharacterKey()
    local from = math.max(1, #db.log - (ns.MAX_SCAN or 100000) + 1)
    for i = from, #db.log do
        local e = db.log[i]
        -- This character's runs only. Records from before runs were stamped
        -- carry no character and are still counted.
        local mine = (e.char == nil) or (me == nil) or (e.char == me)
        -- A run whose dungeon never resolved is still a run. Bucketing it under
        -- a placeholder keeps it visible instead of silently vanishing, which
        -- is how the original problem hid itself.
        if e.t == "mplus" and mine then
            local b = Bucket(e.mapID or "unknown")
            b.runs = b.runs + 1
            b.levelSum = b.levelSum + (e.level or 0)
            if e.timed then b.timed = b.timed + 1 end

            local items = (type(e.items) == "table") and e.items or {}
            local party = math.max(1, e.party or 5)
            local awarded = #items
            b.groupItems = b.groupItems + awarded

            -- Your share of this run's chest. No 2-of-5 constant anywhere:
            -- whatever the chest actually gave, divided by the group.
            local p = math.min(1, awarded / party)
            b.expected = b.expected + p
            b.expVar = b.expVar + p * (1 - p)

            for _, item in ipairs(items) do
                local key = item.itemID or item.item
                if key then
                    local entry = b.items[key]
                    if not entry then
                        entry = { itemID = item.itemID, name = item.item,
                                  link = item.link, count = 0, mine = 0, warbound = 0 }
                        b.items[key] = entry
                        b.itemOrder[#b.itemOrder + 1] = entry
                    end
                    entry.count = entry.count + 1
                    if item.warbound then
                        entry.warbound = entry.warbound + 1
                        b.warbound = b.warbound + 1
                    end
                    if playerName and item.name == playerName then
                        entry.mine = entry.mine + 1
                        b.mine = b.mine + 1
                    end
                end
            end
        end
    end

    for _, b in ipairs(order) do
        b.avgLevel = (b.runs > 0) and (b.levelSum / b.runs) or 0
        b.timedRate = (b.runs > 0) and (b.timed / b.runs) or 0
        b.enough = b.runs >= self.MIN_RUNS
        if b.expVar > 0 then
            b.z = (b.mine - b.expected) / math.sqrt(b.expVar)
            b.luck = ns.Luck.NormalCDF(b.z) * 100
        end
        table.sort(b.itemOrder, function(x, y)
            if x.count ~= y.count then return x.count > y.count end
            return (x.name or "") < (y.name or "")
        end)

        totals.runs = totals.runs + b.runs
        totals.timed = totals.timed + b.timed
        totals.mine = totals.mine + b.mine
        totals.groupItems = totals.groupItems + b.groupItems
        totals.expected = totals.expected + b.expected
        totals.expVar = totals.expVar + b.expVar
        totals.warbound = totals.warbound + b.warbound
    end

    if totals.expVar > 0 then
        totals.z = (totals.mine - totals.expected) / math.sqrt(totals.expVar)
        totals.luck = ns.Luck.NormalCDF(totals.z) * 100
    end
    totals.enough = totals.runs >= self.MIN_RUNS

    -- Drop the placeholder bucket unless something actually landed in it.
    if byMap.unknown and byMap.unknown.runs == 0 then
        byMap.unknown = nil
        for i, b in ipairs(order) do
            if b.mapID == "unknown" then table.remove(order, i) break end
        end
    end

    table.sort(order, function(a, b) return a.name < b.name end)
    return order, byMap, totals
end

--------------------------------------------------------------------------------
-- Loot specialization
--------------------------------------------------------------------------------
function M:CurrentSpecName()
    local specID
    local ok, loot = pcall(GetLootSpecialization)
    if ok and type(loot) == "number" and loot > 0 then
        specID = loot
    else
        local ok2, index = pcall(GetSpecialization)
        if ok2 and index then
            local ok3, id = pcall(GetSpecializationInfo, index)
            if ok3 then specID = id end
        end
    end
    if not specID then return nil end
    local ok4, _, name = pcall(GetSpecializationInfoByID, specID)
    if ok4 and name then return name, specID end
    return nil, specID
end

--------------------------------------------------------------------------------
-- Encounter Journal loot tables
--------------------------------------------------------------------------------
-- The journal knows what *can* drop in a dungeon, which is the more useful
-- number than what has: it shows the trinket that has never once appeared.
--
-- There is no published mapping from a challenge-mode map to a journal
-- instance, so they are matched by name. That is fragile, hence the cache, the
-- pcall around every call, and the fall back to observed drops when the match
-- or the API is unavailable.
local journalByName
local lootCache = {}

local function EJCall(name, ...)
    local fn = _G[name]
    if type(fn) ~= "function" then return nil end
    local results = { pcall(fn, ...) }
    if not results[1] then return nil end
    return unpack(results, 2)
end

-- Reading the journal means driving it: selecting an instance, a difficulty
-- and a loot filter. That state is global and shared with Blizzard's own
-- Encounter Journal window.
--
-- Trying to save and put back exactly what the player had did not hold up:
-- the getters are not all present, and there is no getter at all for the
-- selected encounter. So instead of guessing, the journal is left in one
-- known state after every read - current loot specialisation, all slots,
-- Mythic difficulty - which is how these dungeons get looked at anyway.
M.JOURNAL_DIFFICULTY = 23      -- Mythic

local function AllSlots()
    local enum = _G.Enum and _G.Enum.ItemSlotFilterType
    if enum and enum.NoFilter then return enum.NoFilter end
    return 0
end

local function NormaliseJournal()
    EJCall("EJ_SetDifficulty", M.JOURNAL_DIFFICULTY)

    local classID = select(3, UnitClass("player"))
    local _, specID = M:CurrentSpecName()
    if classID and specID then
        EJCall("EJ_SetLootFilter", classID, specID)
    end

    -- All slots: a slot filter left over from a previous read would hide most
    -- of the table without any indication why.
    if C_EncounterJournal and C_EncounterJournal.SetSlotFilter then
        pcall(C_EncounterJournal.SetSlotFilter, AllSlots())
    else
        EJCall("EJ_SetSlotFilter", AllSlots())
    end
end
M.NormaliseJournal = NormaliseJournal

-- The instance is the one thing worth putting back: it is what the player is
-- reading, and unlike the filters it is not something they would want reset.
local function SelectedInstance()
    return EJCall("EJ_GetCurrentInstance")
end

local function BuildJournalIndex()
    if journalByName then return journalByName end
    journalByName = {}

    local numTiers = EJCall("EJ_GetNumTiers")
    if type(numTiers) ~= "number" then
        journalByName = nil
        return {}
    end
    local savedTier, savedInstance = EJCall("EJ_GetCurrentTier"), SelectedInstance()

    for tier = 1, numTiers do
        if EJCall("EJ_SelectTier", tier) ~= nil or true then
            local index = 1
            while index < 100 do
                local instanceID, name = EJCall("EJ_GetInstanceByIndex", index, false)
                if not instanceID then break end
                if type(name) == "string" then
                    -- Later tiers win: a dungeon reused in a new season should
                    -- resolve to its current journal entry.
                    journalByName[name:lower()] = instanceID
                end
                index = index + 1
            end
        end
    end

    if savedTier then EJCall("EJ_SelectTier", savedTier) end
    if savedInstance then EJCall("EJ_SelectInstance", savedInstance) end
    NormaliseJournal()
    return journalByName
end

function M:JournalInstanceFor(mapID)
    local info = self:MapInfo(mapID)
    if not info or not info.name then return nil end
    local index = BuildJournalIndex()
    return index[info.name:lower()]
end

-- The journal hands back an item ID long before the client has the item's
-- details cached, so the name comes back nil on a first look and the interface
-- had nothing to show but the number. Ask the client, and failing that ask it
-- to load the item so a later pass can fill it in.
local pendingNames = {}

local function ItemNameFor(itemID, fallback)
    if fallback and fallback ~= "" then return fallback end
    if not itemID then return nil end

    local getter = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo
    if getter then
        local ok, name = pcall(getter, itemID)
        if ok and type(name) == "string" and name ~= "" then return name end
    end

    -- Not cached yet. Request it; ITEM_DATA_LOAD_RESULT re-reads the table.
    local request = C_Item and C_Item.RequestLoadItemDataByID
    if request and not pendingNames[itemID] then
        pendingNames[itemID] = true
        pcall(request, itemID)
    end
    return nil
end

local function ReadLootEntry(i)
    -- Modern clients return a struct; older ones return a flat list. Accept both.
    if C_EncounterJournal and C_EncounterJournal.GetLootInfoByIndex then
        local ok, data = pcall(C_EncounterJournal.GetLootInfoByIndex, i)
        if ok and type(data) == "table" then
            local id = ns:SafeNum(data.itemID, nil)
            return {
                itemID = id,
                name = ItemNameFor(id, ns:SafeStr(data.name, nil)),
                link = ns:SafeStr(data.link or data.itemLink, nil),
                slot = ns:SafeStr(data.slot, nil),
                encounterID = ns:SafeNum(data.encounterID, nil),
            }
        end
    end
    local itemID, encounterID, name, icon, slot, armorType, link = EJCall("EJ_GetLootInfoByIndex", i)
    if not itemID then return nil end
    local id = ns:SafeNum(itemID, nil)
    return {
        itemID = id,
        name = ItemNameFor(id, ns:SafeStr(name, nil)),
        link = ns:SafeStr(link, nil),
        slot = ns:SafeStr(slot, nil),
        encounterID = ns:SafeNum(encounterID, nil),
    }
end

-- Returns the dungeon's loot table, filtered to the given spec when possible.
-- Second return says whether the filter was actually applied, so the UI can be
-- honest about it rather than claiming a filter it did not get.
function M:LootTable(mapID, specID)
    local cacheKey = tostring(mapID) .. ":" .. tostring(specID or 0)
    local cached = lootCache[cacheKey]
    if cached then return cached.items, cached.filtered end

    local instanceID = self:JournalInstanceFor(mapID)
    if not instanceID then
        lootCache[cacheKey] = { items = {}, filtered = false }
        return {}, false
    end

    local savedInstance = SelectedInstance()
    EJCall("EJ_SelectInstance", instanceID)
    -- Mythic difficulty, so the table matches what a keystone actually drops.
    EJCall("EJ_SetDifficulty", 23)

    local filtered = false
    if specID then
        local classID = select(3, UnitClass("player"))
        if EJCall("EJ_SetLootFilter", classID or 0, specID) ~= nil or _G.EJ_SetLootFilter then
            filtered = true
        end
    end

    local count = EJCall("EJ_GetNumLoot")
    local items = {}
    if type(count) == "number" then
        for i = 1, count do
            local entry = ReadLootEntry(i)
            if entry and entry.itemID then items[#items + 1] = entry end
        end
    end

    if savedInstance then EJCall("EJ_SelectInstance", savedInstance) end
    NormaliseJournal()

    table.sort(items, function(a, b) return (a.name or "") < (b.name or "") end)

    -- Only cache a complete table. Caching one with names still loading would
    -- freeze the item numbers in place for the rest of the session.
    local complete = true
    for _, entry in ipairs(items) do
        if not entry.name then complete = false break end
    end
    if complete then
        lootCache[cacheKey] = { items = items, filtered = filtered and #items > 0 }
    end
    return items, filtered and #items > 0
end

-- Only the loot tables. The instance index is expensive to build - it walks
-- every tier, selecting as it goes - and nothing about a spec change
-- invalidates it.
function M:ClearLootCache()
    lootCache = {}
end

function M:ClearJournalIndex()
    journalByName = nil
    lootCache = {}
end

-- Item details arriving late are the normal case, not an edge case: the whole
-- loot table is usually uncached the first time a dungeon is opened.
local refreshQueued = false

-- The loot table is filtered to the current loot spec, so it has to be rebuilt
-- when that changes rather than showing the previous spec's items.
local function OnSpecChanged()
    M:ClearLootCache()
    if ns.UI and ns.UI:IsShown() then ns.UI:Refresh() end
end

ns:On("PLAYER_LOOT_SPEC_UPDATED", OnSpecChanged)
ns:On("PLAYER_SPECIALIZATION_CHANGED", OnSpecChanged)
ns:On("ACTIVE_TALENT_GROUP_CHANGED", OnSpecChanged)

ns:On("ITEM_DATA_LOAD_RESULT", function(itemID)
    if not itemID or not pendingNames[itemID] then return end   -- not ours
    pendingNames[itemID] = nil
    if refreshQueued or not ns.UI or not ns.UI:IsShown() then return end
    refreshQueued = true
    local function Refresh()
        refreshQueued = false
        M:ClearLootCache()
        if ns.UI:IsShown() then ns.UI:Refresh() end
    end
    -- Batched: a loot table produces dozens of these in a burst.
    if C_Timer and C_Timer.After then C_Timer.After(0.5, Refresh) else Refresh() end
end)
