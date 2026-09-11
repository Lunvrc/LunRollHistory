-- LunRollHistory :: UI.lua
-- The main window. Sidebar navigation on the left, header + tab strip on the
-- right, one content page at a time, footer actions along the bottom.

local ADDON, ns = ...

local T = ns.Theme
local W = ns.Widgets
local C = T.colors

local UI = {}
ns.UI = UI

local WIDTH, HEIGHT = 940, 640
local SIDEBAR = 218
local HEADER = 96
local FOOTER = 54

local frame

--------------------------------------------------------------------------------
-- Data shaping
--------------------------------------------------------------------------------
local function ItemColor(link)
    if type(link) == "string" then
        local hex = link:match("|c%x%x(%x%x%x%x%x%x)")
        if hex then
            return tonumber(hex:sub(1, 2), 16) / 255,
                   tonumber(hex:sub(3, 4), 16) / 255,
                   tonumber(hex:sub(5, 6), 16) / 255
        end
    end
    return 1, 1, 1
end

-- Flattens the log into one view model per displayable line.
local MAX_VIEW_ROWS = 5000

local function BuildRows(filter, search)
    local db = LunRollHistoryDB
    local out = {}
    if not db then return out, false end
    search = (search or ""):lower()

    local function matches(vm)
        if search == "" then return true end
        return (vm.player and vm.player:lower():find(search, 1, true))
            or (vm.item and vm.item:lower():find(search, 1, true))
            or (vm.encounter and vm.encounter:lower():find(search, 1, true))
    end

    -- Newest first, and stop once the screen is fed. The list is virtualised,
    -- so building more than this is work nobody ever sees.
    for i = #db.log, 1, -1 do
        if #out >= MAX_VIEW_ROWS then return out, true end
        local e = db.log[i]
        if e.t == "drop" and type(e.rolls) == "table" then
            if filter == "all" or filter == "rolls" then
                for j = 1, #e.rolls do
                    local r = e.rolls[j]
                    local vm = {
                        ts = e.ts, kind = "roll",
                        item = e.item, link = e.link,
                        player = r.name, class = r.class,
                        rollType = r.state, roll = r.roll, winner = r.winner,
                        encounter = e.encName, instance = e.inst,
                    }
                    if matches(vm) then out[#out + 1] = vm end
                end
            end
        elseif e.t == "manualroll" then
            if filter == "all" or filter == "manual" then
                local vm = {
                    ts = e.ts, kind = "manual",
                    item = nil, player = e.name,
                    rollType = string.format("Manual %d-%d", e.low or 1, e.high or 100),
                    roll = e.roll, encounter = e.encName, instance = e.inst,
                }
                if matches(vm) then out[#out + 1] = vm end
            end
        elseif e.t == "loot" then
            if filter == "all" or filter == "loot" then
                local vm = {
                    ts = e.ts, kind = "loot",
                    item = e.item, link = e.link,
                    player = e.name, rollType = "Received",
                    encounter = e.encName, instance = e.inst, qty = e.qty,
                }
                if matches(vm) then out[#out + 1] = vm end
            end
        end
    end
    return out, false
end

-- Roll type buckets. The enum names are what Capture stores, but the labels
-- people actually use are shorter, so the mapping lives here rather than
-- leaking enum spelling into the interface.
local ROLL_FILTERS = {
    { key = "all",      label = "All" },
    { key = "need",     label = "Need",     states = { NeedMainSpec = true, Need = true } },
    { key = "greed",    label = "Greed",    states = { Greed = true } },
    { key = "transmog", label = "Transmog", states = { Transmog = true } },
}

local function RollFilterFor(key)
    for _, f in ipairs(ROLL_FILTERS) do
        if f.key == key then return f end
    end
    return ROLL_FILTERS[1]
end

local function BuildStats(filterKey)
    local db = LunRollHistoryDB
    local players, order = {}, {}
    if not db then return order end
    local filter = RollFilterFor(filterKey)

    local from = math.max(1, #db.log - ns.MAX_SCAN + 1)
    for i = from, #db.log do
        local e = db.log[i]
        if e.t == "drop" and type(e.rolls) == "table" then
            for j = 1, #e.rolls do
                local r = e.rolls[j]
                local contested = r.roll and r.roll > 0
                    and r.state ~= "Pass" and r.state ~= "NoRoll"
                local matches = contested
                    and (not filter.states or (r.state and filter.states[r.state]))
                if r.name and matches then
                    local p = players[r.name]
                    if not p then
                        p = { name = r.name, class = r.class, rolls = 0, wins = 0, total = 0 }
                        players[r.name] = p
                        order[#order + 1] = p
                    end
                    p.rolls = p.rolls + 1
                    p.total = p.total + r.roll
                    if r.winner then p.wins = p.wins + 1 end
                end
            end
        end
    end

    for _, p in ipairs(order) do
        p.avg = (p.rolls > 0) and (p.total / p.rolls) or 0
        p.winRate = (p.rolls > 0) and (p.wins / p.rolls) or 0
    end
    return order
end

-- Sorting is a separate step so the same data can be re-ordered without
-- rebuilding it from the log.
local STATS_COLUMNS = {
    { key = "name",    title = "Player",   ascending = true },
    { key = "winRate", title = "Win rate" },
    { key = "rolls",   title = "Rolls" },
    { key = "wins",    title = "Wins" },
    { key = "avg",     title = "Avg" },
}

local function SortStats(rows, key, descending)
    table.sort(rows, function(a, b)
        local x, y = a[key], b[key]
        if x == y or x == nil or y == nil then
            return (a.name or "") < (b.name or "")   -- stable, readable tiebreak
        end
        if descending then return x > y end
        return x < y
    end)
    return rows
end

--------------------------------------------------------------------------------
-- Page: Roll History
--------------------------------------------------------------------------------
local HISTORY_COLUMNS = {
    { key = "time",   title = "Time",   default = 96,  min = 56 },
    { key = "item",   title = "Item",   default = 250, min = 110, flex = true, ascending = true },
    { key = "player", title = "Player", default = 140, min = 80, ascending = true },
    { key = "type",   title = "Type",   default = 122, min = 70, ascending = true },
    { key = "roll",   title = "Roll",   default = 62,  min = 44, justify = "RIGHT" },
}

-- What each column sorts on. Text lowercased so the order is not split by
-- capitalisation, and missing values sort last rather than throwing.
local HISTORY_SORT = {
    time   = function(vm) return vm.ts or 0 end,
    item   = function(vm) return (vm.item or vm.encounter or ""):lower() end,
    player = function(vm) return (vm.player or ""):lower() end,
    type   = function(vm) return (vm.rollType or ""):lower() end,
    roll   = function(vm) return vm.roll or -1 end,
}

local function SortHistory(rows, key, descending)
    local accessor = HISTORY_SORT[key]
    if not accessor then return rows end
    table.sort(rows, function(a, b)
        local x, y = accessor(a), accessor(b)
        if x == y then
            -- Newest first within a tie, so equal rolls stay in a sane order.
            return (a.ts or 0) > (b.ts or 0)
        end
        if descending then return x > y end
        return x < y
    end)
    return rows
end

local function LoadColumnWidths(columns)
    local saved = LunRollHistoryDB and LunRollHistoryDB.settings.columnWidths
    for _, col in ipairs(columns) do
        local width = type(saved) == "table" and saved[col.key]
        col.width = math.max(col.min or 40, tonumber(width) or col.default)
    end
end

local function SaveColumnWidths(columns)
    if not LunRollHistoryDB then return end
    local out = {}
    for _, col in ipairs(columns) do out[col.key] = col.width end
    LunRollHistoryDB.settings.columnWidths = out
end

local function CreateHistoryPage(parent)
    local page = CreateFrame("Frame", nil, parent)
    page.tabs = { { key = "all", text = "All" }, { key = "rolls", text = "Loot Rolls" },
                  { key = "manual", text = "Manual" }, { key = "loot", text = "Awards" } }
    page.filter = "all"
    page.search = ""

    local search = W.SearchBox(page, "Filter by player, item, or boss...", function(text)
        page.search = text
        page:Reload()
    end)
    search:SetPoint("TOPLEFT", 0, 0)
    search:SetPoint("TOPRIGHT", 0, 0)

    -- Each page gets its own copy so dragging one does not mutate the template.
    local columns = {}
    for i, col in ipairs(HISTORY_COLUMNS) do
        columns[i] = {}
        for k, v in pairs(col) do columns[i][k] = v end
    end
    LoadColumnWidths(columns)

    local list

    page.sortKey, page.sortDesc = "time", true

    local head = W.ColumnHeader(page, columns, function()
        if list then list:Refresh() end
    end, {
        sortKey = "time", sortDesc = true,
        onSort = function(key, descending)
            page.sortKey, page.sortDesc = key, descending
            page:Reload()
        end,
    })
    head:SetPoint("TOPLEFT", search, "BOTTOMLEFT", 0, -10)
    head:SetPoint("TOPRIGHT", search, "BOTTOMRIGHT", 0, -10)
    head.onCommit = SaveColumnWidths
    head.onReset = function()
        for _, col in ipairs(columns) do col.width = col.default end
        head:Layout()
        SaveColumnWidths(columns)
    end
    page.head = head
    page.columns = columns

    -- Rows read their geometry from the column model, so a drag moves the
    -- header and every visible row together.
    local function PositionCells(row)
        for i, col in ipairs(columns) do
            local cell = row.cells[col.key]
            cell:ClearAllPoints()
            local pad = col.pad or 4
            cell:SetPoint("LEFT", row, "LEFT", (col.offset or 0) + pad, 0)
            cell:SetWidth(math.max(10, (col.render or col.width) - pad * 2))
            cell:SetJustifyH(col.justify or "LEFT")
        end
    end

    list = W.List(page, 26,
        function(listFrame)
            local row = CreateFrame("Frame", nil, listFrame)
            row.bg = W.Fill(row, "BACKGROUND", C.row)
            row.cells = {}
            row.cells.time   = W.Text(row, "", 11, C.textFaint)
            row.cells.item   = W.Text(row, "", 12, C.text)
            row.cells.player = W.Text(row, "", 12, C.text)
            row.cells.type   = W.Text(row, "", 11, C.textDim)
            row.cells.roll   = W.Text(row, "", 12.5, C.text)
            for _, cell in pairs(row.cells) do cell:SetWordWrap(false) end
            return row
        end,
        function(row, vm, index)
            PositionCells(row)
            row.bg:SetColorTexture(
                (index % 2 == 0) and C.rowAlt[1] or C.row[1],
                (index % 2 == 0) and C.rowAlt[2] or C.row[2],
                (index % 2 == 0) and C.rowAlt[3] or C.row[3], 1)

            row.cells.time:SetText(vm.ts and date("%m/%d %H:%M", vm.ts) or "")

            if vm.item then
                row.cells.item:SetText(vm.item)
                row.cells.item:SetTextColor(ItemColor(vm.link))
            else
                row.cells.item:SetText(vm.encounter or "-")
                row.cells.item:SetTextColor(C.textFaint[1], C.textFaint[2], C.textFaint[3])
            end

            row.cells.player:SetText(vm.player or "?")
            row.cells.player:SetTextColor(T:ClassColor(vm.class))

            row.cells.type:SetText(vm.rollType or "")
            if vm.rollType == "Pass" or vm.rollType == "NoRoll" then
                row.cells.type:SetTextColor(C.pass[1], C.pass[2], C.pass[3])
            else
                row.cells.type:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
            end

            if vm.roll and vm.roll > 0 then
                row.cells.roll:SetText(tostring(vm.roll))
                if vm.winner then
                    row.cells.roll:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
                else
                    row.cells.roll:SetTextColor(1, 1, 1)
                end
            elseif vm.kind == "loot" then
                row.cells.roll:SetText(vm.qty and vm.qty > 1 and ("x" .. vm.qty) or "-")
                row.cells.roll:SetTextColor(C.textFaint[1], C.textFaint[2], C.textFaint[3])
            else
                row.cells.roll:SetText("-")
                row.cells.roll:SetTextColor(C.textFaint[1], C.textFaint[2], C.textFaint[3])
            end
        end)

    list:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -4)
    list:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)

    local empty = W.EmptyState(list, "No rolls recorded yet.\nThey will appear here after your next raid drop.")

    function page:Reload()
        head:Layout()
        head:SetSort(self.sortKey, self.sortDesc)
        local rows, truncated = BuildRows(self.filter, self.search)
        SortHistory(rows, self.sortKey, self.sortDesc)
        list:SetData(rows)
        if #rows == 0 then empty:Show() else empty:Hide() end
        page.truncated = truncated
        if self.OnCount then self:OnCount(#rows) end
    end

    page.list = list
    return page
end

--------------------------------------------------------------------------------
-- Page: Statistics
--------------------------------------------------------------------------------
local function CreateStatsPage(parent)
    local page = CreateFrame("Frame", nil, parent)
    page.filter = "all"
    page.sortKey = "wins"
    page.sortDesc = true

    local caption = W.Text(page, "Counts only contested rolls. Passes and auto-greeds are excluded.",
        11, C.textFaint)
    caption:SetPoint("TOPLEFT", 2, -2)

    -- Roll type filter, pinned to the right of the caption.
    page.filterButtons = {}
    local previous
    for i = #ROLL_FILTERS, 1, -1 do
        local spec = ROLL_FILTERS[i]
        local b = CreateFrame("Button", nil, page)
        b:SetSize(66, 20)
        if previous then
            b:SetPoint("RIGHT", previous, "LEFT", -4, 0)
        else
            b:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, 2)
        end
        previous = b

        b.bg = W.Fill(b, "BACKGROUND", C.panel)
        W.Border(b, C.borderSoft)
        b.label = W.Text(b, spec.label, 11, C.textDim)
        b.label:SetPoint("CENTER")
        b.label:SetJustifyH("CENTER")
        b.filterKey = spec.key

        function b:Paint()
            if page.filter == self.filterKey then
                for _, edge in ipairs(self.borderEdges) do
                    edge:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 1)
                end
                self.label:SetTextColor(1, 1, 1)
            else
                for _, edge in ipairs(self.borderEdges) do
                    edge:SetColorTexture(C.borderSoft[1], C.borderSoft[2], C.borderSoft[3], 1)
                end
                self.label:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
            end
        end

        b:SetScript("OnEnter", function(self)
            self.bg:SetColorTexture(C.panelHover[1], C.panelHover[2], C.panelHover[3], 1)
        end)
        b:SetScript("OnLeave", function(self)
            self.bg:SetColorTexture(C.panel[1], C.panel[2], C.panel[3], 1)
        end)
        b:SetScript("OnClick", function(self)
            page.filter = self.filterKey
            page:Reload()
        end)
        page.filterButtons[#page.filterButtons + 1] = b
    end

    local head = CreateFrame("Frame", nil, page)
    head:SetHeight(20)
    head:SetPoint("TOPLEFT", caption, "BOTTOMLEFT", -2, -12)
    head:SetPoint("RIGHT", page, "RIGHT", 0, 0)

    local underline = W.Divider(head)
    underline:SetPoint("BOTTOMLEFT", 0, 0)
    underline:SetPoint("BOTTOMRIGHT", 0, 0)

    -- Column headers double as sort controls.
    page.headers = {}
    local LAYOUT = {
        name    = { point = "LEFT",  x = 4,    width = 180, justify = "LEFT" },
        winRate = { point = "LEFT",  x = 190,  width = 150, justify = "LEFT" },
        rolls   = { point = "RIGHT", x = -170, width = 50,  justify = "RIGHT" },
        wins    = { point = "RIGHT", x = -96,  width = 50,  justify = "RIGHT" },
        avg     = { point = "RIGHT", x = -14,  width = 50,  justify = "RIGHT" },
    }

    for _, col in ipairs(STATS_COLUMNS) do
        local layout = LAYOUT[col.key]
        local b = CreateFrame("Button", nil, head)
        b:SetPoint(layout.point, layout.x, 0)
        b:SetSize(layout.width, 20)

        b.label = W.Text(b, col.title:upper(), 10, C.textFaint)
        b.label:SetPoint(layout.point == "RIGHT" and "RIGHT" or "LEFT", 0, 0)
        b.label:SetJustifyH(layout.justify)
        b.colKey = col.key
        b.defaultAscending = col.ascending and true or false

        function b:Paint()
            if page.sortKey == self.colKey then
                -- The arrow points the way the values run down the column.
                self.label:SetText(col.title:upper() .. (page.sortDesc and "  v" or "  ^"))
                self.label:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
            else
                self.label:SetText(col.title:upper())
                self.label:SetTextColor(C.textFaint[1], C.textFaint[2], C.textFaint[3])
            end
        end

        b:SetScript("OnEnter", function(self)
            if page.sortKey ~= self.colKey then self.label:SetTextColor(0.8, 0.78, 0.84) end
        end)
        b:SetScript("OnLeave", function(self) self:Paint() end)
        b:SetScript("OnClick", function(self)
            if page.sortKey == self.colKey then
                page.sortDesc = not page.sortDesc
            else
                page.sortKey = self.colKey
                -- Names read best A to Z, numbers best highest first.
                page.sortDesc = not self.defaultAscending
            end
            page:Reload()
        end)
        page.headers[col.key] = b
    end

    local list = W.List(page, 30,
        function(listFrame)
            local row = CreateFrame("Frame", nil, listFrame)
            row.bg = W.Fill(row, "BACKGROUND", C.row)
            row.name = W.Text(row, "", 12.5, C.text)
            row.name:SetPoint("LEFT", 8, 0)
            row.name:SetWidth(170)

            row.barBg = row:CreateTexture(nil, "ARTWORK")
            row.barBg:SetTexture("Interface\\Buttons\\WHITE8X8")
            row.barBg:SetPoint("LEFT", 190, 0)
            row.barBg:SetSize(150, 6)
            row.barBg:SetColorTexture(1, 1, 1, 0.06)

            row.bar = row:CreateTexture(nil, "OVERLAY")
            row.bar:SetTexture("Interface\\Buttons\\WHITE8X8")
            row.bar:SetPoint("LEFT", row.barBg, "LEFT", 0, 0)
            row.bar:SetHeight(6)
            T:Track(row.bar, "texture")

            row.pct = W.Text(row, "", 11, C.textDim)
            row.pct:SetPoint("LEFT", row.barBg, "RIGHT", 8, 0)

            row.rolls = W.Text(row, "", 12, C.text)
            row.rolls:SetPoint("RIGHT", -170, 0)
            row.rolls:SetWidth(50)
            row.rolls:SetJustifyH("RIGHT")

            row.wins = W.Text(row, "", 12, C.text)
            row.wins:SetPoint("RIGHT", -96, 0)
            row.wins:SetWidth(50)
            row.wins:SetJustifyH("RIGHT")

            row.avg = W.Text(row, "", 12, C.textDim)
            row.avg:SetPoint("RIGHT", -14, 0)
            row.avg:SetWidth(50)
            row.avg:SetJustifyH("RIGHT")
            return row
        end,
        function(row, p, index)
            row.bg:SetColorTexture(
                (index % 2 == 0) and C.rowAlt[1] or C.row[1],
                (index % 2 == 0) and C.rowAlt[2] or C.row[2],
                (index % 2 == 0) and C.rowAlt[3] or C.row[3], 1)
            row.name:SetText(p.name)
            row.name:SetTextColor(T:ClassColor(p.class))
            row.bar:SetWidth(math.max(1, 150 * p.winRate))
            row.pct:SetText(string.format("%d%%", p.winRate * 100 + 0.5))
            row.rolls:SetText(tostring(p.rolls))
            row.wins:SetText(tostring(p.wins))
            row.avg:SetText(string.format("%.1f", p.avg))
        end)

    list:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -4)
    list:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)

    local empty = W.EmptyState(list, "Nothing to summarise yet.")

    function page:Reload()
        local stats = SortStats(BuildStats(self.filter), self.sortKey, self.sortDesc)
        self.rows = stats
        list:SetData(stats)
        if #stats == 0 then empty:Show() else empty:Hide() end
        for _, b in ipairs(self.filterButtons) do b:Paint() end
        for _, b in pairs(self.headers) do b:Paint() end
    end

    page.list = list
    return page
end

--------------------------------------------------------------------------------
-- Page: Am I Unlucky?
--------------------------------------------------------------------------------
-- Raid target icons rather than emoji: the client's fonts have no emoji
-- glyphs, so a star character renders as a blank box. These textures ship with
-- every install and inline cleanly in a FontString.
local ICON_STAR  = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:14:14|t"
local ICON_SKULL = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:14:14|t"

local LUCKY_AT, UNLUCKY_AT = 75, 25

local function Verdict(pct)
    if pct == nil then return "", nil end
    if pct >= LUCKY_AT then return ICON_STAR, C.win end
    if pct <= UNLUCKY_AT then return ICON_SKULL, C.bad end
    return "", nil
end

local function CreateLuckPage(parent)
    local page = CreateFrame("Frame", nil, parent)
    local scroll = W.ScrollPage(page)
    local body = scroll.content
    local rows = {}

    page.selected = nil

    -- Who are we looking at
    local pickRow = W.SettingRow(body, "Player",
        "Everyone who has rolled in your recorded history.", 210)
    local pickDrop = W.Dropdown(pickRow, {
        width = 210,
        maxHeight = 240,
        getItems = function()
            local items = {}
            for _, rec in ipairs(page.order or {}) do
                items[#items + 1] = {
                    name = rec.enough and rec.name or (rec.name .. "  (too few rolls)"),
                    value = rec.name,
                }
            end
            return items
        end,
        getValue = function() return page.selected end,
        setValue = function(name) page.selected = name end,
        labelFor = function(name) return name or "Nobody yet" end,
        onChanged = function() page:Reload() end,
    })
    pickDrop:SetPoint("RIGHT", -14, 0)
    rows[#rows + 1] = pickRow
    page.pickDrop = pickDrop

    -- Every row on this page shares one shape, so the headline is built from
    -- the same template as the metrics rather than a bigger bespoke one.
    local function MetricRow(title)
        local row = W.Panel(body, { color = C.row })
        row.title = W.Text(row, title, 12.5, C.text)
        row.title:SetPoint("TOPLEFT", 14, -12)

        row.value = W.Text(row, "-", 12.5, C.textDim)
        row.value:SetPoint("TOPRIGHT", -14, -12)
        row.value:SetJustifyH("RIGHT")

        row.meter = W.Meter(row)
        row.meter:SetPoint("TOPLEFT", 14, -36)
        row.meter:SetPoint("RIGHT", row, "RIGHT", -14, 0)

        row.verdict = W.Text(row, "", 11, C.textFaint)
        row.verdict:SetPoint("TOPLEFT", 14, -48)
        row.verdict:SetPoint("RIGHT", row, "RIGHT", -14, 0)
        row.verdict:SetWordWrap(true)

        function row:AutoHeight()
            local h = 48 + (self.verdict:GetStringHeight() or 12) + 14
            self:SetHeight(h)
            return h
        end

        function row:Set(valueText, pct, verdictText)
            self.value:SetText(valueText or "-")
            local icon, color = Verdict(pct)
            self.meter:SetPercent(pct, color)
            self.verdict:SetText(
                (icon ~= "" and (icon .. " ") or "") .. (verdictText or ""))
            if color then
                self.verdict:SetTextColor(color[1], color[2], color[3])
            else
                self.verdict:SetTextColor(C.textFaint[1], C.textFaint[2], C.textFaint[3])
            end
        end

        rows[#rows + 1] = row
        return row
    end

    local headline  = MetricRow("Luck Rating")
    local rollRow   = MetricRow("Average roll")
    local winRow    = MetricRow("Items obtained")
    local sampleRow = MetricRow("Sample size")

    sampleRow.meter:Hide()
    function sampleRow:AutoHeight()
        local titleH = self.title:GetStringHeight() or 14
        local h = 12 + titleH + 6 + (self.verdict:GetStringHeight() or 12) + 14
        self:SetHeight(h)
        self.verdict:ClearAllPoints()
        self.verdict:SetPoint("TOPLEFT", 14, -(12 + titleH + 6))
        self.verdict:SetPoint("RIGHT", self, "RIGHT", -14, 0)
        return h
    end

    local note = W.Text(body,
        "A /roll is uniform over 1 to 100, so your average has a known distribution. Items are scored against your share of each contest: four people rolling means one win in four is par. Both are z-scores, so a small sample is pulled toward the middle rather than reading as spectacular luck.",
        11, C.textFaint)
    note:SetJustifyH("LEFT")
    note:SetWordWrap(true)

    local noteHolder = CreateFrame("Frame", nil, body)
    note:SetPoint("TOPLEFT", noteHolder, "TOPLEFT", 2, -6)
    note:SetPoint("RIGHT", noteHolder, "RIGHT", -2, 0)
    function noteHolder:AutoHeight()
        local h = (note:GetStringHeight() or 30) + 16
        self:SetHeight(h)
        return h
    end
    rows[#rows + 1] = noteHolder

    -- "Luckier than X% of players" only when there are players to compare
    -- with. On your own, the comparison is against chance and says so.
    local function Phrase(peerPct, chancePct)
        if peerPct then
            local pct = math.floor(peerPct + 0.5)
            if pct >= 50 then
                return peerPct, string.format("Luckier than %d%% of players.", pct)
            end
            return peerPct, string.format("Unluckier than %d%% of players.", 100 - pct)
        end
        if chancePct then
            local pct = math.floor(chancePct + 0.5)
            if pct >= 50 then
                return chancePct, string.format("Luckier than %d%% of what chance would give you.", pct)
            end
            return chancePct, string.format("Unluckier than %d%% of what chance would give you.", 100 - pct)
        end
        return nil, ""
    end

    function page:Layout()
        scroll:SetContentHeight(W.StackRows(body, rows))
    end

    function page:Reload()
        local order, byName = ns.Luck:Compute()
        self.order, self.byName = order, byName

        if not self.selected or not byName[self.selected] then
            self.selected = ns.Luck:DefaultPlayer(byName)
                or (order[1] and order[1].name) or nil
        end
        pickDrop:Refresh()

        local rec = self.selected and byName[self.selected]

        if not rec or not rec.enough then
            headline:Set("-", nil, rec
                and string.format("Only %d contested %s so far. %d needed before a rating means anything.",
                    rec.rolls, rec.rolls == 1 and "roll" or "rolls", ns.Luck.MIN_ROLLS)
                or "No rolls recorded yet.")
            rollRow:Set("-", nil, "")
            winRow:Set("-", nil, "")
            sampleRow:Set("", nil, rec and string.format("%d rolls recorded.", rec.rolls) or "")
            self:Layout()
            return
        end

        local luckPct, luckText = Phrase(rec.peerLuck, rec.luck)
        headline:Set(luckPct and tostring(math.floor(luckPct + 0.5)) or "-", luckPct, luckText)

        local rollPct, rollText = Phrase(rec.peerRoll, rec.rollPct)
        rollRow:Set(string.format("%.1f", rec.avgRoll), rollPct, rollText)

        if rec.contests > 0 then
            local winPct, winText = Phrase(rec.peerWin, rec.winPct)
            winRow:Set(string.format("%d of %d", rec.wins, rec.contests), winPct,
                string.format("%s You won %d of the %d %s you rolled on.",
                    winText, rec.wins, rec.contests,
                    rec.contests == 1 and "item" or "items"))
        else
            winRow:Set("-", nil,
                "Nothing contested yet. An item nobody else rolled on is a certainty, not luck.")
        end

        -- The loot log is a separate observation and can legitimately disagree:
        -- traded items inflate it, the quality filter deflates it.
        local sampleText = string.format(
            "%d rolls across %d %s, %d of them contested.",
            rec.rolls, rec.items, rec.items == 1 and "item" or "items", rec.contests)
        if rec.received and rec.received > 0 then
            sampleText = sampleText .. string.format(
                " The loot log separately records %d %s reaching you.",
                rec.received, rec.received == 1 and "item" or "items")
        end
        sampleRow:Set("", nil, sampleText)

        self:Layout()
    end

    page.scroll = scroll
    page.rows = rows
    return page
end

--------------------------------------------------------------------------------
-- Page: Mythic+
--------------------------------------------------------------------------------
-- The dungeon grid builds itself from C_ChallengeMode.GetMapTable(), so a new
-- season needs no code change: names, icons and the tile count all come from
-- whatever the client is running. Only the abbreviation overrides in
-- Mythic.lua are worth touching by hand.
local TILE_W, TILE_H, TILE_GAP = 92, 88, 8

local function CreateMythicPage(parent)
    local page = CreateFrame("Frame", nil, parent)
    local scroll = W.ScrollPage(page)
    local body = scroll.content
    local rows = {}

    page.selectedMap = nil

    ---------------------------------------------------------------- grid ----
    local gridRow = W.Panel(body, { color = C.row })
    gridRow.title = W.Text(gridRow, "Season dungeons", 12.5, C.text)
    gridRow.title:SetPoint("TOPLEFT", 14, -12)
    gridRow.hint = W.Text(gridRow, "", 11, C.textFaint)
    gridRow.hint:SetPoint("TOPRIGHT", -14, -12)
    gridRow.hint:SetJustifyH("RIGHT")

    gridRow.tiles = {}

    local function AcquireTile(index)
        local tile = gridRow.tiles[index]
        if tile then return tile end

        tile = CreateFrame("Button", nil, gridRow)
        tile:SetSize(TILE_W, TILE_H)

        tile.art = tile:CreateTexture(nil, "ARTWORK")
        tile.art:SetPoint("TOPLEFT", 2, -2)
        tile.art:SetPoint("TOPRIGHT", -2, -2)
        tile.art:SetHeight(TILE_H - 24)
        -- Always full colour. Selection is shown with the accent border and a
        -- brightened label instead of draining the colour out of the rest.
        tile.art:SetDesaturated(false)

        tile.label = W.Text(tile, "", 12, C.textDim)
        tile.label:SetPoint("BOTTOM", 0, 4)
        tile.label:SetJustifyH("CENTER")
        tile.label:SetWidth(TILE_W - 4)

        tile.count = W.Text(tile, "", 10, C.textFaint)
        tile.count:SetPoint("TOPRIGHT", -5, -5)
        tile.count:SetJustifyH("RIGHT")

        W.Border(tile, C.borderSoft)

        tile:SetScript("OnEnter", function(self)
            if not self.selected then
                for _, edge in ipairs(self.borderEdges) do
                    edge:SetColorTexture(1, 1, 1, 0.35)
                end
            end
        end)
        tile:SetScript("OnLeave", function(self) self:Paint() end)
        tile:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        tile:SetScript("OnClick", function(self, button)
            -- Clicking the selected dungeon again, or right-clicking any of
            -- them, clears the selection and returns to the combined view.
            if button == "RightButton" or page.selectedMap == self.mapID then
                page.selectedMap = nil
            else
                page.selectedMap = self.mapID
            end
            page:Reload()
        end)

        function tile:Paint()
            if self.selected then
                for _, edge in ipairs(self.borderEdges) do
                    edge:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 1)
                end
                self.label:SetTextColor(1, 1, 1)
            else
                for _, edge in ipairs(self.borderEdges) do
                    edge:SetColorTexture(C.borderSoft[1], C.borderSoft[2], C.borderSoft[3], 1)
                end
                self.label:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
            end
        end

        gridRow.tiles[index] = tile
        return tile
    end

    -- Column count is chosen from the dungeon count, not from whatever width
    -- the frame happens to report. Eight dungeons give 4x2, which is what a
    -- season looks like; the width only ever caps it.
    local function ColumnsFor(count, maxFit)
        if count <= 0 then return 1, 1 end
        maxFit = math.max(1, maxFit)

        local perRow
        if count <= 5 and count <= maxFit then
            perRow = count                      -- a short season fits on one row
        else
            perRow = math.min(math.ceil(count / 2), maxFit)
        end

        -- Even the rows out so the last one is not left ragged.
        local lines = math.ceil(count / perRow)
        perRow = math.ceil(count / lines)
        return perRow, math.ceil(count / perRow)
    end

    function gridRow:Available()
        -- On the first pass this frame has not been anchored yet and reports
        -- zero, which is what stacked every tile into a single column until
        -- something forced a second layout.
        local width = self:GetWidth() or 0
        if width < 100 then width = body:GetWidth() or 0 end
        if width < 100 then width = scroll:GetWidth() or 0 end
        if width < 100 then width = (parent and parent:GetWidth()) or 0 end
        if width < 100 then width = 640 end
        return width
    end

    function gridRow:Arrange()
        local buckets = self.buckets or {}
        local available = self:Available() - 28
        local maxFit = math.max(1, math.floor((available + TILE_GAP) / (TILE_W + TILE_GAP)))
        local perRow, lines = ColumnsFor(#buckets, maxFit)

        -- Centre the block rather than left-aligning it against the panel edge.
        local blockWidth = perRow * TILE_W + (perRow - 1) * TILE_GAP
        local startX = 14 + math.max(0, (available - blockWidth) / 2)

        for i, bucket in ipairs(buckets) do
            local tile = self.tiles[i]
            if tile then
                local col = (i - 1) % perRow
                local line = math.floor((i - 1) / perRow)
                tile:ClearAllPoints()
                tile:SetPoint("TOPLEFT", self, "TOPLEFT",
                    startX + col * (TILE_W + TILE_GAP),
                    -36 - line * (TILE_H + TILE_GAP))
            end
        end

        self.perRow = perRow
        self.usedRows = lines
    end

    function gridRow:Populate(buckets)
        self.buckets = buckets

        for i, bucket in ipairs(buckets) do
            local tile = AcquireTile(i)
            tile.mapID = bucket.mapID
            tile.selected = (bucket.mapID == page.selectedMap)
            tile.label:SetText(bucket.abbr)
            tile.count:SetText(bucket.runs > 0 and tostring(bucket.runs) or "")

            if bucket.texture then
                tile.art:SetTexture(bucket.texture)
                tile.art:SetAlpha(1)
            else
                tile.art:SetTexture("Interface\\Buttons\\WHITE8X8")
                tile.art:SetColorTexture(C.panel[1], C.panel[2], C.panel[3], 1)
            end
            tile:Paint()
            tile:Show()
        end

        for i = #buckets + 1, #self.tiles do self.tiles[i]:Hide() end
        self:Arrange()
    end

    -- Any width change re-runs the arrangement, so a first pass that had no
    -- width to work with corrects itself instead of staying wrong until click.
    gridRow:SetScript("OnSizeChanged", function(self)
        if not self.buckets then return end
        local before = self.usedRows
        self:Arrange()
        if before ~= self.usedRows and page.Layout then page:Layout() end
    end)

    function gridRow:AutoHeight()
        local lines = self.usedRows or 1
        local h = 36 + lines * (TILE_H + TILE_GAP) + 6
        self:SetHeight(h)
        return h
    end
    rows[#rows + 1] = gridRow

    ------------------------------------------------------------- summary ----
    local function StatRow(title)
        local row = W.Panel(body, { color = C.row })
        row.title = W.Text(row, title, 12.5, C.text)
        row.title:SetPoint("TOPLEFT", 14, -12)
        row.value = W.Text(row, "-", 12.5, C.textDim)
        row.value:SetPoint("TOPRIGHT", -14, -12)
        row.value:SetJustifyH("RIGHT")
        row.meter = W.Meter(row)
        row.meter:SetPoint("TOPLEFT", 14, -36)
        row.meter:SetPoint("RIGHT", row, "RIGHT", -14, 0)
        row.verdict = W.Text(row, "", 11, C.textFaint)
        row.verdict:SetPoint("TOPLEFT", 14, -48)
        row.verdict:SetPoint("RIGHT", row, "RIGHT", -14, 0)
        row.verdict:SetWordWrap(true)

        function row:AutoHeight()
            local h = 48 + (self.verdict:GetStringHeight() or 12) + 14
            self:SetHeight(h)
            return h
        end
        function row:Set(valueText, pct, verdictText)
            self.value:SetText(valueText or "-")
            local icon, color = Verdict(pct)
            self.meter:SetPercent(pct, color)
            self.verdict:SetText((icon ~= "" and (icon .. " ") or "") .. (verdictText or ""))
            self.verdict:SetTextColor((color or C.textFaint)[1], (color or C.textFaint)[2],
                                      (color or C.textFaint)[3])
        end
        rows[#rows + 1] = row
        return row
    end

    local chestRow = StatRow("Chest luck")
    local runsRow  = StatRow("Runs")
    runsRow.meter:Hide()
    function runsRow:AutoHeight()
        local titleH = self.title:GetStringHeight() or 14
        local h = 12 + titleH + 6 + (self.verdict:GetStringHeight() or 12) + 14
        self:SetHeight(h)
        self.verdict:ClearAllPoints()
        self.verdict:SetPoint("TOPLEFT", 14, -(12 + titleH + 6))
        self.verdict:SetPoint("RIGHT", self, "RIGHT", -14, 0)
        return h
    end

    ---------------------------------------------------------- item table ----
    local itemsRow = W.Panel(body, { color = C.row })
    itemsRow.title = W.Text(itemsRow, "Items seen drop", 12.5, C.text)
    itemsRow.title:SetPoint("TOPLEFT", 14, -12)
    -- Recipes, patterns and reagents appear in the journal's list. Most people
    -- reading this page want gear, so they are hidden by default and this puts
    -- them back. Same switch the settings pages use, rather than a one-off.
    local miscToggle = W.Toggle(itemsRow,
        function() return LunRollHistoryDB and LunRollHistoryDB.settings.mplusShowNonGear end,
        function(value)
            LunRollHistoryDB.settings.mplusShowNonGear = value
            page:Reload()
        end)
    miscToggle:SetPoint("TOPRIGHT", -14, -11)
    itemsRow.miscToggle = miscToggle

    local miscLabel = W.Text(itemsRow, "Show misc items", 11.5, C.textDim)
    miscLabel:SetPoint("RIGHT", miscToggle, "LEFT", -8, 0)
    miscLabel:SetJustifyH("RIGHT")
    itemsRow.miscLabel = miscLabel

    itemsRow.hint = W.Text(itemsRow, "", 11, C.textFaint)
    itemsRow.hint:SetPoint("RIGHT", miscLabel, "LEFT", -12, 0)
    itemsRow.hint:SetJustifyH("RIGHT")
    itemsRow.lines = {}

    local function AcquireItemLine(index)
        local line = itemsRow.lines[index]
        if line then return line end
        line = CreateFrame("Frame", nil, itemsRow)
        line:SetHeight(20)
        line.name = W.Text(line, "", 12, C.text)
        line.name:SetPoint("LEFT", 0, 0)
        line.name:SetWordWrap(false)
        line.mine = W.Text(line, "", 11, C.textDim)
        line.mine:SetPoint("RIGHT", -70, 0)
        line.mine:SetWidth(90)
        line.mine:SetJustifyH("RIGHT")
        line.count = W.Text(line, "", 12, C.text)
        line.count:SetPoint("RIGHT", 0, 0)
        line.count:SetWidth(60)
        line.count:SetJustifyH("RIGHT")
        itemsRow.lines[index] = line
        return line
    end

    -- Strictly the journal's list for the current loot specialisation, with
    -- observed counts laid over it. Items seen drop that the journal does not
    -- list are deliberately not shown: they are off-spec loot that went to
    -- somebody else, and listing them makes this a record of the group's loot
    -- rather than a list of what this character can get.
    function itemsRow:Populate(bucket, specID)
        local shown, usedFilter = 0, false
        if bucket then
            local journal, filtered = ns.Mythic:LootTable(bucket.mapID, specID)
            usedFilter = filtered

            local showNonGear = LunRollHistoryDB
                and LunRollHistoryDB.settings.mplusShowNonGear
            local hidden = 0

            local list = {}
            for _, entry in ipairs(journal) do
                local gear = ns:IsGearItem(entry.itemID)
                if not gear and not showNonGear then
                    hidden = hidden + 1
                end
                local observed = bucket.items[entry.itemID]
                if gear or showNonGear then
                    list[#list + 1] = {
                        itemID = entry.itemID,
                        name = entry.name,
                        link = entry.link or (observed and observed.link),
                        slot = entry.slot,
                        count = observed and observed.count or 0,
                        mine = observed and observed.mine or 0,
                        warbound = observed and observed.warbound or 0,
                    }
                end
            end
            self.hiddenCount = hidden

            table.sort(list, function(a, b)
                if a.count ~= b.count then return a.count > b.count end
                return (a.name or "") < (b.name or "")
            end)

            for i, entry in ipairs(list) do
                if i > 60 then break end
                local line = AcquireItemLine(i)
                line:ClearAllPoints()
                line:SetPoint("TOPLEFT", self, "TOPLEFT", 14, -36 - (i - 1) * 20)
                line:SetPoint("RIGHT", self, "RIGHT", -14, 0)
                -- A name still loading shows as an ellipsis rather than a raw
                -- item number, and refreshes when the client answers.
                line.name:SetText(entry.name or "Loading...")
                line.name:SetWidth(math.max(60, (self:GetWidth() or 400) - 200))
                if entry.count > 0 then
                    line.name:SetTextColor(ItemColor(entry.link))
                else
                    -- Never seen: dimmed, so the gaps read at a glance.
                    line.name:SetTextColor(C.textFaint[1], C.textFaint[2], C.textFaint[3])
                end

                local detail = ""
                if entry.mine > 0 then detail = entry.mine .. " to you" end
                if entry.warbound > 0 then
                    detail = (detail ~= "" and (detail .. ", ") or "") .. entry.warbound .. " warbound"
                end
                line.mine:SetText(detail)

                if entry.count > 0 then
                    line.count:SetText(tostring(entry.count))
                    line.count:SetTextColor(1, 1, 1)
                else
                    line.count:SetText("-")
                    line.count:SetTextColor(C.textFaint[1], C.textFaint[2], C.textFaint[3])
                end
                line:Show()
                shown = i
            end
        end
        for i = shown + 1, #self.lines do self.lines[i]:Hide() end
        self.shown = shown
        self.usedFilter = usedFilter
    end

    function itemsRow:AutoHeight()
        local h = 36 + math.max(1, self.shown or 0) * 20 + 12
        self:SetHeight(h)
        return h
    end

    itemsRow.empty = W.Text(itemsRow, "", 11, C.textFaint)
    itemsRow.empty:SetPoint("TOPLEFT", 14, -38)
    rows[#rows + 1] = itemsRow

    local note = W.Text(body,
        "Runs and items are for this character only. The loot table is the Encounter Journal's list for your current loot specialisation and nothing else, rebuilt when you change spec; dimmed rows have never dropped for your group. Par is whatever the chest actually gave the group divided by the party size, so no assumption about how many items a run drops is baked in. Great Vault picks are excluded: that is a choice, not luck.",
        11, C.textFaint)
    note:SetJustifyH("LEFT")
    note:SetWordWrap(true)
    local noteHolder = CreateFrame("Frame", nil, body)
    note:SetPoint("TOPLEFT", noteHolder, "TOPLEFT", 2, -6)
    note:SetPoint("RIGHT", noteHolder, "RIGHT", -2, 0)
    function noteHolder:AutoHeight()
        local h = (note:GetStringHeight() or 30) + 16
        self:SetHeight(h)
        return h
    end
    rows[#rows + 1] = noteHolder

    function page:Layout()
        scroll:SetContentHeight(W.StackRows(body, rows))
    end

    function page:Reload()
        if not ns.Mythic then
            error("Mythic.lua is not loaded. Check that it is listed in LunRollHistory.toc.", 0)
        end
        local playerName = (select(1, UnitName("player")))
        local order, byMap, totals = ns.Mythic:Compute(playerName)
        self.buckets, self.byMap, self.totals = order, byMap, totals

        if self.selectedMap and not byMap[self.selectedMap] then self.selectedMap = nil end

        -- Lay out once before populating, so the grid has a real width to
        -- divide into columns rather than the zero it reports before anchoring.
        self:Layout()
        gridRow:Populate(order)

        local specName, specID = ns.Mythic:CurrentSpecName()
        if #order == 0 then
            gridRow.hint:SetText("No season dungeon list available")
        elseif self.selectedMap then
            gridRow.hint:SetText("Click again to see all dungeons")
        else
            gridRow.hint:SetText(string.format("%d dungeons this season", #order))
        end

        local bucket = self.selectedMap and byMap[self.selectedMap]
        local scope = bucket or totals

        if bucket then
            runsRow.title:SetText("Runs in " .. bucket.name)
            chestRow.title:SetText("Chest luck in " .. bucket.abbr)
        else
            runsRow.title:SetText("Runs across all dungeons")
            chestRow.title:SetText("Chest luck")
        end

        -- A dungeon with no runs still has a loot table worth seeing: "what can
        -- drop here" is a fair question before you have ever run it. Only the
        -- run-derived rows go blank.
        local hasRuns = (scope.runs or 0) > 0
        if not hasRuns then
            chestRow:Set("-", nil, "No completed runs recorded here yet.")
            runsRow:Set("", nil, bucket
                and "Nothing run here yet on this character."
                or "Complete a Mythic+ dungeon and the chest loot will be recorded automatically.")
        end
        itemsRow.empty:Hide()

        -- Items received out of chests opened, which is the question people
        -- actually ask. The expected share drives the bar and is stated in
        -- words rather than shown as a second, confusing number.
        local value = string.format("%d of %d", scope.mine, scope.runs)
        if not hasRuns then
            -- handled above
        elseif scope.enough and scope.luck then
            local pct = math.floor(scope.luck + 0.5)
            chestRow:Set(value, scope.luck, string.format(
                "%s You opened %d %s and took %d %s. Par is about %.1f.",
                pct >= 50
                    and string.format("Luckier than %d%% of what chance would give you.", pct)
                    or string.format("Unluckier than %d%% of what chance would give you.", 100 - pct),
                scope.runs, scope.runs == 1 and "chest" or "chests",
                scope.mine, scope.mine == 1 and "item" or "items",
                scope.expected))
        else
            chestRow:Set(value, nil, string.format(
                "You opened %d %s and took %d %s. %d runs needed before a rating means anything.",
                scope.runs, scope.runs == 1 and "chest" or "chests",
                scope.mine, scope.mine == 1 and "item" or "items",
                ns.Mythic.MIN_RUNS))
        end

        if hasRuns then
        local timedPct = (scope.runs > 0) and (scope.timed / scope.runs * 100) or 0
        local runsText = string.format("%d completed, %d timed (%d%%).",
            scope.runs, scope.timed, math.floor(timedPct + 0.5))
        if bucket and bucket.avgLevel > 0 then
            runsText = runsText .. string.format(" Average key level %.1f.", bucket.avgLevel)
        end
        if (scope.warbound or 0) > 0 then
            runsText = runsText .. string.format(" %d warbound %s.",
                scope.warbound, scope.warbound == 1 and "drop" or "drops")
        end
        runsRow:Set("", nil, runsText)
        end

        itemsRow.title:SetText("Loot table" .. (bucket and (" - " .. bucket.abbr) or ""))
        if bucket then
            itemsRow:Populate(bucket, specID)
            itemsRow.miscToggle:Refresh()
            local hintText = specName and ("Filtered to " .. specName) or ""
            if (itemsRow.hiddenCount or 0) > 0 then
                hintText = hintText .. string.format("   %d hidden", itemsRow.hiddenCount)
            end
            itemsRow.hint:SetText(hintText)
            if (itemsRow.shown or 0) == 0 then
                itemsRow.empty:SetText(
                    "The Encounter Journal returned no loot for this dungeon and specialisation.")
                itemsRow.empty:Show()
            else
                itemsRow.empty:Hide()
            end
        else
            itemsRow:Populate(nil)
            itemsRow.title:SetText("Loot table")
            itemsRow.hint:SetText("")
            itemsRow.empty:SetText("Pick a dungeon above to see its loot table.")
            itemsRow.empty:Show()
        end

        self:Layout()
    end

    page.scroll = scroll
    page.rows = rows
    page.grid = gridRow
    return page
end

--------------------------------------------------------------------------------
-- Page: Capture settings
--------------------------------------------------------------------------------
local function CreateCapturePage(parent)
    local page = CreateFrame("Frame", nil, parent)
    local scroll = W.ScrollPage(page)
    local body = scroll.content

    local rows, toggles = {}, {}

    local function AddToggle(label, desc, key)
        local row = W.SettingRow(body, label, desc, 42)
        local toggle = W.Toggle(row,
            function() return LunRollHistoryDB and LunRollHistoryDB.settings[key] end,
            function(v) LunRollHistoryDB.settings[key] = v end)
        toggle:SetPoint("RIGHT", -14, 0)
        row.toggle = toggle
        rows[#rows + 1] = row
        toggles[#toggles + 1] = toggle
        return row
    end

    AddToggle("Capture group loot rolls",
        "Reads the client's loot history, so every player's roll is recorded without anyone else installing this addon.",
        "captureLootHistory")
    AddToggle("Capture manual /roll",
        "Parses roll results out of the system chat channel for guilds that run rolls by hand.",
        "captureManualRolls")
    AddToggle("Capture loot awards",
        "Records who actually received each item, which is not always who won the roll.",
        "captureLootAwards")
    AddToggle("Capture roll windows",
        "Logs the moment a Need/Greed window opens. Useful for items that never resolve.",
        "captureRollStarts")
    AddToggle("Only record while grouped",
        "Ignores everything looted while solo.",
        "groupOnly")
    AddToggle("Sweep on open",
        "Sweeps the history every time you open the addon window.",
        "sweepOnOpen")

    local QUALITY = {
        { q = 0, name = "Everything" },
        { q = 1, name = "Common and better" },
        { q = 2, name = "Uncommon and better" },
        { q = 3, name = "Rare and better" },
        { q = 4, name = "Epic and better" },
        { q = 5, name = "Legendary only" },
    }

    local qualityRow = W.SettingRow(body, "Minimum loot quality",
        "Filters loot awards only. Reagents, cooking mats and vendor trash sit below Rare, which is what keeps them out of the history. Loot rolls are never filtered.", 210)
    local qualityDrop = W.Dropdown(qualityRow, {
        width = 210,
        getItems = function()
            local items = {}
            for _, entry in ipairs(QUALITY) do
                local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[entry.q]
                local name = entry.name
                if color and color.r then
                    name = string.format("|cff%s%s|r",
                        ns.Theme.RGBtoHex(color.r, color.g, color.b), entry.name)
                end
                items[#items + 1] = { name = name, value = entry.q }
            end
            return items
        end,
        getValue = function() return LunRollHistoryDB and LunRollHistoryDB.settings.minLootQuality end,
        setValue = function(q) LunRollHistoryDB.settings.minLootQuality = q end,
        labelFor = function(q)
            for _, entry in ipairs(QUALITY) do
                if entry.q == q then return entry.name end
            end
            return "Rare and better"
        end,
    })
    qualityDrop:SetPoint("RIGHT", -14, 0)
    rows[#rows + 1] = qualityRow

    AddToggle("Gear only",
        "Drops anything that is not a weapon or a piece of armour, so consumables and crafting reagents never reach the history.",
        "lootGearOnly")

    local cleanRow = W.SettingRow(body, "Clean up existing log",
        "Applies the two filters above to entries already recorded. Loot rolls and manual rolls are left alone.", 150)
    local cleanButton = W.Button(cleanRow, "Remove trash", function()
        local removed = ns:PruneLog()
        ns:Print(removed > 0
            and string.format("Removed %d filtered loot entries.", removed)
            or "Nothing to remove; the log already matches your filters.")
        UI:Refresh()
    end, { width = 140 })
    cleanButton:SetPoint("RIGHT", -14, 0)
    rows[#rows + 1] = cleanRow

    -- Stepped rather than linear: a 2,000 to 1,000,000 range on a linear slider
    -- makes every useful value sit in the first pixel.
    local SIZE_STOPS = { 2000, 5000, 10000, 25000, 50000, 100000, 250000, 500000, 1000000 }

    local function StopIndex(value)
        local best, bestDiff = 1, math.huge
        for i, stop in ipairs(SIZE_STOPS) do
            local diff = math.abs(stop - (value or 20000))
            if diff < bestDiff then best, bestDiff = i, diff end
        end
        return best
    end

    local function FormatStop(value)
        if value >= 1000000 then return string.format("%.0fM", value / 1000000) end
        return string.format("%.0fk", value / 1000)
    end

    local sliderRow = W.SettingRow(body, "History size",
        "Oldest entries are dropped past this.", 200)
    local slider = W.Slider(sliderRow, 1, #SIZE_STOPS, 1,
        function() return StopIndex(ns.MAX_ENTRIES) end,
        function(index)
            local value = SIZE_STOPS[math.max(1, math.min(#SIZE_STOPS, math.floor(index + 0.5)))]
            ns.MAX_ENTRIES = value
            if LunRollHistoryDB then LunRollHistoryDB.settings.maxEntries = value end
            if sliderRow.UpdateEstimate then sliderRow:UpdateEstimate() end
        end,
        function(index)
            return FormatStop(SIZE_STOPS[math.max(1, math.min(#SIZE_STOPS, math.floor(index + 0.5)))])
        end)
    slider:SetPoint("RIGHT", -14, 0)
    slider:SetWidth(200)

    -- The cost of a large cap should be visible here, not discovered at the
    -- next logout when the client writes the file.
    function sliderRow:UpdateEstimate()
        local bytes = ns:EstimateBytes(ns.MAX_ENTRIES)
        local text = string.format(
            "About %s of SavedVariables when full, written on logout. Import to SQLite regularly and the database outlives the window.",
            ns:FormatBytes(bytes))
        self.desc:SetText("Oldest entries are dropped past this. " .. text)
        if bytes > 512 * 1024 * 1024 then
            self.desc:SetTextColor(C.bad[1], C.bad[2], C.bad[3])
        else
            self.desc:SetTextColor(C.textFaint[1], C.textFaint[2], C.textFaint[3])
        end
    end
    rows[#rows + 1] = sliderRow

    function page:Layout()
        scroll:SetContentHeight(W.StackRows(body, rows))
    end

    function page:Reload()
        for _, toggle in ipairs(toggles) do toggle:Refresh() end
        qualityDrop:Refresh()
        slider:Refresh()
        sliderRow:UpdateEstimate()
        self:Layout()
    end

    page.scroll = scroll
    page.rows = rows
    return page
end

--------------------------------------------------------------------------------
-- Page: Appearance
--------------------------------------------------------------------------------
local function CreateAppearancePage(parent)
    local page = CreateFrame("Frame", nil, parent)
    local scroll = W.ScrollPage(page)
    local body = scroll.content

    local rows = {}

    -- Accent: a real picker, not a fixed palette.
    local accentRow = W.SettingRow(body, "Accent colour",
        "Applies immediately to every highlight in the window. Type a hex code or use the presets as a starting point.", 10)
    local picker = W.ColorPicker(accentRow,
        function() return T.accent[1], T.accent[2], T.accent[3] end,
        function(r, g, b) T:SetAccent(r, g, b) end)
    picker:SetPoint("TOPLEFT", accentRow, "TOPLEFT", 14, -58)
    picker:SetPoint("RIGHT", accentRow, "RIGHT", -14, 0)

    -- The picker sits below the description, so the row needs its own height.
    function accentRow:AutoHeight()
        local labelH = self.label:GetStringHeight() or 14
        local descH = self.desc and self.desc:GetStringHeight() or 0
        local h = 12 + labelH + 5 + descH + 14 + (picker:GetHeight() or 126) + 14
        self:SetHeight(h)
        picker:ClearAllPoints()
        picker:SetPoint("TOPLEFT", self, "TOPLEFT", 14, -(12 + labelH + 5 + descH + 14))
        picker:SetPoint("RIGHT", self, "RIGHT", -14, 0)
        return h
    end
    rows[#rows + 1] = accentRow

    local fontRow = W.SettingRow(body, "Font",
        "Client fonts, plus anything registered with LibSharedMedia if you have it installed.", 210)
    local fontDrop = W.Dropdown(fontRow, {
        width = 210,
        maxHeight = 220,
        getItems = function()
            local items = {}
            for _, entry in ipairs(T.fontList or {}) do
                items[#items + 1] = {
                    name = entry.shared and (entry.name .. "  (shared)") or entry.name,
                    value = entry.path,
                }
            end
            return items
        end,
        getValue = function() return T.fontPath end,
        setValue = function(path) T:SetFontFamily(path) end,
        labelFor = function(path) return T:FontNameFor(path) end,
    })
    fontDrop:SetPoint("RIGHT", -14, 0)
    rows[#rows + 1] = fontRow

    local sizeRow = W.SettingRow(body, "Font size",
        "Scales all text in the window. 100% is the client default size for each element.", 200)
    local sizeSlider = W.Slider(sizeRow, 0.7, 1.6, 0.05,
        function() return T.fontScale end,
        function(v) T:SetFontScale(v) end,
        function(v) return string.format("%d%%", v * 100 + 0.5) end)
    sizeSlider:SetPoint("RIGHT", -14, 0)
    sizeSlider:SetWidth(200)
    rows[#rows + 1] = sizeRow

    local mmRow = W.SettingRow(body, "Show minimap button",
        "Left click opens the window, right click jumps to capture settings.", 42)
    local mmToggle = W.Toggle(mmRow,
        function() return LunRollHistoryDB and not LunRollHistoryDB.settings.minimapHide end,
        function(v) ns.Minimap:Toggle(not v) end)
    mmToggle:SetPoint("RIGHT", -14, 0)
    rows[#rows + 1] = mmRow

    function page:Layout()
        scroll:SetContentHeight(W.StackRows(body, rows))
    end

    function page:Reload()
        picker:Load()
        fontDrop:Refresh()
        sizeSlider:Refresh()
        mmToggle:Refresh()
        self:Layout()
    end

    page.scroll = scroll
    page.rows = rows
    return page
end

--------------------------------------------------------------------------------
-- Page: Export
--------------------------------------------------------------------------------
local function CreateExportPage(parent)
    local page = CreateFrame("Frame", nil, parent)

    local caption = W.Text(page, "Select all and copy, or import the SavedVariables file directly with the bundled Python script.",
        11, C.textFaint)
    caption:SetPoint("TOPLEFT", 2, -2)

    local box = W.Panel(page, { color = { 0.035, 0.024, 0.051, 1 } })
    box:SetPoint("TOPLEFT", caption, "BOTTOMLEFT", -2, -12)
    box:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 34)

    local scroll = CreateFrame("ScrollFrame", nil, box)
    scroll:SetPoint("TOPLEFT", 8, -8)
    scroll:SetPoint("BOTTOMRIGHT", -8, 8)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetMaxLetters(0)
    edit:SetAutoFocus(false)
    edit:SetWidth(600)
    T:SetFont(edit, 11)
    edit:SetTextColor(0.85, 0.85, 0.88)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(edit)

    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll() or 0
        local maxScroll = self:GetVerticalScrollRange() or 0
        local target = current - delta * 40
        if target < 0 then target = 0 end
        if target > maxScroll then target = maxScroll end
        self:SetVerticalScroll(target)
    end)

    local hint = W.Text(page, "", 11, C.textFaint)
    hint:SetPoint("BOTTOMLEFT", 2, 10)

    function page:Reload()
        local csv, rows, truncated = ns:BuildCSV(4000)
        edit:SetText(csv)
        edit:SetCursorPosition(0)
        hint:SetText(string.format(
            "%d rows%s   |   Ctrl+A then Ctrl+C to copy",
            rows, truncated and " (truncated; use the importer for everything)" or ""))
    end

    page.edit = edit
    return page
end

--------------------------------------------------------------------------------
-- Page: About
--------------------------------------------------------------------------------
local function CreateAboutPage(parent)
    local outer = CreateFrame("Frame", nil, parent)
    local scroll = W.ScrollPage(outer)
    local body = scroll.content

    local lines = {
        { "LunRollHistory", 16, C.text, "display" },
        { "Logs every group loot roll, manual /roll, and loot award, then hands the data over in a form you can actually query.", 12, C.textDim },
        { "", 8, C.textDim },
        { "WHERE THE DATA LIVES", 11, "accent" },
        { "Addons cannot write files. Everything is stored in the account SavedVariables file, which the client writes on logout or /reload:", 12, C.textDim },
        { "WTF\\Account\\<ACCOUNT>\\SavedVariables\\LunRollHistory.lua", 11, C.text },
        { "", 8, C.textDim },
        { "TURNING IT INTO A DATABASE", 11, "accent" },
        { "Use this command:  python3 lunrollhistory_import.py <path to that file> --db rolls.sqlite --summary", 11, C.text },
        { "Or copy the CSV from the export tab and fix the structuring yourself.", 11, C.text },
        { "Rows are keyed on account and entry id, so re-running accumulates history instead of duplicating it.", 12, C.textDim },
        { "", 8, C.textDim },
        { "SLASH COMMANDS", 11, "accent" },
        { "/lrh                  open this window", 11, C.textDim },
        { "/lrh sweep            re-read the client's loot history and backfill", 11, C.textDim },
        { "/lrh clean            drop logged items that fail the current filters", 11, C.textDim },
        { "/lrh minimap          show or hide the minimap button", 11, C.textDim },
        { "/lrh stats            print a summary to chat", 11, C.textDim },
        { "/lrh wipe             clear the log", 11, C.textDim },
    }

    local strings, prev = {}, nil
    for _, spec in ipairs(lines) do
        local fs = W.Text(body, spec[1], spec[2], spec[3], nil, spec[4])
        if prev then
            fs:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -6)
        else
            fs:SetPoint("TOPLEFT", 2, -2)
        end
        fs:SetPoint("RIGHT", body, "RIGHT", -8, 0)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(true)
        strings[#strings + 1] = fs
        prev = fs
    end

    function outer:Layout()
        -- Measured rather than assumed: these lines wrap, and the wrap point
        -- moves with the font size setting.
        local total = 8
        for _, fs in ipairs(strings) do
            total = total + (fs:GetStringHeight() or 12) + 6
        end
        scroll:SetContentHeight(total)
    end
    outer.Reload = outer.Layout

    return outer
end

--------------------------------------------------------------------------------
-- Confirmation dialog
--------------------------------------------------------------------------------
-- Built from our own widgets rather than StaticPopup. Adding an entry to
-- StaticPopupDialogs means our insecure table reaches Blizzard's popup code on
-- every subsequent popup, not just ours.
local function BuildConfirm(parent)
    local overlay = CreateFrame("Frame", nil, parent)
    overlay:SetAllPoints(parent)
    overlay:SetFrameLevel((parent:GetFrameLevel() or 1) + 20)
    overlay:EnableMouse(true)
    W.Fill(overlay, "BACKGROUND", { 0, 0, 0, 0.6 })

    local box = W.Panel(overlay, { color = C.panel, borderColor = C.border })
    box:SetSize(420, 160)
    box:SetPoint("CENTER")

    box.title = W.Text(box, "", 15, C.text, nil, "display")
    box.title:SetPoint("TOPLEFT", 20, -20)

    box.body = W.Text(box, "", 12, C.textDim)
    box.body:SetPoint("TOPLEFT", box.title, "BOTTOMLEFT", 0, -10)
    box.body:SetPoint("RIGHT", box, "RIGHT", -20, 0)
    box.body:SetJustifyH("LEFT")
    box.body:SetWordWrap(true)

    local cancel = W.Button(box, "Cancel", function() overlay:Hide() end, { width = 110 })
    cancel:SetPoint("BOTTOMRIGHT", -20, 18)

    local accept = W.Button(box, "Delete", function()
        overlay:Hide()
        if overlay.onAccept then overlay.onAccept() end
    end, { width = 110, danger = true })
    accept:SetPoint("BOTTOMRIGHT", cancel, "BOTTOMLEFT", -10, 0)

    overlay.accept = accept
    overlay.box = box
    overlay:Hide()
    return overlay
end

--------------------------------------------------------------------------------
-- Page error surface
--------------------------------------------------------------------------------
-- WoW swallows errors thrown inside script handlers when Lua error display is
-- off, and a page that throws part-way through Reload leaves its rows
-- unanchored: a completely blank panel with nothing to go on. Reloads run
-- inside pcall and any failure is shown here instead.
local function BuildErrorPanel(parent)
    local panel = W.Panel(parent, { color = C.row, borderColor = C.border })
    panel:SetPoint("TOPLEFT", 0, 0)
    panel:SetPoint("TOPRIGHT", 0, 0)
    panel:SetHeight(150)

    panel.title = W.Text(panel, "This page failed to draw", 13, C.bad, nil, "display")
    panel.title:SetPoint("TOPLEFT", 14, -14)

    panel.body = W.Text(panel, "", 11, C.textDim)
    panel.body:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -10)
    panel.body:SetPoint("RIGHT", panel, "RIGHT", -14, 0)
    panel.body:SetJustifyH("LEFT")
    panel.body:SetWordWrap(true)

    panel.hint = W.Text(panel,
        "Run /lrh diag and send the output along with this message.", 11, C.textFaint)
    panel.hint:SetPoint("BOTTOMLEFT", 14, 12)
    panel:Hide()
    return panel
end

-- Runs a page reload, surfacing anything it throws rather than losing it.
local function SafeReload(page)
    if not page or not page.Reload then return true end
    local ok, err = pcall(page.Reload, page)
    if ok then
        if page.errorPanel then page.errorPanel:Hide() end
        return true
    end

    ns.lastPageError = tostring(err)
    if not page.errorPanel then
        page.errorPanel = BuildErrorPanel(page)
    end
    page.errorPanel.body:SetText(tostring(err))
    page.errorPanel:Show()
    page.errorPanel:Raise()
    ns:Print("|cffff6666Page error:|r", tostring(err))
    return false
end

--------------------------------------------------------------------------------
-- Window assembly
--------------------------------------------------------------------------------
local PAGES = {
    { key = "history",    label = "Roll History",     title = "Roll History",
      subtitle = "Every roll this client has witnessed, newest first.",  section = "HISTORY" },
    { key = "stats",      label = "Statistics",       title = "Statistics",
      subtitle = "Who rolls, who wins, and how the dice have actually been falling." },
    { key = "luck",       label = "Am I Unlucky?",    title = "Am I Unlucky?",
      subtitle = "Your rolls measured against what chance would have given you." },
    { key = "mplus",      label = "Mythic+",          title = "Mythic+",
      subtitle = "End-of-run chest loot, by dungeon." },
    { key = "capture",    label = "Capture Settings", title = "Capture Settings",
      subtitle = "What gets written to the history.", section = "SETUP" },
    { key = "appearance", label = "Appearance",       title = "Appearance",
      subtitle = "Colours for this window." },
    { key = "export",     label = "Export",           title = "Export",
      subtitle = "Copy the history out as CSV.", section = "DATA" },
    { key = "about",      label = "About",            title = "About",
      subtitle = "Where the data lives and how to query it." },
}

local BUILDERS = {
    history    = CreateHistoryPage,
    stats      = CreateStatsPage,
    luck       = CreateLuckPage,
    mplus      = CreateMythicPage,
    capture    = CreateCapturePage,
    appearance = CreateAppearancePage,
    export     = CreateExportPage,
    about      = CreateAboutPage,
}

local function BuildWindow()
    frame = CreateFrame("Frame", "LunRollHistoryFrame", UIParent)
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()

    W.Fill(frame, "BACKGROUND", C.window)
    W.Border(frame, C.border)

    ----------------------------------------------------------------- sidebar --
    local side = CreateFrame("Frame", nil, frame)
    side:SetPoint("TOPLEFT", 1, -1)
    side:SetPoint("BOTTOMLEFT", 1, 1)
    side:SetWidth(SIDEBAR)
    W.Fill(side, "BACKGROUND", C.sidebar)

    local sideEdge = side:CreateTexture(nil, "BORDER")
    sideEdge:SetTexture("Interface\\Buttons\\WHITE8X8")
    sideEdge:SetPoint("TOPRIGHT", 0, 0)
    sideEdge:SetPoint("BOTTOMRIGHT", 0, 0)
    sideEdge:SetWidth(1)
    sideEdge:SetColorTexture(C.border[1], C.border[2], C.border[3], 1)

    -- Logo. The TGA is padded to a power-of-two square; the texcoords crop the
    -- transparent side padding so the frame can use the art's real aspect.
    local mark = CreateFrame("Frame", nil, side)
    mark:SetSize(46 * T.LOGO_ASPECT, 46)
    mark:SetPoint("TOPLEFT", 18, -16)
    local logo = mark:CreateTexture(nil, "ARTWORK")
    logo:SetTexture(T.LOGO)
    logo:SetTexCoord(T.LOGO_COORDS[1], T.LOGO_COORDS[2], T.LOGO_COORDS[3], T.LOGO_COORDS[4])
    logo:SetAllPoints(mark)
    frame.logo = logo

    local wordmark = W.Text(side, "LunRollHistory", 14, C.text, nil, "display")
    wordmark:SetPoint("LEFT", mark, "RIGHT", 10, 6)
    local tagline = W.Text(side, "raid loot and roll history", 10, C.textFaint)
    tagline:SetPoint("TOPLEFT", wordmark, "BOTTOMLEFT", 1, -3)

    frame.nav = {}
    local navY = -84
    for _, spec in ipairs(PAGES) do
        if spec.section then
            local label = W.SectionLabel(side, spec.section)
            label:SetPoint("TOPLEFT", 20, navY - 8)
            navY = navY - 26
        end
        local button = W.NavButton(side, spec.label, function()
            UI:Select(spec.key)
        end)
        button:SetPoint("TOPLEFT", 0, navY)
        button:SetPoint("TOPRIGHT", side, "TOPRIGHT", -1, navY)
        frame.nav[spec.key] = button
        navY = navY - 34
    end

    frame.sideStatus = W.Text(side, "", 10, C.textFaint)
    frame.sideStatus:SetPoint("BOTTOMLEFT", 20, 16)
    frame.sideStatus:SetJustifyH("LEFT")

    ------------------------------------------------------------------ header --
    local header = CreateFrame("Frame", nil, frame)
    header:SetPoint("TOPLEFT", side, "TOPRIGHT", 0, 0)
    header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
    header:SetHeight(HEADER)
    W.Fill(header, "BACKGROUND", C.headerBg)

    -- Accent wash in the top-right. A single flat texture read as a hard-edged
    -- block against the header, so it is built from strips whose alpha falls
    -- off to zero on the left. SetGradient would do this in one texture, but
    -- its signature has moved around between expansions.
    local STRIPS, WASH_W = 14, 400
    for i = 1, STRIPS do
        local strip = header:CreateTexture(nil, "ARTWORK")
        strip:SetTexture("Interface\\Buttons\\WHITE8X8")
        strip:SetPoint("TOPRIGHT", -(i - 1) * (WASH_W / STRIPS), 0)
        strip:SetSize(WASH_W / STRIPS + 0.5, HEADER)
        local falloff = (1 - (i - 1) / STRIPS) ^ 1.8
        T:Track(strip, "texture", 0.07 * falloff)
    end

    -- Sits below the close button rather than running through it.
    local washLine = header:CreateTexture(nil, "OVERLAY")
    washLine:SetTexture("Interface\\Buttons\\WHITE8X8")
    washLine:SetPoint("TOPRIGHT", -24, -60)
    washLine:SetSize(180, 2)
    T:Track(washLine, "texture", 0.5)

    frame.title = W.Text(header, "", 24, C.text, nil, "display")
    frame.title:SetPoint("TOPLEFT", 28, -26)
    frame.subtitle = W.Text(header, "", 11.5, C.textDim)
    frame.subtitle:SetPoint("TOPLEFT", frame.title, "BOTTOMLEFT", 1, -6)

    frame.close = W.CloseButton(frame, function() UI:Hide() end)
    frame.close:SetPoint("TOPRIGHT", -10, -10)
    frame.close:SetFrameLevel((header:GetFrameLevel() or 1) + 10)

    local headerEdge = W.Divider(header, C.border)
    headerEdge:SetPoint("BOTTOMLEFT", 0, 0)
    headerEdge:SetPoint("BOTTOMRIGHT", 0, 0)

    -------------------------------------------------------------------- tabs --
    local tabStrip = CreateFrame("Frame", nil, frame)
    tabStrip:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 24, 0)
    tabStrip:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", -24, 0)
    tabStrip:SetHeight(32)
    frame.tabStrip = tabStrip
    frame.tabButtons = {}

    local tabEdge = W.Divider(tabStrip, C.borderSoft)
    tabEdge:SetPoint("BOTTOMLEFT", -24, 0)
    tabEdge:SetPoint("BOTTOMRIGHT", 24, 0)

    ------------------------------------------------------------------ footer --
    local footer = CreateFrame("Frame", nil, frame)
    footer:SetPoint("BOTTOMLEFT", side, "BOTTOMRIGHT", 0, 1)
    footer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    footer:SetHeight(FOOTER)
    W.Fill(footer, "BACKGROUND", C.footerBg)
    local footerEdge = W.Divider(footer, C.border)
    footerEdge:SetPoint("TOPLEFT", 0, 0)
    footerEdge:SetPoint("TOPRIGHT", 0, 0)

    local sweep = W.Button(footer, "Sweep History", function()
        ns.SweepAll()
        UI:Refresh()
    end, { width = 128 })
    sweep:SetPoint("LEFT", 20, 0)

    local wipe = W.Button(footer, "Clear Log", function()
        ns:ConfirmWipe()
    end, { width = 110, danger = true })
    wipe:SetPoint("LEFT", sweep, "RIGHT", 10, 0)

    local close = W.Button(footer, "Close", function() UI:Hide() end,
        { width = 110, primary = true })
    close:SetPoint("RIGHT", -20, 0)

    ------------------------------------------------------------------- pages --
    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", tabStrip, "BOTTOMLEFT", 0, -14)
    content:SetPoint("BOTTOMRIGHT", footer, "TOPRIGHT", -24, 14)
    frame.content = content
    frame.pages = {}
    frame.current = "history"

    -- Deliberately NOT registered in UISpecialFrames. Inserting into that
    -- Blizzard-owned table taints it, and the taint then rides along into
    -- CloseSpecialWindows and the ESC / game-menu path, which is where the
    -- "blocked from an action only available to the Blizzard UI" popup comes
    -- from. ESC is handled locally instead.
    frame:EnableKeyboard(false)
    frame:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" and not InCombatLockdown() then
            pcall(self.SetPropagateKeyboardInput, self, false)
            self:Hide()
        else
            pcall(self.SetPropagateKeyboardInput, self, true)
        end
    end)
    frame:SetScript("OnShow", function(self)
        -- Keyboard capture is left alone in combat: SetPropagateKeyboardInput
        -- is off limits under lockdown and would itself trigger a block.
        if not InCombatLockdown() then
            self:EnableKeyboard(true)
            pcall(self.SetPropagateKeyboardInput, self, true)
        end
        UI:Refresh()
    end)
    frame:SetScript("OnHide", function(self) self:EnableKeyboard(false) end)

    frame.confirm = BuildConfirm(frame)
    return frame
end

--------------------------------------------------------------------------------
-- Tabs are per page, so the strip is rebuilt on selection.
--------------------------------------------------------------------------------
local function LayoutTabs(page)
    for _, b in ipairs(frame.tabButtons) do b:Hide() end

    if type(page.tabs) ~= "table" then
        frame.tabStrip:Hide()
        frame.content:SetPoint("TOPLEFT", frame.tabStrip, "BOTTOMLEFT", 0, 4)
        return
    end
    frame.tabStrip:Show()
    frame.content:SetPoint("TOPLEFT", frame.tabStrip, "BOTTOMLEFT", 0, -14)

    local x = 0
    for i, spec in ipairs(page.tabs) do
        local b = frame.tabButtons[i]
        if not b then
            b = W.Tab(frame.tabStrip, spec.text)
            frame.tabButtons[i] = b
        end
        b.label:SetText(spec.text)
        b:SetWidth(math.max(64, (b.label:GetStringWidth() or 40) + 26))
        b:ClearAllPoints()
        b:SetPoint("BOTTOMLEFT", x, 0)
        b:SetScript("OnClick", function()
            page.filter = spec.key
            page:Reload()
            for j, other in ipairs(frame.tabButtons) do
                other:SetSelected(page.tabs[j] and page.tabs[j].key == spec.key)
            end
        end)
        b:SetSelected(spec.key == page.filter)
        b:Show()
        x = x + b:GetWidth()
    end
end

function UI:Select(key)
    if not frame then return end
    for _, spec in ipairs(PAGES) do
        local button = frame.nav[spec.key]
        if button then button:SetSelected(spec.key == key) end

        if spec.key == key then
            frame.title:SetText(spec.title)
            frame.subtitle:SetText(spec.subtitle or "")
        end
    end

    for pageKey, page in pairs(frame.pages) do
        if pageKey ~= key then page:Hide() end
    end

    local page = frame.pages[key]
    if not page then
        page = BUILDERS[key](frame.content)
        page:SetAllPoints(frame.content)
        frame.pages[key] = page
    end
    frame.current = key
    if not T.onFontsChanged then
        -- Tab widths are measured from the label, so they must be recomputed
        -- when the font or its size changes.
        T.onFontsChanged = function()
            local page = frame and frame.current and frame.pages[frame.current]
            if not page then return end
            LayoutTabs(page)
            -- Row heights are measured from wrapped text, so a font change
            -- invalidates every one of them.
            if page.Layout then page:Layout() end
        end
    end
    LayoutTabs(page)
    SafeReload(page)
    page:Show()
    self:UpdateStatus()
end

function UI:UpdateStatus()
    if not frame then return end
    local db = LunRollHistoryDB
    local entries = db and #db.log or 0
    local rolls = 0
    if db then
        for i = 1, #db.log do
            local e = db.log[i]
            if e.t == "drop" and type(e.rolls) == "table" then rolls = rolls + #e.rolls end
        end
    end
    frame.sideStatus:SetText(string.format("v%s\n%d entries  |  %d rolls",
        ns.VERSION or "1.0.0", entries, rolls))
end

function UI:Refresh()
    if not frame or not frame:IsShown() then return end
    local page = frame.pages[frame.current]
    SafeReload(page)
    self:UpdateStatus()
end

function UI:Show(key)
    if not frame then BuildWindow() end

    -- Re-read the client's loot history on open. Rolls that resolve while the
    -- window is shut, or while events were being missed, are picked up here
    -- rather than being lost. On by default; the Capture Settings page can
    -- turn it off.
    if LunRollHistoryDB and LunRollHistoryDB.settings.sweepOnOpen and ns.SweepAll then
        pcall(ns.SweepAll)
    end

    frame:Show()
    self:Select(key or frame.current or "history")
end

function UI:Hide()
    if frame then frame:Hide() end
end

function UI:Toggle(key)
    if frame and frame:IsShown() then
        self:Hide()
    else
        self:Show(key)
    end
end

function UI:IsShown()
    return frame and frame:IsShown()
end

function UI:Confirm(title, body, acceptLabel, onAccept)
    if not frame then BuildWindow() end
    if not frame:IsShown() then self:Show() end
    frame.confirm.box.title:SetText(title)
    frame.confirm.box.body:SetText(body)
    frame.confirm.accept.label:SetText(acceptLabel or "Confirm")
    frame.confirm.onAccept = onAccept
    frame.confirm:Show()
end

function UI:IsConfirmShown()
    return frame and frame.confirm and frame.confirm:IsShown()
end
