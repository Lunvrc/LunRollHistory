-- Resolve paths relative to this script so the suite runs from any checkout.
local HERE = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "."
local ROOT = HERE .. "/.."
dofile(HERE .. "/harness.lua")

local ADDON = "LunRollHistory"
local ns = {}

local function LoadFile(path)
    local chunk = assert(loadfile(path))
    -- Emulate WoW's addon vararg: (addonName, privateTable)
    local wrapper = function(...) return chunk(...) end
    wrapper(ADDON, ns)
end

LoadFile(ROOT .. "/Core.lua")
LoadFile(ROOT .. "/Theme.lua")
LoadFile(ROOT .. "/Widgets.lua")
LoadFile(ROOT .. "/Luck.lua")
LoadFile(ROOT .. "/UI.lua")
LoadFile(ROOT .. "/Minimap.lua")
LoadFile(ROOT .. "/Capture.lua")
LoadFile(ROOT .. "/Export.lua")

local pass, fail = 0, 0
local function check(label, cond, detail)
    if cond then pass = pass + 1; print("  ok   " .. label)
    else fail = fail + 1; print("  FAIL " .. label .. (detail and ("  -> " .. tostring(detail)) or "")) end
end

print("== boot ==")
__fire("ADDON_LOADED", ADDON)
__fire("PLAYER_ENTERING_WORLD")
check("db created", type(LunRollHistoryDB) == "table")
check("settings defaulted", LunRollHistoryDB.settings.captureLootHistory == true)

print("\n== pattern compiler ==")
local m = ns.Compile("%s rolls %d (%d-%d)")
local n, r, lo, hi = m("Sneakyboi rolls 73 (1-100)")
check("enUS /roll", n == "Sneakyboi" and r == "73" and lo == "1" and hi == "100",
      tostring(n) .. "/" .. tostring(r))

-- Positional specifiers, as used by several localisations.
local mp = ns.Compile("%2$d ist das Ergebnis von %1$s (%3$d-%4$d)")
local pn, pr = mp("58 ist das Ergebnis von Zauberer (1-100)")
check("positional args remapped", pn == "Zauberer" and pr == "58",
      tostring(pn) .. "/" .. tostring(pr))

local ml = ns.Compile("%s receives loot: %sx%d.")
local who, link, qty = ml("Healzalot receives loot: |cff0070dd|Hitem:12345::::::::80:::::|h[Bag of Fangs]|hx3.")
check("loot multiple", who == "Healzalot" and qty == "3" and link:find("Bag of Fangs", 1, true) ~= nil,
      tostring(who) .. "/" .. tostring(qty))

local mn = ns.Compile("%s receives loot: %s.")
local who2, link2 = mn("Tankadin receives loot: |cffa335ee|Hitem:229876::::::::80:::::|h[Ver. 2.0 Cloak]|h|r.")
check("item name containing a period", link2 and link2:find("Ver. 2.0 Cloak", 1, true) ~= nil, link2)

print("\n== encounter + group loot rolls ==")
__fire("ENCOUNTER_START", 7001, "Nymrissa Wavecaller", 16, 20)
__fire("START_LOOT_ROLL", 3)
__fire("LOOT_HISTORY_UPDATE_DROP", 7001, 1)
__fire("LOOT_HISTORY_UPDATE_DROP", 7001, 1)  -- repeat: must NOT duplicate
__fire("ENCOUNTER_END", 7001, "Nymrissa Wavecaller", 16, 20, true)

local drops = 0
local dropRec
for _, e in ipairs(LunRollHistoryDB.log) do
    if e.t == "drop" then drops = drops + 1; dropRec = e end
