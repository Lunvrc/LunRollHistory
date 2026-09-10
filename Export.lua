-- LunRollHistory :: Export.lua
-- CSV builder, wipe confirmation, slash commands.

local ADDON, ns = ...

--------------------------------------------------------------------------------
-- CSV
--------------------------------------------------------------------------------
local COLUMNS = {
    "uid", "timestamp", "type", "instance", "difficulty", "encounter",
    "item_id", "item_name", "player", "realm", "class",
    "roll_type", "roll", "is_winner", "quantity",
}

local function Cell(v)
    if v == nil then return "" end
    if type(v) == "boolean" then return v and "1" or "0" end
    local s = tostring(v)
    s = s:gsub("[\r\n]", " ")
    if s:find('[",]') then
        s = '"' .. s:gsub('"', '""') .. '"'
    end
    return s
end

local function Row(t)
    local out = {}
    for i = 1, #COLUMNS do out[i] = Cell(t[COLUMNS[i]]) end
    return table.concat(out, ",")
end

local function Stamp(ts)
    if not ts then return "" end
    return date("!%Y-%m-%dT%H:%M:%SZ", ts)
end

-- Flattens the log: a drop with five rolls becomes five rows sharing a uid.
function ns:BuildCSV(limit)
    local db = LunRollHistoryDB
    if not db then return "", 0, false end
    local lines = { table.concat(COLUMNS, ",") }
    local rows = 0

    for i = 1, #db.log do
        local e = db.log[i]
        local base = {
            uid = e.uid, timestamp = Stamp(e.ts), type = e.t,
            instance = e.inst, difficulty = e.diff, encounter = e.encName,
            item_id = e.itemID, item_name = e.item,
        }

        if e.t == "drop" and type(e.rolls) == "table" and #e.rolls > 0 then
            for j = 1, #e.rolls do
                local r = e.rolls[j]
                base.player, base.realm, base.class = r.name, r.realm, r.class
                base.roll_type, base.roll, base.is_winner = r.state, r.roll, r.winner
                lines[#lines + 1] = Row(base)
                rows = rows + 1
                if limit and rows >= limit then return table.concat(lines, "\n"), rows, true end
            end
        else
            base.player, base.realm = e.name, e.realm
            base.roll = e.roll
            base.quantity = e.qty
            if e.t == "manualroll" then
                base.roll_type = "Manual(" .. tostring(e.low or 1) .. "-" .. tostring(e.high or 100) .. ")"
            end
            lines[#lines + 1] = Row(base)
            rows = rows + 1
            if limit and rows >= limit then return table.concat(lines, "\n"), rows, true end
        end
    end

    return table.concat(lines, "\n"), rows, false
end

--------------------------------------------------------------------------------
-- Wipe confirmation
--------------------------------------------------------------------------------
local function WipeNow()
    LunRollHistoryDB.log = {}
    LunRollHistoryDB.nextUID = 1
    ns.ResetTransientState()
    ns:Print("Log cleared.")
    if ns.UI then ns.UI:Refresh() end
end
ns.WipeNow = WipeNow

-- No StaticPopupDialogs entry on purpose: that table belongs to Blizzard, and
-- writing into it hands our taint to every popup the UI shows afterwards.
function ns:ConfirmWipe()
    ns.UI:Confirm(
        "Clear the log?",
        "This deletes every recorded roll and cannot be undone. Anything already imported to SQLite is unaffected.",
        "Delete",
        WipeNow)
end

--------------------------------------------------------------------------------
-- Stats to chat
--------------------------------------------------------------------------------
local function PrintStats()
    local db = LunRollHistoryDB
    if not db then return end
    local counts, rolls = {}, 0
    for i = 1, #db.log do
        local e = db.log[i]
        counts[e.t] = (counts[e.t] or 0) + 1
        if e.t == "drop" and type(e.rolls) == "table" then rolls = rolls + #e.rolls end
    end
    ns:Print(("%d entries: %d drops (%d individual rolls), %d manual rolls, %d loot events.")
        :format(#db.log, counts.drop or 0, rolls, counts.manualroll or 0, counts.loot or 0))
    ns:Print("SavedVariables are written on logout or /reload, not live.")
end

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------
SLASH_LUNROLLHISTORY1 = "/lunrollhistory"
SLASH_LUNROLLHISTORY2 = "/lrh"

SlashCmdList.LUNROLLHISTORY = function(input)
    local cmd, rest = strsplit(" ", (input or ""):lower(), 2)

    if cmd == nil or cmd == "" or cmd == "show" or cmd == "ui" then
        ns.UI:Toggle()

    elseif cmd == "history" then
        ns.UI:Show("history")

    elseif cmd == "export" then
        ns.UI:Show("export")

    elseif cmd == "settings" or cmd == "config" then
        ns.UI:Show("capture")

    elseif cmd == "stats" then
        PrintStats()

    elseif cmd == "sweep" then
        ns.SweepAll()
        ns:Print("Swept loot history.")
        if ns.UI then ns.UI:Refresh() end

    elseif cmd == "diag" then
        ns:Print("version", ns.VERSION)
        ns:Print("modules:",
            "Theme", ns.Theme and "y" or "n",
            "Widgets", ns.Widgets and "y" or "n",
            "Luck", ns.Luck and "y" or "n",
            "Mythic", ns.Mythic and "y" or "n",
            "UI", ns.UI and "y" or "n")

        local cm = _G.C_ChallengeMode
        ns:Print("C_ChallengeMode:", cm and "present" or "MISSING",
            cm and (cm.GetMapTable and "GetMapTable y" or "GetMapTable n") or "",
            cm and (cm.GetMapUIInfo and "GetMapUIInfo y" or "GetMapUIInfo n") or "",
            cm and (cm.GetCompletionInfo and "GetCompletionInfo y" or "GetCompletionInfo n") or "")

        if cm and cm.GetMapTable then
            local ok, list = pcall(cm.GetMapTable)
            if not ok then
                ns:Print("GetMapTable errored:", tostring(list))
            elseif type(list) ~= "table" then
                ns:Print("GetMapTable returned", type(list))
            else
                ns:Print("season maps:", #list)
                for i = 1, math.min(#list, 12) do
                    local id = list[i]
                    local ok2, name, _, timeLimit, texture = pcall(cm.GetMapUIInfo, id)
                    ns:Print(string.format("  [%s] %s  texture=%s  %s",
                        tostring(id),
                        ok2 and tostring(name) or ("ERROR " .. tostring(name)),
                        tostring(texture),
                        ns.Mythic and ("abbr=" .. tostring(ns.Mythic:Abbreviate(id, name))) or ""))
                end
            end
        end

        ns:Print("encounter journal:",
            _G.EJ_GetNumTiers and "EJ_GetNumTiers y" or "EJ_GetNumTiers n",
            _G.EJ_SelectInstance and "EJ_SelectInstance y" or "EJ_SelectInstance n",
            (_G.C_EncounterJournal and _G.C_EncounterJournal.GetLootInfoByIndex)
                and "C_EJ.GetLootInfoByIndex y" or "C_EJ.GetLootInfoByIndex n")

        if ns.Mythic then
            local runs, unresolved = 0, 0
            for _, entry in ipairs(LunRollHistoryDB.log) do
                if entry.t == "mplus" then
                    runs = runs + 1
                    if not entry.mapID then unresolved = unresolved + 1 end
                end
            end
            ns:Print("duplicate drops in the log:", ns:CountDuplicates())
            ns:Print(string.format("mythic+ runs recorded: %d (%d with no dungeon)",
                runs, unresolved))
            ns:Print("last completion event:",
                ns.Mythic.lastCompletionAt
                    and (date("%Y-%m-%d %H:%M:%S", ns.Mythic.lastCompletionAt)
                         .. "  resolved=" .. tostring(ns.Mythic.lastResolved)
                         .. "  attempts=" .. tostring(ns.Mythic.lastResolveAttempts))
                    or "never fired since login")
            ns:Print("active challenge map:", tostring(ns.Mythic:ActiveMapID()))
            ns:Print("completion data shape:",
                tostring(ns.Mythic.lastCompletionShape or "never read"))
            ns:Print("loot window:", ns.Mythic:IsWindowOpen() and "OPEN" or "closed")
            ns:Print("ENCOUNTER_LOOT_RECEIVED seen:",
                ns.Mythic.lastEncounterLoot
                    and date("%H:%M:%S", ns.Mythic.lastEncounterLoot) or "never")

            -- The most recent run and what actually attached to it.
            local last
            for i = #LunRollHistoryDB.log, 1, -1 do
                if LunRollHistoryDB.log[i].t == "mplus" then
                    last = LunRollHistoryDB.log[i]
                    break
                end
            end
            if last then
                ns:Print(string.format("last run: map=%s level=%s timed=%s party=%s items=%d",
                    tostring(last.mapID), tostring(last.level), tostring(last.timed),
                    tostring(last.party), #(last.items or {})))
                for _, item in ipairs(last.items or {}) do
                    ns:Print(string.format("   %s <- %s (%s)",
                        tostring(item.name), tostring(item.item), tostring(item.source)))
                end
            end

            local raw = ns.Mythic.rawLoot or {}
            ns:Print(string.format("raw loot messages during the last window: %d", #raw))
            for i = 1, math.min(#raw, 12) do
                ns:Print("   " .. raw[i])
            end
            ns:Print("current instance:", tostring(ns.context and ns.context.instance))
        end

        local spec, specID = ns.Mythic and ns.Mythic:CurrentSpecName()
        ns:Print("loot spec:", tostring(spec), tostring(specID))
        ns:Print("last page error:", ns.lastPageError or "none")

    elseif cmd == "addrun" then
        local run = ns.Mythic and ns.Mythic:RecordRunManually()
        if run then
            ns:Print(("Recorded a run in %s. Chest loot in the next %d seconds will be attached.")
                :format(run.mapName or "this dungeon", ns.Mythic.LOOT_WINDOW))
        else
            ns:Print("Could not tell which dungeon this is. Run it from inside the instance.")
        end
        if ns.UI then ns.UI:Refresh() end

    elseif cmd == "dedupe" then
        local drops, rolls = ns:DeduplicateLog()
        if drops == 0 then
            ns:Print("No duplicate drops found.")
        else
            ns:Print(("Merged %d duplicate drops and %d repeated rolls.")
                :format(drops, rolls))
        end
        if ns.UI then ns.UI:Refresh() end

    elseif cmd == "clean" then
        local removed = ns:PruneLog()
        ns:Print(string.format("Removed %d filtered loot entries.", removed))
        if ns.UI then ns.UI:Refresh() end

    elseif cmd == "minimap" then
        local hidden = LunRollHistoryDB.settings.minimapHide
        ns.Minimap:Toggle(not hidden)
        ns:Print("Minimap button", hidden and "shown." or "hidden.")
        if ns.UI then ns.UI:Refresh() end

    elseif cmd == "debug" then
        ns.debug = not ns.debug
        ns:Print("Debug", ns.debug and "on" or "off")

    elseif cmd == "wipe" then
        if rest == "confirm" then
            WipeNow()
        else
            ns:ConfirmWipe()
        end

    else
        ns:Print("Commands: |cffffff00show|r, |cffffff00export|r, |cffffff00settings|r, |cffffff00stats|r, |cffffff00sweep|r, |cffffff00clean|r, |cffffff00dedupe|r, |cffffff00minimap|r, |cffffff00diag|r, |cffffff00addrun|r, |cffffff00debug|r, |cffffff00wipe|r")
    end
end
