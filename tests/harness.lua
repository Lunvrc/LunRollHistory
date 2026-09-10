-- Minimal WoW API stub so the addon can be exercised outside the game.
local events = {}

local HERE = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "."
local uistub = dofile(HERE .. "/uistub.lua")
uistub.install()
_G.__uistub = uistub


_G.date = os.date
_G.time = os.time
_G.tinsert = table.insert
_G.strsplit = function(sep, str, limit)
    local out = {}
    local pattern = "([^" .. sep .. "]*)"
    for piece in str:gmatch(pattern .. "[" .. sep .. "]?") do
        out[#out + 1] = piece
        if limit and #out >= limit then break end
    end
    return unpack(out)
end
_G.GetInstanceInfo = function() return "The Venomous Abyss", "raid", 16, "Mythic" end
_G.IsInGroup = function() return true end
_G.UnitName = function() return "Testchar" end
_G.GetPlayerInfoByGUID = function(guid)
    local map = {
        ["Player-1234-AAAA1111"] = { "Rogue", "ROGUE", "Elf", "BloodElf", 2, "Sneakyboi", "Kazzak" },
        ["Player-1234-BBBB2222"] = { "Priest", "PRIEST", "Human", "Human", 3, "Healzalot", "Draenor" },
    }
    local e = map[guid]
    if not e then return nil end
    return e[1], e[2], e[3], e[4], e[5], e[6], e[7]
end
_G.GetLootRollItemLink = function(rollID)
    return "|cffa335ee|Hitem:229876::::::::80:::::|h[Venomfang Shoulderguards]|h|r"
end

_G.Enum = {
    EncounterLootDropRollState = {
        NoRoll = 0, NeedMainSpec = 1, Transmog = 2, Greed = 3, Disenchant = 4, Pass = 5,
    },
}

-- enUS global strings, verbatim shapes.
_G.RANDOM_ROLL_RESULT           = "%s rolls %d (%d-%d)"
_G.LOOT_ITEM                    = "%s receives loot: %s."
_G.LOOT_ITEM_MULTIPLE           = "%s receives loot: %sx%d."
_G.LOOT_ITEM_SELF               = "You receive loot: %s."
_G.LOOT_ITEM_SELF_MULTIPLE      = "You receive loot: %sx%d."
_G.LOOT_ITEM_PUSHED_SELF        = "You receive item: %s."
_G.LOOT_ITEM_PUSHED_SELF_MULTIPLE = "You receive item: %sx%d."

-- Fake loot history backend -------------------------------------------------
local ITEM = "|cffa335ee|Hitem:229876::::::::80:::::|h[Venomfang Shoulderguards]|h|r"
local dropState = {
    itemHyperlink = ITEM,
    isTradeable = true,
    allPassed = false,
    rollInfos = {
        { playerName = "Tankadin-Silvermoon", playerClass = "PALADIN", roll = 91, state = 1, isWinner = true },
        { playerGUID = "Player-1234-AAAA1111", roll = 44, state = 1, isWinner = false },
        { playerGUID = "Player-1234-BBBB2222", roll = 12, state = 3, isWinner = false },
        { playerName = "Passerby",  playerClass = "MAGE",  roll = 0, state = 5, isWinner = false },
    },
}

_G.C_LootHistory = {
    GetSortedInfoForDrop = function(encounterID, lootListID)
        if encounterID == 7001 and lootListID == 1 then return dropState end
        return nil
    end,
    GetSortedDropsForEncounter = function(encounterID)
        if encounterID == 7001 then return { { lootListID = 1 } } end
        return {}
    end,
    GetAllEncounterInfos = function() return { { encounterID = 7001 } } end,
}
_G.__dropState = dropState

-- Event firing --------------------------------------------------------------
function _G.__fire(event, ...)
    local f = _G.__eventFrame
    local handler = f and f.__scripts and f.__scripts.OnEvent
    if handler then handler(f, event, ...) end
end

return events