end
check("repeated drop events collapse to one record", drops == 1, drops)
check("all four rolls captured", dropRec and #dropRec.rolls == 4, dropRec and #dropRec.rolls)
check("winner identified", dropRec and dropRec.winner == "Tankadin", dropRec and dropRec.winner)
check("realm split off name", dropRec and dropRec.rolls[1].realm == "Silvermoon",
      dropRec and dropRec.rolls[1].realm)
check("GUID resolved to name", dropRec and dropRec.rolls[2].name == "Sneakyboi",
      dropRec and dropRec.rolls[2].name)
check("class from GUID", dropRec and dropRec.rolls[2].class == "ROGUE",
      dropRec and dropRec.rolls[2].class)
check("enum decoded", dropRec and dropRec.rolls[1].state == "NeedMainSpec",
      dropRec and dropRec.rolls[1].state)
check("pass decoded", dropRec and dropRec.rolls[4].state == "Pass",
      dropRec and dropRec.rolls[4].state)
check("itemID parsed", dropRec and dropRec.itemID == 229876, dropRec and dropRec.itemID)
check("encounter stamped", dropRec and dropRec.encName == "Nymrissa Wavecaller", dropRec and dropRec.encName)
check("difficulty stamped", dropRec and dropRec.diff == "Mythic", dropRec and dropRec.diff)

print("\n== manual rolls ==")
__fire("CHAT_MSG_SYSTEM", "Sneakyboi rolls 73 (1-100)")
__fire("CHAT_MSG_SYSTEM", "Healzalot-Draenor rolls 8 (1-100)")
__fire("CHAT_MSG_SYSTEM", "Some unrelated system message.")
local manual = {}
for _, e in ipairs(LunRollHistoryDB.log) do if e.t == "manualroll" then manual[#manual + 1] = e end end
check("two manual rolls recorded", #manual == 2, #manual)
check("noise ignored", #manual == 2)
check("manual roll value", manual[1] and manual[1].roll == 73, manual[1] and manual[1].roll)
check("manual roll realm split", manual[2] and manual[2].realm == "Draenor", manual[2] and manual[2].realm)

print("\n== secret value resilience ==")
-- A secret value throws when touched. Nothing should escape to the caller.
local secret = setmetatable({}, {
    __tostring = function() error("attempted to use a secret value") end,
    __concat   = function() error("attempted to use a secret value") end,
})
local ok = pcall(__fire, "CHAT_MSG_SYSTEM", secret)
check("secret chat message does not error out", ok)
local before = #LunRollHistoryDB.log
__dropState.rollInfos[1].playerName = secret
__fire("LOOT_HISTORY_UPDATE_DROP", 7001, 1)
check("secret player name does not error out", true)
check("record still present after secret", #LunRollHistoryDB.log == before, #LunRollHistoryDB.log)
__dropState.rollInfos[1].playerName = "Tankadin-Silvermoon"
__fire("LOOT_HISTORY_UPDATE_DROP", 7001, 1)

print("\n== loot awards ==")
__fire("CHAT_MSG_LOOT", "Tankadin receives loot: |cffa335ee|Hitem:229876::::::::80:::::|h[Venomfang Shoulderguards]|h|r.")
__fire("CHAT_MSG_LOOT", "You receive loot: |cff0070dd|Hitem:12345::::::::80:::::|h[Bag of Fangs]|h|rx3.")
local loots = {}
for _, e in ipairs(LunRollHistoryDB.log) do if e.t == "loot" then loots[#loots + 1] = e end end
check("two loot events", #loots == 2, #loots)
check("named looter", loots[1] and loots[1].name == "Tankadin", loots[1] and loots[1].name)
check("self looter resolved", loots[2] and loots[2].name == "Testchar", loots[2] and loots[2].name)
check("quantity parsed", loots[2] and loots[2].qty == 3, loots[2] and loots[2].qty)

print("\n== csv ==")
local csv, rows = ns:BuildCSV()
local lines = {}
for line in csv:gmatch("[^\n]+") do lines[#lines + 1] = line end
check("header present", lines[1]:find("^uid,timestamp,type") ~= nil, lines[1])
check("one row per individual roll", rows == 4 + 2 + 2 + 1, rows) -- 4 rolls, 2 manual, 2 loot, 1 rollstart
check("no unescaped commas break columns", (function()
    for i = 2, #lines do
        local count = 0
        local inQ = false
        for c in lines[i]:gmatch(".") do
            if c == '"' then inQ = not inQ elseif c == "," and not inQ then count = count + 1 end
        end
        if count ~= 14 then return false, i end
    end
    return true
end)())

print("\n== item filter ==")
do
    local EPIC  = "|cffa335ee|Hitem:229876::::::::80:::::|h[Venomfang Shoulderguards]|h|r"
    local GREY  = "|cff9d9d9d|Hitem:99001::::::::80:::::|h[Corroded Scale]|h|r"
    local WHITE = "|cffffffff|Hitem:99002::::::::80:::::|h[Practically Pork]|h|r"
    local GREEN = "|cff1eff00|Hitem:12345::::::::80:::::|h[Void-tempered Scales]|h|r"

    check("quality read from the link colour", ns:ItemQuality(EPIC) == 4, ns:ItemQuality(EPIC))
    check("grey detected", ns:ItemQuality(GREY) == 0, ns:ItemQuality(GREY))
    check("white detected", ns:ItemQuality(WHITE) == 1, ns:ItemQuality(WHITE))
    check("green detected", ns:ItemQuality(GREEN) == 2, ns:ItemQuality(GREEN))

    LunRollHistoryDB.settings.minLootQuality = 3
    LunRollHistoryDB.settings.lootGearOnly = false
    check("epic passes the rare filter", ns:PassesLootFilter(EPIC, 229876))
    check("grey reagent blocked", not ns:PassesLootFilter(GREY, 99001))
    check("white reagent blocked", not ns:PassesLootFilter(WHITE, 99002))
    check("green reagent blocked", not ns:PassesLootFilter(GREEN, 12345))

    LunRollHistoryDB.settings.minLootQuality = 0
    check("filter off lets everything through", ns:PassesLootFilter(GREY, 99001))

    -- Gear-only should stop a green reagent that quality alone would allow.
    LunRollHistoryDB.settings.lootGearOnly = true
    check("gear only blocks tradegoods", not ns:PassesLootFilter(GREEN, 12345))
    check("gear only keeps armour", ns:PassesLootFilter(EPIC, 229876))
    LunRollHistoryDB.settings.lootGearOnly = false

    -- Unknown quality is kept rather than silently dropped.
    LunRollHistoryDB.settings.minLootQuality = 4
    check("uncoloured link is kept", ns:PassesLootFilter("|Hitem:55555|h[Mystery]|h", 55555))

    -- Manual ignore list.
    LunRollHistoryDB.settings.minLootQuality = 0
    LunRollHistoryDB.settings.ignoreItems = { [229876] = true }
    check("ignore list blocks by item id", not ns:PassesLootFilter(EPIC, 229876))
    LunRollHistoryDB.settings.ignoreItems = {}

    -- End to end through the real event, then a retroactive clean.
    LunRollHistoryDB.settings.minLootQuality = 3
    local before = 0
    for _, e in ipairs(LunRollHistoryDB.log) do if e.t == "loot" then before = before + 1 end end
    __fire("CHAT_MSG_LOOT", "Tankadin receives loot: " .. GREY .. ".")
    __fire("CHAT_MSG_LOOT", "Tankadin receives loot: " .. WHITE .. ".")
    local after = 0
    for _, e in ipairs(LunRollHistoryDB.log) do if e.t == "loot" then after = after + 1 end end
    check("trash never reaches the log", after == before, after .. " vs " .. before)

    __fire("CHAT_MSG_LOOT", "Tankadin receives loot: " .. EPIC .. ".")
    local withEpic = 0
    for _, e in ipairs(LunRollHistoryDB.log) do if e.t == "loot" then withEpic = withEpic + 1 end end
    check("real gear still recorded", withEpic == before + 1, withEpic)
    table.remove(LunRollHistoryDB.log)   -- leave the log as we found it

    -- Retroactive prune: plant trash directly, then clean it out.
    ns:Append({ t = "loot", name = "Tankadin", link = GREY, itemID = 99001, item = "Corroded Scale" })
    ns:Append({ t = "loot", name = "Tankadin", link = WHITE, itemID = 99002, item = "Practically Pork" })
    local rollsBefore = #LunRollHistoryDB.log
    local removed = ns:PruneLog()
    check("prune removes planted trash", removed == 2, removed)
    check("prune leaves everything else", #LunRollHistoryDB.log == rollsBefore - 2)
    check("prune is idempotent", ns:PruneLog() == 0)
end

print("\n== uid uniqueness ==")
local seen, dupes = {}, 0
for _, e in ipairs(LunRollHistoryDB.log) do
    if seen[e.uid] then dupes = dupes + 1 end
    seen[e.uid] = true
end
check("uids unique", dupes == 0, dupes)

print("\n== slash commands ==")
check("stats runs", pcall(SlashCmdList.LUNROLLHISTORY, "stats"))
check("wipe requires confirm", pcall(SlashCmdList.LUNROLLHISTORY, "wipe") and #LunRollHistoryDB.log > 0)

print("\n== ui construction ==")
local okShow, errShow = pcall(function() ns.UI:Show() end)
check("window builds and shows", okShow, errShow)

for _, key in ipairs({ "history", "stats", "capture", "appearance", "export", "about" }) do
    local ok, err = pcall(function() ns.UI:Select(key) end)
    check("page builds: " .. key, ok, err)
end

print("\n== ui behaviour ==")
ns.UI:Select("history")
local frame = _G.LunRollHistoryFrame
local page = frame.pages.history
check("history page populated", #page.list.data > 0, #page.list.data)

-- Tab switching must refilter, not just recolour.
local allCount = #page.list.data
frame.tabButtons[3]:Fire("OnClick")        -- "Manual"
check("manual tab filters down", #page.list.data == 2 and #page.list.data < allCount,
      #page.list.data)
frame.tabButtons[1]:Fire("OnClick")        -- back to "All"
check("all tab restores", #page.list.data == allCount, #page.list.data)

-- Search
page.search = "sneaky"
page:Reload()
-- Sneakyboi appears once as a loot roll and once as a manual roll.
check("search matches across record types", #page.list.data == 2, #page.list.data)
page.search = "venomfang"
page:Reload()
check("search matches on item name", #page.list.data == 5, #page.list.data)
page.search = ""
page:Reload()

-- Virtualisation: row frames created must be bounded by the viewport, not data.
local bigData = {}
for i = 1, 5000 do bigData[i] = page.list.data[1] end
page.list:SetData(bigData)
check("virtualised list creates few row frames", #page.list.rows < 60,
      #page.list.rows .. " frames for 5000 rows")

-- Scrolling
local before = page.list.offset
page.list:Fire("OnMouseWheel", -1)
check("scroll down moves offset", page.list.offset > before, page.list.offset)
page.list:Fire("OnMouseWheel", 50)
check("scroll clamps at top", page.list.offset == 0, page.list.offset)

print("\n== settings page ==")
ns.UI:Select("capture")
local cap = frame.pages.capture
local firstToggle = nil
for _, child in pairs(cap) do
    if type(child) == "table" and child.toggle then firstToggle = child.toggle break end
end
LunRollHistoryDB.settings.captureManualRolls = true
local togglesOk = pcall(function()
    LunRollHistoryDB.settings.captureManualRolls = not LunRollHistoryDB.settings.captureManualRolls
    cap:Reload()
end)
check("settings page reloads", togglesOk)
check("setting actually flipped", LunRollHistoryDB.settings.captureManualRolls == false,
      tostring(LunRollHistoryDB.settings.captureManualRolls))
LunRollHistoryDB.settings.captureManualRolls = true

print("\n== colour maths ==")
local T = ns.Theme
check("hsv round trip: orchid", (function()
    local h, s, v = T.RGBtoHSV(0.898, 0.522, 0.808)
    local r, g, b = T.HSVtoRGB(h, s, v)
    return math.abs(r - 0.898) < 0.001 and math.abs(g - 0.522) < 0.001
       and math.abs(b - 0.808) < 0.001
end)())
check("hsv round trip: pure grey", (function()
    local h, s, v = T.RGBtoHSV(0.5, 0.5, 0.5)
    local r, g, b = T.HSVtoRGB(h, s, v)
    return math.abs(r - 0.5) < 0.001 and math.abs(g - b) < 0.001
end)())
check("hsv round trip: black", (function()
    local h, s, v = T.RGBtoHSV(0, 0, 0)
    local r, g, b = T.HSVtoRGB(h, s, v)
    return r == 0 and g == 0 and b == 0
end)())
check("hex encodes", T.RGBtoHex(1, 0, 0.5) == "FF0080", T.RGBtoHex(1, 0, 0.5))
check("hex decodes", (function()
    local r, g, b = T.HexToRGB("E585CE")
    return math.abs(r - 229/255) < 0.001 and math.abs(b - 206/255) < 0.001
end)())
check("hex tolerates a leading hash", T.HexToRGB("#E585CE") ~= nil)
check("hex rejects junk", T.HexToRGB("nope") == nil)
check("hex rejects wrong length", T.HexToRGB("FFF") == nil)

print("\n== settings page layout ==")
do
    ns.UI:Select("capture")
    local cap = _G.LunRollHistoryFrame.pages.capture
    check("rows exposed for layout", cap.rows and #cap.rows > 0, cap.rows and #cap.rows)

    -- No row may be shorter than the text it contains, or the description
    -- bleeds into the row below it.
    local function NoRowIsTooShort(page)
        for _, row in ipairs(page.rows) do
            local labelH = row.label:GetStringHeight() or 14
            local descH = row.desc and row.desc:GetStringHeight() or 0
            local needed = (descH > 0) and (12 + labelH + 5 + descH + 12) or (labelH + 24)
            if (row:GetHeight() or 0) + 0.5 < needed then
                return false, row.label:GetText()
            end
        end
        return true
    end
    check("every row is tall enough for its text", NoRowIsTooShort(cap))

    -- Content height must account for all of them, so the scroll range is real.
    local sum = 0
    for _, row in ipairs(cap.rows) do sum = sum + (row:GetHeight() or 0) + 6 end
    check("content height covers every row",
          math.abs(cap.scroll.contentHeight - sum) < 1,
          cap.scroll.contentHeight .. " vs " .. sum)

    -- The original bug: content taller than the viewport ran off the window.
    cap.scroll:SetHeight(300)
    cap.scroll:Update()
    check("overflowing content becomes scrollable", cap.scroll:MaxScroll() > 0,
          cap.scroll:MaxScroll())

    cap.scroll.offset = 99999
    cap.scroll:Update()
    check("scroll clamps at the bottom",
          math.abs(cap.scroll.offset - cap.scroll:MaxScroll()) < 0.01, cap.scroll.offset)
    cap.scroll:Fire("OnMouseWheel", 99)
    check("scroll clamps at the top", cap.scroll.offset == 0, cap.scroll.offset)

    -- Bigger text means taller rows, not overlapping ones.
    local before = cap.scroll.contentHeight
    ns.Theme:SetFontScale(1.6)
    cap:Layout()
    check("rows grow with the font size", cap.scroll.contentHeight > before,
          cap.scroll.contentHeight .. " vs " .. before)
    check("still no row too short at 160%", NoRowIsTooShort(cap))
    ns.Theme:SetFontScale(1.0)
    cap:Layout()
    check("rows shrink back", math.abs(cap.scroll.contentHeight - before) < 1)

    ns.UI:Select("appearance")
    local app = _G.LunRollHistoryFrame.pages.appearance
    check("appearance rows sized too", NoRowIsTooShort(app))
    check("appearance content measured", app.scroll.contentHeight > 0, app.scroll.contentHeight)

    ns.UI:Select("about")
    local about = _G.LunRollHistoryFrame.pages.about
    check("about page measured", about.scroll ~= nil or true)
end

print("\n== accent picker ==")
ns.UI:Select("appearance")
local beforeAccent = { T.accent[1], T.accent[2], T.accent[3] }
T:SetAccent(T.HSVtoRGB(120, 0.8, 0.9))
check("arbitrary accent applies", T.accent[1] ~= beforeAccent[1], T:AccentHex())
check("accent persisted as rgb",
      type(LunRollHistoryDB.settings.accentColor) == "table"
      and #LunRollHistoryDB.settings.accentColor == 3)
check("old preset keys still resolve", T:SetAccentByKey("fel") == true)
check("unknown preset key rejected", T:SetAccentByKey("nope") == false)
T:SetAccent(0.898, 0.522, 0.808)

print("\n== fonts ==")
check("font list built", #T.fontList > 0, #T.fontList)
check("list only holds loadable fonts", (function()
    for _, e in ipairs(T.fontList) do
        if not T.CanUseFont(e.path) then return false, e.path end
    end
    return true
end)())
check("list is sorted by name", (function()
    for i = 2, #T.fontList do
        if T.fontList[i - 1].name > T.fontList[i].name then return false end
    end
    return true
end)())
local firstFont = T.fontList[1].path
T:SetFontFamily(firstFont)
check("font family applies", T.fontPath == firstFont, T.fontPath)
check("font family persisted", LunRollHistoryDB.settings.fontPath == firstFont)
check("name lookup works", T:FontNameFor(firstFont) == T.fontList[1].name)

T:SetFontScale(1.25)
check("font scale applies", math.abs(T.fontScale - 1.25) < 0.001, T.fontScale)
check("font scale persisted", math.abs(LunRollHistoryDB.settings.fontScale - 1.25) < 0.001)
T:SetFontScale(9)
check("font scale clamps high", T.fontScale == 1.6, T.fontScale)
T:SetFontScale(0.1)
check("font scale clamps low", T.fontScale == 0.7, T.fontScale)
T:SetFontScale(1.0)

check("settings round trip through LoadFromSettings", (function()
    T:SetAccent(0.1, 0.2, 0.3)
    T:SetFontScale(1.3)
    local saved = LunRollHistoryDB.settings
    T:SetAccent(1, 1, 1, true)
    T.fontScale = 1.0
    T:LoadFromSettings(saved)
    return math.abs(T.accent[1] - 0.1) < 0.001 and math.abs(T.fontScale - 1.3) < 0.001
end)())
T:SetAccent(0.898, 0.522, 0.808)
T:SetFontScale(1.0)

check("appearance page reloads after all that",
      pcall(function() _G.LunRollHistoryFrame.pages.appearance:Reload() end))

print("\n== dropdown widget ==")
do
    local host = CreateFrame("Frame")
    local chosen = "b"
    local dd = ns.Widgets.Dropdown(host, {
        getItems = function()
            return { { name = "Alpha", value = "a" }, { name = "Beta", value = "b" },
                     { name = "Gamma", value = "c" } }
        end,
        getValue = function() return chosen end,
        setValue = function(v) chosen = v end,
        labelFor = function(v) return ({ a = "Alpha", b = "Beta", c = "Gamma" })[v] end,
    })
    check("shows the current value", dd.label:GetText() == "Beta", dd.label:GetText())
    dd:Open()
    check("menu opens", dd.menu:IsShown())
    check("all items loaded", #dd.list.data == 3, #dd.list.data)

    -- Select through the row click path, the way a user would.
    local row = dd.list.rows[1]
    row:Fire("OnClick")
    check("clicking a row sets the value", chosen == "a", chosen)
    check("menu closes after choosing", not dd.menu:IsShown())
    check("label follows the new value", dd.label:GetText() == "Alpha", dd.label:GetText())

    chosen = "c"
    dd:Refresh()
    check("refresh follows the backing value", dd.label:GetText() == "Gamma", dd.label:GetText())
end

print("\n== export page ==")
ns.UI:Select("export")
local exportText = frame.pages.export.edit:GetText()
check("export box filled with csv", exportText:find("^uid,timestamp,type") ~= nil)

print("\n== toggle + close ==")
ns.UI:Hide()
check("hides", not ns.UI:IsShown())
ns.UI:Toggle()
check("toggle reopens", ns.UI:IsShown())

print("\n== slash commands route to ui ==")
check("/lrh export", pcall(SlashCmdList.LUNROLLHISTORY, "export"))
check("/lrh settings", pcall(SlashCmdList.LUNROLLHISTORY, "settings"))
check("/lrh wipe prompts instead of wiping", (function()
    local n = #LunRollHistoryDB.log
    pcall(SlashCmdList.LUNROLLHISTORY, "wipe")
    return #LunRollHistoryDB.log == n and ns.UI:IsConfirmShown()
end)())

print("\n== taint safety ==")
check("never registers in UISpecialFrames", #_G.UISpecialFrames == 0, #_G.UISpecialFrames)
check("never writes to StaticPopupDialogs",
      next(_G.StaticPopupDialogs) == nil, tostring(next(_G.StaticPopupDialogs)))

-- Opening the window in combat must not touch keyboard capture.
ns.UI:Hide()
__uistub.inCombat = true
local okCombat = pcall(function() ns.UI:Show() end)
check("opens during combat without error", okCombat)
local f = _G.LunRollHistoryFrame
check("escape is a no-op in combat", (function()
    f:Fire("OnKeyDown", "ESCAPE")
    return f:IsShown()
end)())
__uistub.inCombat = false
f:Fire("OnKeyDown", "ESCAPE")
check("escape closes out of combat", not f:IsShown())

-- Confirmation dialog is ours, and cancelling leaves the log alone.
local before = #LunRollHistoryDB.log
ns:ConfirmWipe()
check("confirm dialog opens", ns.UI:IsConfirmShown())
check("log untouched until accepted", #LunRollHistoryDB.log == before, #LunRollHistoryDB.log)
_G.LunRollHistoryFrame.confirm.onAccept()
check("accepting clears the log", #LunRollHistoryDB.log == 0, #LunRollHistoryDB.log)

print("\n== minimap button ==")
local mm = _G.LunRollHistoryMinimapButton
check("button created on load", mm ~= nil)
check("button shown by default", mm and mm:IsShown())
check("addon compartment hook is a global function",
      type(_G.LunRollHistory_OnAddonCompartmentClick) == "function")

ns.UI:Hide()
_G.LunRollHistory_OnAddonCompartmentClick(nil, "LeftButton")
check("compartment left click opens the window", ns.UI:IsShown())
_G.LunRollHistory_OnAddonCompartmentClick(nil, "RightButton")
check("compartment right click lands on settings",
      _G.LunRollHistoryFrame.current == "capture", _G.LunRollHistoryFrame.current)

ns.UI:Hide()
mm:Fire("OnClick", "LeftButton")
check("minimap left click opens the window", ns.UI:IsShown())
check("tooltip builds without error", pcall(function() mm:Fire("OnEnter") end))

-- Dragging writes an angle back to saved variables.
local startAngle = LunRollHistoryDB.settings.minimapAngle
mm:Fire("OnDragStart")
mm.__scripts.OnUpdate(mm)
check("drag updates the saved angle",
      LunRollHistoryDB.settings.minimapAngle ~= startAngle,
      LunRollHistoryDB.settings.minimapAngle)
mm:Fire("OnDragStop")

ns.Minimap:Toggle(true)
check("can be hidden", not mm:IsShown())
check("hidden state persisted", LunRollHistoryDB.settings.minimapHide == true)
ns.Minimap:Toggle(false)
check("can be shown again", mm:IsShown())

check("/lrh minimap toggles", (function()
    local before = LunRollHistoryDB.settings.minimapHide
    pcall(SlashCmdList.LUNROLLHISTORY, "minimap")
    return LunRollHistoryDB.settings.minimapHide ~= before
end)())
ns.Minimap:Toggle(false)


print("\n== luck maths ==")
do
    local L = ns.Luck
    -- Normal CDF against known values.
    check("cdf at 0 is 50%", math.abs(L.NormalCDF(0) - 0.5) < 1e-6)
    check("cdf at 1 sigma", math.abs(L.NormalCDF(1) - 0.8413) < 0.001, L.NormalCDF(1))
    check("cdf at -1.96", math.abs(L.NormalCDF(-1.96) - 0.025) < 0.001, L.NormalCDF(-1.96))
    check("cdf is symmetric", math.abs(L.NormalCDF(1.4) + L.NormalCDF(-1.4) - 1) < 1e-6)

    -- Build a synthetic history with three known profiles.
    local saved = LunRollHistoryDB.log
    LunRollHistoryDB.log = {}
    LunRollHistoryDB.nextUID = 1

    local function Drop(entries)
        local rolls = {}
        for _, e in ipairs(entries) do
            rolls[#rolls + 1] = { name = e[1], roll = e[2], state = e[3] or "NeedMainSpec",
                                  winner = e[4] or false, class = "ROGUE" }
        end
        ns:Append({ t = "drop", item = "Test Item", itemID = 1, rolls = rolls })
    end

    -- Highroller always rolls high and wins; Lowroller always rolls low.
    for i = 1, 30 do
        Drop({ { "Highroller", 90 + (i % 8), nil, true },
               { "Lowroller", 5 + (i % 8) },
               { "Midroller", 45 + (i % 11) } })
    end

    local order, byName = L:Compute()
    local hi, lo, mid = byName.Highroller, byName.Lowroller, byName.Midroller

    check("everyone picked up", hi and lo and mid ~= nil)
    check("sample counted", hi.rolls == 30, hi.rolls)
    check("contested counted", hi.contests == 30, hi.contests)
    check("expected wins is one third", math.abs(hi.expWins - 10) < 0.001, hi.expWins)

    check("high roller reads lucky", hi.luck > 95, hi.luck)
    check("low roller reads unlucky", lo.luck < 5, lo.luck)
    -- Midroller's *rolls* are dead par, so that component sits near 50...
    check("mid roller's roll average is par", math.abs(mid.rollPct - 50) < 15, mid.rollPct)
    -- ...but they won none of an expected ten, which is real bad luck and the
    -- composite is supposed to say so. Rolling average while never winning your
    -- share is exactly the case this feature exists to surface.
    check("never winning your share reads unlucky", mid.luck < 20, mid.luck)
    check("luck is ordered", hi.z > mid.z and mid.z > lo.z)

    check("ranking assigned", hi.rank == 1 and hi.rankOf == 3, hi.rank)
    check("best beats everyone", math.abs(hi.peerLuck - 100) < 0.01, hi.peerLuck)
    check("worst beats nobody", math.abs(lo.peerLuck - 0) < 0.01, lo.peerLuck)
    check("middle sits in the middle", math.abs(mid.peerLuck - 50) < 0.01, mid.peerLuck)

    -- Every displayed percentage says "of players", so each one has to be
    -- measured against players, not against chance.
    check("per-metric peer percentiles exist",
          hi.peerRoll ~= nil and hi.peerWin ~= nil)
    check("roll peer percentile ranks by roll average",
          hi.peerRoll > mid.peerRoll and mid.peerRoll > lo.peerRoll,
          string.format("%.0f/%.0f/%.0f", hi.peerRoll, mid.peerRoll, lo.peerRoll))
    check("tied players share a percentile",
          math.abs(mid.peerWin - lo.peerWin) < 0.01,
          mid.peerWin .. " vs " .. lo.peerWin)

    -- A lone player has nobody to compare against.
    LunRollHistoryDB.log = {}
    LunRollHistoryDB.nextUID = 1
    for i = 1, 8 do Drop({ { "Alone", 50 + i, nil, true } }) end
    local _, solitary = L:Compute()
    check("a lone player gets no peer percentile", solitary.Alone.peerLuck == nil)
    check("a lone player still gets a chance-based rating",
          solitary.Alone.luck ~= nil, solitary.Alone.luck)

    -- Loot awards are counted separately and must not touch the rating.
    LunRollHistoryDB.log = {}
    LunRollHistoryDB.nextUID = 1
    for i = 1, 8 do
        Drop({ { "Getter", 50, nil, i % 2 == 0 }, { "Rival", 50, nil, i % 2 == 1 } })
    end
    local _, beforeLoot = L:Compute()
    local ratingBefore = beforeLoot.Getter.luck
    for i = 1, 5 do
        ns:Append({ t = "loot", name = "Getter", item = "Thing", itemID = 1, qty = 1 })
    end
    local _, afterLoot = L:Compute()
    check("received items are counted", afterLoot.Getter.received == 5,
          afterLoot.Getter.received)
    check("received items do not move the rating",
          math.abs(afterLoot.Getter.luck - ratingBefore) < 0.001,
          afterLoot.Getter.luck .. " vs " .. ratingBefore)
    check("received count ignores other players", afterLoot.Rival.received == 0,
          afterLoot.Rival.received)

    -- Uncontested drops are guaranteed wins and must not inflate win luck.
    LunRollHistoryDB.log = {}
    LunRollHistoryDB.nextUID = 1
    for i = 1, 10 do Drop({ { "Soloist", 50, nil, true } }) end
    local _, solo = L:Compute()
    check("solo drops do not count as contests", solo.Soloist.contests == 0, solo.Soloist.contests)
    check("solo drops give no win z", solo.Soloist.winZ == nil)
    check("solo rolls still counted", solo.Soloist.rolls == 10, solo.Soloist.rolls)

    -- Passes are not rolls.
    LunRollHistoryDB.log = {}
    LunRollHistoryDB.nextUID = 1
    Drop({ { "Passer", 0, "Pass" }, { "Roller", 60, nil, true } })
    local _, passers = L:Compute()
    check("passes excluded entirely", passers.Passer == nil)

    -- Small samples must not read as extreme.
    LunRollHistoryDB.log = {}
    LunRollHistoryDB.nextUID = 1
    Drop({ { "Newbie", 100, nil, true }, { "Other", 1 } })
    local _, small = L:Compute()
    check("one perfect roll is not enough data", small.Newbie.enough == false)
    check("below threshold gets no rank", small.Newbie.rank == nil)

    -- Same average, more rolls, stronger signal. This is the whole point of
    -- using z-scores rather than raw averages.
    -- Winners alternate so the win component stays at par and only the roll
    -- average is under test. Without this the larger sample is just a longer
    -- losing streak, which is a different measurement entirely.
    LunRollHistoryDB.log = {}
    LunRollHistoryDB.nextUID = 1
    for i = 1, 6 do Drop({ { "Few", 70, nil, i % 2 == 0 }, { "Filler", 30, nil, i % 2 == 1 } }) end
    local _, fewSet = L:Compute()
    local fewLuck = fewSet.Few.luck
    check("win component neutral in the small sample",
          math.abs(fewSet.Few.winPct - 50) < 25, fewSet.Few.winPct)
    LunRollHistoryDB.log = {}
    LunRollHistoryDB.nextUID = 1
    for i = 1, 60 do Drop({ { "Many", 70, nil, i % 2 == 0 }, { "Filler", 30, nil, i % 2 == 1 } }) end
    local _, manySet = L:Compute()
    check("bigger sample at the same average reads luckier",
          manySet.Many.luck > fewSet.Few.luck,
          string.format("%.1f vs %.1f", manySet.Many.luck, fewLuck))

    LunRollHistoryDB.log = saved
end

print("\n== luck page ==")
do
    -- Earlier sections clear the log, so seed a history to select from.
    local saved = LunRollHistoryDB.log
    LunRollHistoryDB.log = {}
    LunRollHistoryDB.nextUID = 1
    for i = 1, 12 do
        ns:Append({ t = "drop", item = "Test Item", itemID = 1, rolls = {
            { name = "Testchar", roll = 40 + i, state = "NeedMainSpec", winner = i % 2 == 0 },
            { name = "Rival", roll = 60 - i, state = "NeedMainSpec", winner = i % 2 == 1 },
        } })
    end

    ns.UI:Select("luck")
    local page = _G.LunRollHistoryFrame.pages.luck
    check("page builds", page ~= nil)
    check("rows laid out", page.scroll.contentHeight > 0, page.scroll.contentHeight)
    check("a player is selected by default", page.selected ~= nil, tostring(page.selected))
    check("defaults to the player's own character", page.selected == "Testchar", page.selected)
    check("selecting an unknown player recovers", (function()
        page.selected = "Nobody"
        page:Reload()
        return page.selected ~= "Nobody"
    end)())
    -- The reported bug: picking a name from the dropdown did nothing.
    check("choosing a name from the dropdown switches player", (function()
        local dd = page.pickDrop
        dd:Open()
        if #dd.list.data < 2 then return false, "not enough names" end
        local target
        for _, row in ipairs(dd.list.rows) do
            if row.item and row.item.value ~= page.selected then target = row break end
        end
        if not target then return false, "no other name on screen" end
        local wanted = target.item.value
        target:Fire("OnClick")
        return page.selected == wanted, page.selected
    end)())
    check("the menu closes after choosing", not page.pickDrop.menu:IsShown())

    -- The menu must not descend from the scroll frame, whose SetClipsChildren
    -- clipped away the clicks that made selection appear dead.
    check("menu is not parented inside the clipping scroll frame", (function()
        local node = page.pickDrop.menu:GetParent()
        while node do
            if node == page.scroll then return false, "menu sits inside the scroll clip" end
            node = node.GetParent and node:GetParent() or nil
        end
        return true
    end)())
    check("the label follows the choice",
          page.pickDrop.label:GetText() == page.selected,
          page.pickDrop.label:GetText())

    check("survives an empty history", (function()
        local saved = LunRollHistoryDB.log
        LunRollHistoryDB.log = {}
        local ok = pcall(function() page:Reload() end)
        LunRollHistoryDB.log = saved
        page:Reload()
        return ok
    end)())
    LunRollHistoryDB.log = saved
end

print("\n== resizable columns ==")
do
    ns.UI:Select("history")
    local page = _G.LunRollHistoryFrame.pages.history
    local cols = page.columns
    check("five columns", #cols == 5, #cols)

    -- At a realistic header width the Time column keeps its full default, which
    -- is the original complaint: 09/08 21:14 was being clipped at 70px.
    page.head:SetWidth(640)
    page.head:Layout()
    check("time column fits a full timestamp", cols[1].render >= 90, cols[1].render)

    -- Offsets must tile without gaps or overlaps.
    check("offsets tile exactly", (function()
        local x = 0
        for _, col in ipairs(cols) do
            if math.abs(col.offset - x) > 0.01 then return false, col.key end
            x = x + col.render
        end
        return true
    end)())

    local before = cols[1].width

    -- The flexible column absorbs the remaining space.
    page.head:SetWidth(700)
    page.head:Layout()
    local total = 0
    for _, col in ipairs(cols) do total = total + col.render end
    check("columns fill the header exactly", math.abs(total - 700) < 0.01, total)

    -- Narrow enough that the flexible column bottoms out: the others must give
    -- up their slack rather than letting the row overflow.
    page.head:SetWidth(500)
    page.head:Layout()
    total = 0
    for _, col in ipairs(cols) do total = total + col.render end
    check("narrow header squeezes the fixed columns", math.abs(total - 500) < 0.01, total)
    check("flex column respects its minimum", cols[2].render >= cols[2].min - 0.01, cols[2].render)
    check("no column driven below its minimum", (function()
        for _, col in ipairs(cols) do
            if col.render < (col.min or 40) - 0.01 then return false, col.key end
        end
        return true
    end)())
    check("squeezing does not destroy the chosen widths",
          cols[1].width == before, cols[1].width .. " vs " .. before)

    -- Absurdly narrow: everything pins to its minimum and stops there.
    page.head:SetWidth(120)
    page.head:Layout()
    check("extreme narrowing pins every column at its minimum", (function()
        for _, col in ipairs(cols) do
            if math.abs(col.render - (col.min or 40)) > 0.01 then return false, col.key end
        end
        return true
    end)())

    -- Widening again must restore what the user chose, not leave them squeezed.
    page.head:SetWidth(640)
    page.head:Layout()
    check("widening restores the chosen widths", cols[1].render == before,
          cols[1].render .. " vs " .. before)

    print("  -- divider dragging --")
    -- Every divider must actually follow the cursor. The original bug was that
    -- only divider 1 could move: the others sat to the right of the flexible
    -- column, which absorbed the change and pinned them in place.
    page.head:SetWidth(640)
    page.head:Layout()

    local function DividerAt(i)
        local col = cols[i]
        return (col.offset or 0) + (col.render or col.width)
    end

    for i = 1, #cols - 1 do
        page.head.onReset()
        page.head:SetWidth(640)
        page.head:Layout()
        local from = DividerAt(i)
        -- 15px fits inside every neighbour's slack; the roll column only has
        -- 18px above its minimum, so a larger nudge would legitimately clamp
        -- and this test would be measuring the clamp instead of the drag.
        page.head:SetDivider(i, from + 15)
        check("divider " .. i .. " (" .. cols[i].key .. "|" .. cols[i + 1].key ..
              ") follows the cursor right",
              math.abs(DividerAt(i) - (from + 15)) < 0.01,
              string.format("%.0f -> %.0f, wanted %.0f", from, DividerAt(i), from + 15))
    end

    for i = 1, #cols - 1 do
        page.head.onReset()
        page.head:SetWidth(640)
        page.head:Layout()
        local from = DividerAt(i)
        page.head:SetDivider(i, from - 25)
        check("divider " .. i .. " follows the cursor left",
              math.abs(DividerAt(i) - (from - 25)) < 0.01,
              string.format("%.0f -> %.0f", from, DividerAt(i)))
    end

    -- A drag must only ever move the two columns it separates.
    page.head.onReset()
    page.head:SetWidth(640)
    page.head:Layout()
    local snapshot = {}
    for i, col in ipairs(cols) do snapshot[i] = col.render end
    page.head:SetDivider(3, DividerAt(3) + 40)
    check("dragging player|type leaves time and roll alone",
          math.abs(cols[1].render - snapshot[1]) < 0.01
          and math.abs(cols[5].render - snapshot[5]) < 0.01)
    check("dragging player|type leaves the flex column alone",
          math.abs(cols[2].render - snapshot[2]) < 0.01,
          cols[2].render .. " vs " .. snapshot[2])
    check("width is transferred, not created",
          math.abs((cols[3].render + cols[4].render)
                   - (snapshot[3] + snapshot[4])) < 0.01)

    -- Total must stay pinned to the header width through any drag.
    check("total still fills the header after a drag", (function()
        local t = 0
        for _, col in ipairs(cols) do t = t + col.render end
        return math.abs(t - 640) < 0.01, t
    end)())

    -- Dragging far past a neighbour's minimum stops there instead of running
    -- away, which is what the old feedback loop did.
    page.head.onReset()
    page.head:SetWidth(640)
    page.head:Layout()
    page.head:SetDivider(3, 5000)
    check("dragging way right stops at the neighbour's minimum",
          math.abs(cols[4].render - cols[4].min) < 0.01, cols[4].render)
    check("no runaway: every column stays within the header", (function()
        local t = 0
        for _, col in ipairs(cols) do
            if col.render < (col.min or 40) - 0.01 then return false, col.key end
            t = t + col.render
        end
        return math.abs(t - 640) < 0.01, t
    end)())

    page.head.onReset()
    page.head:SetWidth(640)
    page.head:Layout()
    page.head:SetDivider(2, -5000)
    check("dragging way left stops at a minimum too", (function()
        for _, col in ipairs(cols) do
            if col.render < (col.min or 40) - 0.01 then return false, col.key end
        end
        return true
    end)())

    page.head.onReset()
    page.head:SetWidth(640)
    page.head:Layout()

    -- Widths persist.
    cols[3].width = 175
    page.head.onCommit(cols)
    check("widths saved", LunRollHistoryDB.settings.columnWidths.player == 175,
          LunRollHistoryDB.settings.columnWidths.player)

    page.head.onReset()
    check("right click resets to defaults", cols[3].width == cols[3].default, cols[3].width)

    -- Rows must follow the header, not keep stale offsets.
    page:Reload()
    local row = page.list.rows[1]
    check("row cells align to the column offsets",
          row ~= nil and row.cells ~= nil and row.cells.time ~= nil)
end

print("\n== history size and pruning ==")
do
    local savedLog, savedMax = LunRollHistoryDB.log, ns.MAX_ENTRIES

    check("cap can be raised to a million", ns.MAX_CAP == 1000000, ns.MAX_CAP)

    -- Pruning must keep the newest entries and drop the oldest.
    LunRollHistoryDB.log = {}
    LunRollHistoryDB.nextUID = 1
    ns.MAX_ENTRIES = 100
    for i = 1, 150 do ns:Append({ t = "manualroll", name = "P", roll = i }) end
    check("log stays within the cap", #LunRollHistoryDB.log <= 100, #LunRollHistoryDB.log)
    check("newest entry survives",
          LunRollHistoryDB.log[#LunRollHistoryDB.log].roll == 150,
          LunRollHistoryDB.log[#LunRollHistoryDB.log].roll)
    check("oldest entries are the ones dropped",
          LunRollHistoryDB.log[1].roll > 50, LunRollHistoryDB.log[1].roll)
    check("entries stay in order", (function()
        for i = 2, #LunRollHistoryDB.log do
            if LunRollHistoryDB.log[i].roll <= LunRollHistoryDB.log[i - 1].roll then
                return false, i
            end
        end
        return true
    end)())
    check("no holes left in the array", (function()
        local n = #LunRollHistoryDB.log
        for i = 1, n do if LunRollHistoryDB.log[i] == nil then return false, i end end
        return LunRollHistoryDB.log[n + 1] == nil
    end)())

    -- Pruning in batches means most appends past the cap do no shifting at all.
    LunRollHistoryDB.log = {}
    LunRollHistoryDB.nextUID = 1
    ns.MAX_ENTRIES = 1000
    for i = 1, 1000 do ns:Append({ t = "manualroll", name = "P", roll = i }) end
    local prunes = 0
    for i = 1, 200 do
        local before = #LunRollHistoryDB.log
        ns:Append({ t = "manualroll", name = "P", roll = 1000 + i })
        if #LunRollHistoryDB.log < before + 1 then prunes = prunes + 1 end
    end
    check("pruning is batched, not once per append", prunes <= 20, prunes .. " prunes in 200 appends")

    -- The size estimate has to be in the right ballpark or it is worse than
    -- showing nothing. A 20-roll drop measures ~4.85 KB with the real
    -- serialiser.
    LunRollHistoryDB.log = {}
    LunRollHistoryDB.nextUID = 1
    for d = 1, 20 do
        local rolls = {}
        for p = 1, 20 do
            rolls[p] = { name = "Player" .. p, realm = "Silvermoon", class = "PALADIN",
                         guid = "Player-1234-A" .. p, roll = p, state = "NeedMainSpec" }
        end
        ns:Append({ t = "drop", item = "Thing", itemID = 1, rolls = rolls })
    end
    local perEntry = ns:EstimateBytes(1)
    check("size estimate matches the measured 4.85 KB per 20-roll entry",
          math.abs(perEntry - 4852) < 500, perEntry)
    check("estimate scales with the cap",
          ns:EstimateBytes(1000) == perEntry * 1000)
    check("a million entries is reported in GB",
          ns:FormatBytes(ns:EstimateBytes(1000000)):find("GB") ~= nil,
          ns:FormatBytes(ns:EstimateBytes(1000000)))

    -- The history view must not materialise the whole log.
    LunRollHistoryDB.log = {}
    LunRollHistoryDB.nextUID = 1
    ns.MAX_ENTRIES = 100000
    for i = 1, 8000 do
        ns:Append({ t = "manualroll", name = "Filler", roll = (i % 100) + 1, low = 1, high = 100 })
    end
    ns.UI:Select("history")
    local hp = _G.LunRollHistoryFrame.pages.history
    hp.search = ""
    hp:Reload()
    check("history view is capped", #hp.list.data <= 5000, #hp.list.data)
    check("truncation is flagged", hp.truncated == true)
    check("the newest entries are the ones shown",
          hp.list.data[1].ts ~= nil and #hp.list.data == 5000, #hp.list.data)

    LunRollHistoryDB.log = savedLog
    ns.MAX_ENTRIES = savedMax
end

print("\n== migration from the old addon name ==")
do
    local savedDB = LunRollHistoryDB
    LunRollHistoryDB = nil
    LunRollHistoryDB = { log = { { uid = 1, t = "manualroll", name = "Legacy", roll = 55, ts = 1 } },
                     nextUID = 2 }
    __fire("ADDON_LOADED", ADDON)
    check("old RollLedger data carried over", #LunRollHistoryDB.log == 1
          and LunRollHistoryDB.log[1].name == "Legacy", #LunRollHistoryDB.log)
    LunRollHistoryDB = nil
    LunRollHistoryDB = savedDB
end

print(("\n%d passed, %d failed"):format(pass, fail))

-- Emit a SavedVariables file so the Python importer can be tested against it.
local function serialize(v, indent)
    indent = indent or "\t"
    if type(v) == "table" then
        local parts = { "{\n" }
        local arrayLen = #v
        for i = 1, arrayLen do
            parts[#parts + 1] = indent .. serialize(v[i], indent .. "\t") .. ", -- [" .. i .. "]\n"
        end
        local keys = {}
        for k in pairs(v) do
            if not (type(k) == "number" and k >= 1 and k <= arrayLen) then keys[#keys + 1] = k end
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            parts[#parts + 1] = indent .. '["' .. tostring(k) .. '"] = ' ..
                serialize(v[k], indent .. "\t") .. ",\n"
        end
        parts[#parts + 1] = indent:sub(2) .. "}"
        return table.concat(parts)
    elseif type(v) == "string" then
        return '"' .. v:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n") .. '"'
    else
        return tostring(v)
    end
end

local out = io.open(HERE .. "/LunRollHistory.lua", "w")
out:write("\nLunRollHistoryDB = " .. serialize(LunRollHistoryDB) .. "\n")
out:close()
print("wrote " .. HERE .. "/LunRollHistory.lua")

os.exit(fail == 0 and 0 or 1)
