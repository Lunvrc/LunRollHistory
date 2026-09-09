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
        ns:Print("Commands: |cffffff00show|r, |cffffff00export|r, |cffffff00settings|r, |cffffff00stats|r, |cffffff00sweep|r, |cffffff00clean|r, |cffffff00minimap|r, |cffffff00debug|r, |cffffff00wipe|r")
    end
end
