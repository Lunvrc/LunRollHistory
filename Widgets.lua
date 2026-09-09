-- LunRollHistory :: Widgets.lua
-- A small widget kit built from plain textures. No Blizzard templates beyond
-- EditBox/ScrollFrame primitives, so nothing breaks when Blizzard reshuffles
-- template names between patches.

local ADDON, ns = ...

local W = {}
ns.Widgets = W

local T = ns.Theme
local C = T.colors

local WHITE = "Interface\\Buttons\\WHITE8X8"

--------------------------------------------------------------------------------
-- Primitives
--------------------------------------------------------------------------------
local function Fill(frame, layer, color, accent, accentAlpha)
    local tex = frame:CreateTexture(nil, layer or "BACKGROUND")
    tex:SetTexture(WHITE)
    tex:SetAllPoints(frame)
    if accent then
        T:Track(tex, "texture", accentAlpha or 1)
    else
        tex:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
    end
    return tex
end
W.Fill = Fill

-- 1px border drawn as four edges. Cheaper and sharper than a nine-slice.
local function Border(frame, color, accent)
    local edges = {}
    local sides = {
        { "TOPLEFT", "TOPRIGHT", 0, 0, 0, 0, nil, 1 },
        { "BOTTOMLEFT", "BOTTOMRIGHT", 0, 0, 0, 0, nil, 1 },
        { "TOPLEFT", "BOTTOMLEFT", 0, 0, 0, 0, 1, nil },
        { "TOPRIGHT", "BOTTOMRIGHT", 0, 0, 0, 0, 1, nil },
    }
    for i = 1, 4 do
        local s = sides[i]
        local tex = frame:CreateTexture(nil, "BORDER")
        tex:SetTexture(WHITE)
        tex:SetPoint(s[1], frame, s[1], 0, 0)
        tex:SetPoint(s[2], frame, s[2], 0, 0)
        if s[7] then tex:SetWidth(s[7]) end
        if s[8] then tex:SetHeight(s[8]) end
        if accent then
            T:Track(tex, "texture", 1)
        else
            tex:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
        end
        edges[i] = tex
    end
    frame.borderEdges = edges
    return edges
end
W.Border = Border

function W.Panel(parent, opts)
    opts = opts or {}
    local f = CreateFrame("Frame", nil, parent)
    if not opts.noBg then
        f.bg = Fill(f, "BACKGROUND", opts.color or C.panel, opts.accentBg, opts.bgAlpha)
    end
    if not opts.noBorder then
        f.border = Border(f, opts.borderColor or C.borderSoft, opts.accentBorder)
    end
    return f
end

function W.Text(parent, text, size, color, weight, family)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    T:SetFont(fs, size or 12, weight, family)
    fs:SetText(text or "")
    if color == "accent" then
        T:Track(fs, "text")
    else
        color = color or C.text
        fs:SetTextColor(color[1], color[2], color[3], color[4] or 1)
    end
    fs:SetJustifyH("LEFT")
    return fs
end

function W.Divider(parent, color)
    local tex = parent:CreateTexture(nil, "ARTWORK")
    tex:SetTexture(WHITE)
    tex:SetHeight(1)
    color = color or C.borderSoft
    tex:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
    return tex
end

--------------------------------------------------------------------------------
-- Buttons
--------------------------------------------------------------------------------
function W.Button(parent, text, onClick, opts)
    opts = opts or {}
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(opts.width or 132, opts.height or 28)

    b.bg = Fill(b, "BACKGROUND", C.panel)
    Border(b, opts.primary and C.border or C.borderSoft, opts.primary)

    b.label = W.Text(b, text, 12, opts.danger and { 0.90, 0.44, 0.44 } or C.text)
    b.label:SetPoint("CENTER")
    b.label:SetJustifyH("CENTER")

    b:SetScript("OnEnter", function(self)
        self.bg:SetColorTexture(C.panelHover[1], C.panelHover[2], C.panelHover[3], 1)
    end)
    b:SetScript("OnLeave", function(self)
        self.bg:SetColorTexture(C.panel[1], C.panel[2], C.panel[3], 1)
    end)
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

function W.CloseButton(parent, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(30, 30)
    b.bg = Fill(b, "BACKGROUND", C.panel)
    Border(b, C.borderSoft)
    b.label = W.Text(b, "x", 15, C.textDim)
    b.label:SetPoint("CENTER", 0, 1)
    b:SetScript("OnEnter", function(self)
        self.label:SetTextColor(1, 1, 1)
        self.bg:SetColorTexture(C.panelHover[1], C.panelHover[2], C.panelHover[3], 1)
    end)
    b:SetScript("OnLeave", function(self)
        self.label:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
        self.bg:SetColorTexture(C.panel[1], C.panel[2], C.panel[3], 1)
    end)
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

--------------------------------------------------------------------------------
-- Sidebar navigation
--------------------------------------------------------------------------------
function W.NavButton(parent, text, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(34)

    b.bg = Fill(b, "BACKGROUND", { 0, 0, 0, 0 })
    b.marker = b:CreateTexture(nil, "ARTWORK")
    b.marker:SetTexture(WHITE)
    b.marker:SetPoint("TOPLEFT", 0, 0)
    b.marker:SetPoint("BOTTOMLEFT", 0, 0)
    b.marker:SetWidth(2)
    T:Track(b.marker, "texture")
    b.marker:Hide()

    b.label = W.Text(b, text, 12.5, C.textDim)
    b.label:SetPoint("LEFT", 18, 0)

    function b:SetSelected(selected)
        self.selected = selected
        if selected then
            self.marker:Show()
            self.bg:SetColorTexture(1, 1, 1, 0.04)
            self.label:SetTextColor(1, 1, 1)
        else
            self.marker:Hide()
            self.bg:SetColorTexture(0, 0, 0, 0)
            self.label:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
        end
    end

    b:SetScript("OnEnter", function(self)
        if not self.selected then self.bg:SetColorTexture(1, 1, 1, 0.025) end
    end)
    b:SetScript("OnLeave", function(self)
        if not self.selected then self.bg:SetColorTexture(0, 0, 0, 0) end
    end)
    if onClick then b:SetScript("OnClick", onClick) end
    b:SetSelected(false)
    return b
end

function W.SectionLabel(parent, text)
    local fs = W.Text(parent, text, 11, "accent", nil, "display")
    return fs
end

--------------------------------------------------------------------------------
-- Tabs
--------------------------------------------------------------------------------
function W.Tab(parent, text, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(30)

    b.label = W.Text(b, text, 12.5, C.textDim)
    b.label:SetPoint("CENTER", 0, 3)

    b.underline = b:CreateTexture(nil, "ARTWORK")
    b.underline:SetTexture(WHITE)
    b.underline:SetPoint("BOTTOMLEFT", 0, 0)
    b.underline:SetPoint("BOTTOMRIGHT", 0, 0)
    b.underline:SetHeight(2)
    T:Track(b.underline, "texture")
    b.underline:Hide()

    local pad = 26
    b:SetWidth(math.max(64, (b.label:GetStringWidth() or 40) + pad))

    function b:SetSelected(selected)
        self.selected = selected
        if selected then
            self.underline:Show()
            self.label:SetTextColor(1, 1, 1)
        else
            self.underline:Hide()
            self.label:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
        end
    end

    b:SetScript("OnEnter", function(self)
        if not self.selected then self.label:SetTextColor(0.85, 0.82, 0.88) end
    end)
    b:SetScript("OnLeave", function(self)
        if not self.selected then self.label:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3]) end
    end)
    if onClick then b:SetScript("OnClick", onClick) end
    b:SetSelected(false)
    return b
end

--------------------------------------------------------------------------------
-- Toggle switch
--------------------------------------------------------------------------------
function W.Toggle(parent, getValue, setValue)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(42, 20)

    b.bg = Fill(b, "BACKGROUND", C.toggleOff)
    Border(b, C.borderSoft)

    b.thumb = b:CreateTexture(nil, "ARTWORK")
    b.thumb:SetTexture(WHITE)
    b.thumb:SetSize(16, 14)
    b.thumb:SetColorTexture(1, 1, 1, 0.92)

    -- The "on" fill is accent-tinted, so register a callback that repaints it
    -- whenever the accent changes while the toggle happens to be on.
    b.repaint = function()
        local on = getValue and getValue() or false
        if on then
            b.bg:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 0.85)
            b.thumb:ClearAllPoints()
            b.thumb:SetPoint("RIGHT", -3, 0)
        else
            b.bg:SetColorTexture(C.toggleOff[1], C.toggleOff[2], C.toggleOff[3], 1)
            b.thumb:ClearAllPoints()
            b.thumb:SetPoint("LEFT", 3, 0)
        end
    end
    T:Track(b.repaint, "callback")

    b:SetScript("OnClick", function()
        if setValue then setValue(not (getValue and getValue())) end
        b.repaint()
    end)
    b.Refresh = b.repaint
    b.repaint()
    return b
end

--------------------------------------------------------------------------------
-- Slider
--------------------------------------------------------------------------------
function W.Slider(parent, minV, maxV, step, getValue, setValue, formatFn)
    local s = CreateFrame("Frame", nil, parent)
    s:SetHeight(20)
    s:EnableMouse(true)

    s.track = s:CreateTexture(nil, "BACKGROUND")
    s.track:SetTexture(WHITE)
    s.track:SetHeight(4)
    s.track:SetPoint("LEFT", 0, 0)
    s.track:SetPoint("RIGHT", -52, 0)
    s.track:SetColorTexture(C.track[1], C.track[2], C.track[3], 1)

    s.fill = s:CreateTexture(nil, "ARTWORK")
    s.fill:SetTexture(WHITE)
    s.fill:SetHeight(4)
    s.fill:SetPoint("LEFT", s.track, "LEFT", 0, 0)
    T:Track(s.fill, "texture")

    s.thumb = CreateFrame("Button", nil, s)
    s.thumb:SetSize(12, 12)
    s.thumb.tex = s.thumb:CreateTexture(nil, "OVERLAY")
    s.thumb.tex:SetTexture(WHITE)
    s.thumb.tex:SetAllPoints(s.thumb)
    s.thumb.tex:SetColorTexture(1, 1, 1, 0.95)

    s.valueText = W.Text(s, "", 12, C.text)
    s.valueText:SetPoint("RIGHT", 0, 0)
    s.valueText:SetJustifyH("RIGHT")

    local function Clamp(v)
        if v < minV then return minV end
        if v > maxV then return maxV end
        return v
    end

    function s:Refresh()
        local v = Clamp(getValue and getValue() or minV)
        local pct = (maxV > minV) and ((v - minV) / (maxV - minV)) or 0
        local width = self.track:GetWidth() or 0
        self.fill:SetWidth(math.max(1, width * pct))
        self.thumb:ClearAllPoints()
        self.thumb:SetPoint("CENTER", self.track, "LEFT", width * pct, 0)
        self.valueText:SetText(formatFn and formatFn(v) or tostring(v))
    end

    local function ValueFromCursor()
        local scale = s:GetEffectiveScale() or 1
        local cursorX = (GetCursorPosition())
        local left = s.track:GetLeft()
        local width = s.track:GetWidth()
        if not left or not width or width <= 0 then return end
        local pct = ((cursorX / scale) - left) / width
        if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end
        local raw = minV + pct * (maxV - minV)
        local snapped = math.floor((raw - minV) / step + 0.5) * step + minV
        if setValue then setValue(Clamp(snapped)) end
        s:Refresh()
    end

    local function StartDrag(self)
        s.dragging = true
        s:SetScript("OnUpdate", ValueFromCursor)
    end
    local function StopDrag()
        s.dragging = false
        s:SetScript("OnUpdate", nil)
    end

    s.thumb:RegisterForClicks("LeftButtonDown", "LeftButtonUp")
    s.thumb:SetScript("OnMouseDown", StartDrag)
    s.thumb:SetScript("OnMouseUp", StopDrag)
    s:SetScript("OnMouseDown", function() ValueFromCursor(); StartDrag() end)
    s:SetScript("OnMouseUp", StopDrag)
    s:SetScript("OnHide", StopDrag)

    return s
end

--------------------------------------------------------------------------------
-- Setting row: label + description on the left, control on the right
--------------------------------------------------------------------------------
function W.SettingRow(parent, label, description, controlWidth)
    local row = W.Panel(parent, { color = C.row })
    row:SetHeight(description and 54 or 42)

    row.label = W.Text(row, label, 12.5, C.text)
    row.label:SetPoint("TOPLEFT", 14, description and -11 or -14)

    if description then
        row.desc = W.Text(row, description, 11, C.textFaint)
        row.desc:SetPoint("TOPLEFT", row.label, "BOTTOMLEFT", 0, -4)
        row.desc:SetPoint("RIGHT", row, "RIGHT", -(controlWidth or 60) - 24, 0)
        row.desc:SetJustifyH("LEFT")
        row.desc:SetWordWrap(true)
    end

    row.anchor = CreateFrame("Frame", nil, row)
    row.anchor:SetPoint("RIGHT", -14, 0)
    row.anchor:SetSize(controlWidth or 60, 22)

    -- Height comes from the text that is actually there. A fixed height means a
    -- description that wraps to three lines spills into the row below, and it
    -- breaks the moment someone raises the font size.
    function row:AutoHeight()
        local labelH = (self.label:GetStringHeight() or 14)
        if not self.desc then
            local h = math.max(38, labelH + 24)
            self:SetHeight(h)
            return h
        end
        local descH = (self.desc:GetStringHeight() or 12)
        local h = math.max(48, 12 + labelH + 5 + descH + 12)
        self:SetHeight(h)
        return h
    end

    return row
end

-- Stacks rows top to bottom, sizing each to its own content. Returns the total
-- height so the surrounding scroll area knows its range.
function W.StackRows(container, rows, spacing)
    spacing = spacing or 6
    local y = 0
    for i = 1, #rows do
        local row = rows[i]
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", container, "TOPLEFT", 0, y)
        row:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, y)
        -- Points first, then measure: the wrap width depends on the anchors.
        y = y - row:AutoHeight() - spacing
    end
    return -y
end

--------------------------------------------------------------------------------
-- Search box
--------------------------------------------------------------------------------
function W.SearchBox(parent, placeholder, onChanged)
    local holder = W.Panel(parent, { color = { 0.035, 0.024, 0.051, 1 } })
    holder:SetHeight(26)

    local edit = CreateFrame("EditBox", nil, holder)
    edit:SetPoint("TOPLEFT", 8, 0)
    edit:SetPoint("BOTTOMRIGHT", -8, 0)
    edit:SetAutoFocus(false)
    T:SetFont(edit, 12)
    edit:SetTextColor(1, 1, 1)

    local hint = W.Text(holder, placeholder or "Search...", 12, C.textFaint)
    hint:SetPoint("LEFT", 9, 0)

    edit:SetScript("OnTextChanged", function(self)
        local text = self:GetText() or ""
        if text == "" then hint:Show() else hint:Hide() end
        if onChanged then onChanged(text) end
    end)
    edit:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    holder.edit = edit
    return holder
end

--------------------------------------------------------------------------------
-- Virtualised list
--------------------------------------------------------------------------------
-- Only enough row frames to fill the viewport are ever created; scrolling
-- repoints data onto the existing rows. A 20,000-entry log costs the same as
-- a 20-entry one.
function W.List(parent, rowHeight, createRow, updateRow)
    local list = CreateFrame("Frame", nil, parent)
    list:SetClipsChildren(true)
    list:EnableMouseWheel(true)

    list.rows = {}
    list.data = {}
    list.offset = 0
    list.rowHeight = rowHeight

    local bar = CreateFrame("Frame", nil, list)
    bar:SetWidth(3)
    bar:SetPoint("TOPRIGHT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", 0, 0)
    local barTrack = bar:CreateTexture(nil, "BACKGROUND")
    barTrack:SetTexture(WHITE)
    barTrack:SetAllPoints(bar)
    barTrack:SetColorTexture(1, 1, 1, 0.05)
    local thumb = bar:CreateTexture(nil, "ARTWORK")
    thumb:SetTexture(WHITE)
    thumb:SetWidth(3)
    thumb:SetColorTexture(1, 1, 1, 0.25)
    list.scrollThumb = thumb

    function list:VisibleCount()
        local h = self:GetHeight() or 0
        return math.max(1, math.ceil(h / self.rowHeight) + 1)
    end

    function list:MaxOffset()
        local h = self:GetHeight() or 0
        local total = #self.data * self.rowHeight
        return math.max(0, math.ceil((total - h) / self.rowHeight))
    end

    function list:UpdateScrollThumb()
        local total = #self.data
        local visible = math.floor((self:GetHeight() or 0) / self.rowHeight)
        if total <= visible or total == 0 then
            self.scrollThumb:Hide()
            return
        end
        self.scrollThumb:Show()
        local h = self:GetHeight() or 1
        local fraction = visible / total
        local thumbH = math.max(20, h * fraction)
        local maxOff = self:MaxOffset()
        local progress = (maxOff > 0) and (self.offset / maxOff) or 0
        self.scrollThumb:SetHeight(thumbH)
        self.scrollThumb:ClearAllPoints()
        self.scrollThumb:SetPoint("TOP", bar, "TOP", 0, -progress * (h - thumbH))
    end

    function list:Refresh()
        local needed = self:VisibleCount()
        for i = #self.rows + 1, needed do
            local row = createRow(self)
            row:SetHeight(self.rowHeight)
            row:SetPoint("LEFT", self, "LEFT", 0, 0)
            row:SetPoint("RIGHT", self, "RIGHT", -6, 0)
            self.rows[i] = row
        end

        local maxOff = self:MaxOffset()
        if self.offset > maxOff then self.offset = maxOff end
        if self.offset < 0 then self.offset = 0 end

        for i = 1, #self.rows do
            local row = self.rows[i]
            local index = i + self.offset
            local entry = self.data[index]
            if entry and i <= needed then
                row:ClearAllPoints()
                row:SetPoint("LEFT", self, "LEFT", 0, 0)
                row:SetPoint("RIGHT", self, "RIGHT", -6, 0)
                row:SetPoint("TOP", self, "TOP", 0, -(i - 1) * self.rowHeight)
                updateRow(row, entry, index)
                row:Show()
            else
                row:Hide()
            end
        end
        self:UpdateScrollThumb()
    end

    function list:SetData(data)
        self.data = data or {}
        self.offset = 0
        self:Refresh()
    end

    list:SetScript("OnMouseWheel", function(self, delta)
        local step = IsShiftKeyDown() and 10 or 3
        self.offset = self.offset - delta * step
        self:Refresh()
    end)
    list:SetScript("OnSizeChanged", function(self) self:Refresh() end)

    return list
end

--------------------------------------------------------------------------------
-- Empty-state message
--------------------------------------------------------------------------------
function W.EmptyState(parent, text)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    f.label = W.Text(f, text, 12.5, C.textFaint)
    f.label:SetPoint("CENTER")
    f.label:SetJustifyH("CENTER")
    f:Hide()
    return f
end

--------------------------------------------------------------------------------
-- Dropdown
--------------------------------------------------------------------------------
-- Built from our own frames rather than Blizzard's dropdown, which would mean
-- touching UIDropDownMenu globals.
function W.Dropdown(parent, opts)
    opts = opts or {}
    local dd = W.Panel(parent, { color = C.panel })
    dd:SetSize(opts.width or 210, 24)

    dd.label = W.Text(dd, "", 12, C.text)
    dd.label:SetPoint("LEFT", 9, 0)
    dd.label:SetPoint("RIGHT", -22, 0)
    dd.label:SetWordWrap(false)

    dd.arrow = W.Text(dd, "v", 9, C.textDim)
    dd.arrow:SetPoint("RIGHT", -9, 0)

    -- Parented to UIParent, not to the dropdown. Settings pages live inside a
    -- scroll frame with SetClipsChildren(true), and a menu descending from that
    -- frame inherits the clip: it drew, but the clipped region swallowed the
    -- clicks, so picking a name did nothing. Anchoring across the parent
    -- boundary keeps it positioned without inheriting the clip.
    local menu = W.Panel(UIParent, { color = { 0.035, 0.024, 0.051, 1 }, borderColor = C.border })
    menu:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 0, -2)
    menu:SetPoint("TOPRIGHT", dd, "BOTTOMRIGHT", 0, -2)
    menu:Hide()

    -- Full-screen catcher so clicking anywhere else dismisses the menu. Its
    -- level is pinned in Open() rather than here: changing a frame's strata
    -- makes the client reassign levels, so anything captured at creation time
    -- can be stale by the time the menu is shown. When the catcher ended up
    -- above the menu it swallowed every click, which looked exactly like the
    -- menu ignoring selections.
    local catcher = CreateFrame("Frame", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:EnableMouse(true)
    catcher:Hide()
    -- Guarded so that even if the catcher ends up above the menu, a click on a
    -- name is never treated as a click outside it.
    catcher:SetScript("OnMouseDown", function()
        if menu:IsMouseOver() then return end
        dd:Close()
    end)

    local list = W.List(menu, 22,
        function(listFrame)
            local row = CreateFrame("Button", nil, listFrame)
            row.bg = W.Fill(row, "BACKGROUND", { 0, 0, 0, 0 })
            row.label = W.Text(row, "", 12, C.textDim)
            row.label:SetPoint("LEFT", 9, 0)
            row.label:SetPoint("RIGHT", -9, 0)
            row.label:SetWordWrap(false)
            row:SetScript("OnEnter", function(self)
                self.bg:SetColorTexture(1, 1, 1, 0.05)
            end)
            row:SetScript("OnLeave", function(self)
                self.bg:SetColorTexture(0, 0, 0, 0)
            end)
            row:SetScript("OnClick", function(self)
                if self.item and opts.setValue then opts.setValue(self.item.value, self.item) end
                dd:Close()
                dd:Refresh()
                if opts.onChanged then opts.onChanged(self.item) end
            end)
            return row
        end,
        function(row, item)
            row.item = item
            row.label:SetText(item.name)
            local current = opts.getValue and opts.getValue()
            if item.value == current then
                row.label:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
            else
                row.label:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])
            end
        end)
    list:SetPoint("TOPLEFT", 1, -4)
    list:SetPoint("BOTTOMRIGHT", -1, 4)

    function dd:Close()
        menu:Hide()
        catcher:Hide()
        dd.arrow:SetText("v")
    end

    function dd:Open()
        local items = (opts.getItems and opts.getItems()) or {}
        local height = math.min(#items * 22 + 8, opts.maxHeight or 200)
        menu:SetHeight(math.max(30, height))
        list:SetData(items)

        -- Set strata first, then levels, with absolute values. Relative offsets
        -- read from a frame whose strata just changed are not reliable.
        catcher:SetFrameStrata("FULLSCREEN_DIALOG")
        menu:SetFrameStrata("FULLSCREEN_DIALOG")
        catcher:SetFrameLevel(100)
        menu:SetFrameLevel(120)
        list:SetFrameLevel(125)

        catcher:Show()
        menu:Show()
        menu:Raise()
        list:Raise()
        dd.arrow:SetText("^")
    end

    function dd:Refresh()
        local value = opts.getValue and opts.getValue()
        local text = opts.labelFor and opts.labelFor(value) or tostring(value or "")
        dd.label:SetText(text)
    end

    dd.menu = menu
    dd.list = list

    local hit = CreateFrame("Button", nil, dd)
    hit:SetAllPoints(dd)
    hit:SetScript("OnClick", function()
        if menu:IsShown() then dd:Close() else dd:Open() end
    end)
    hit:SetScript("OnEnter", function()
        dd.bg:SetColorTexture(C.panelHover[1], C.panelHover[2], C.panelHover[3], 1)
    end)
    hit:SetScript("OnLeave", function()
        dd.bg:SetColorTexture(C.panel[1], C.panel[2], C.panel[3], 1)
    end)
    dd:SetScript("OnHide", function() dd:Close() end)

    dd:Refresh()
    return dd
end

--------------------------------------------------------------------------------
-- Hue bar
--------------------------------------------------------------------------------
-- Drawn as solid segments rather than a gradient texture: SetGradient's
-- signature has changed across expansions, a strip of flat quads has not.
local HUE_SEGMENTS = 60

function W.HueBar(parent, onPick)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(18)
    bar:EnableMouse(true)

    bar.segments = {}
    for i = 1, HUE_SEGMENTS do
        local seg = bar:CreateTexture(nil, "ARTWORK")
        seg:SetTexture(WHITE)
        local r, g, b = T.HSVtoRGB((i - 1) / HUE_SEGMENTS * 360, 1, 1)
        seg:SetColorTexture(r, g, b, 1)
        bar.segments[i] = seg
    end

    bar.marker = bar:CreateTexture(nil, "OVERLAY")
    bar.marker:SetTexture(WHITE)
    bar.marker:SetColorTexture(1, 1, 1, 1)
    bar.marker:SetSize(2, 24)

    W.Border(bar, C.borderSoft)

    function bar:LayoutSegments()
        local width = self:GetWidth() or 0
        if width <= 0 then return end
        local segWidth = width / HUE_SEGMENTS
        for i = 1, HUE_SEGMENTS do
            local seg = self.segments[i]
            seg:ClearAllPoints()
            seg:SetPoint("TOPLEFT", self, "TOPLEFT", (i - 1) * segWidth, 0)
            seg:SetSize(segWidth + 0.5, self:GetHeight() or 18)
        end
    end

    function bar:SetHue(hue)
        self.hue = hue % 360
        local width = self:GetWidth() or 0
        self.marker:ClearAllPoints()
        self.marker:SetPoint("CENTER", self, "LEFT", width * (self.hue / 360), 0)
    end

    local function PickFromCursor()
        local scale = bar:GetEffectiveScale() or 1
        local left = bar:GetLeft()
        local width = bar:GetWidth()
        if not left or not width or width <= 0 then return end
        local cx = (GetCursorPosition()) / scale
        local pct = (cx - left) / width
        if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end
        bar:SetHue(pct * 360)
        if onPick then onPick(bar.hue) end
    end

    bar:SetScript("OnMouseDown", function(self)
        PickFromCursor()
        self:SetScript("OnUpdate", PickFromCursor)
    end)
    bar:SetScript("OnMouseUp", function(self) self:SetScript("OnUpdate", nil) end)
    bar:SetScript("OnHide", function(self) self:SetScript("OnUpdate", nil) end)
    bar:SetScript("OnSizeChanged", function(self)
        self:LayoutSegments()
        self:SetHue(self.hue or 0)
    end)

    bar:SetHue(0)
    return bar
end

--------------------------------------------------------------------------------
-- Color picker
--------------------------------------------------------------------------------
function W.ColorPicker(parent, getRGB, setRGB)
    local picker = CreateFrame("Frame", nil, parent)
    picker:SetHeight(126)
    picker.h, picker.s, picker.v = 0, 1, 1
    picker.updating = false

    -- Live preview
    local swatch = W.Panel(picker, { color = C.panel, borderColor = C.border })
    swatch:SetSize(56, 56)
    swatch:SetPoint("TOPLEFT", 0, 0)
    local swatchFill = swatch:CreateTexture(nil, "ARTWORK")
    swatchFill:SetTexture(WHITE)
    swatchFill:SetPoint("TOPLEFT", 2, -2)
    swatchFill:SetPoint("BOTTOMRIGHT", -2, 2)
    picker.swatchFill = swatchFill

    -- Hex entry
    local hexBox = W.Panel(picker, { color = { 0.035, 0.024, 0.051, 1 } })
    hexBox:SetSize(56, 22)
    hexBox:SetPoint("TOPLEFT", swatch, "BOTTOMLEFT", 0, -8)
    local hexHash = W.Text(hexBox, "#", 11, C.textFaint)
    hexHash:SetPoint("LEFT", 6, 0)
    local hex = CreateFrame("EditBox", nil, hexBox)
    hex:SetPoint("TOPLEFT", 14, 0)
    hex:SetPoint("BOTTOMRIGHT", -4, 0)
    hex:SetAutoFocus(false)
    hex:SetMaxLetters(6)
    T:SetFont(hex, 11)
    hex:SetTextColor(1, 1, 1)
    picker.hex = hex

    local function Commit()
        local r, g, b = T.HSVtoRGB(picker.h, picker.s, picker.v)
        if setRGB then setRGB(r, g, b) end
        picker:Refresh(true)
    end

    -- Hue
    local hueLabel = W.Text(picker, "HUE", 10, C.textFaint)
    hueLabel:SetPoint("TOPLEFT", swatch, "TOPRIGHT", 16, -2)

    local hueBar = W.HueBar(picker, function(hue)
        picker.h = hue
        Commit()
    end)
    hueBar:SetPoint("TOPLEFT", hueLabel, "BOTTOMLEFT", 0, -4)
    hueBar:SetPoint("RIGHT", picker, "RIGHT", -70, 0)
    picker.hueBar = hueBar

    -- Saturation / value
    local satLabel = W.Text(picker, "SATURATION", 10, C.textFaint)
    satLabel:SetPoint("TOPLEFT", hueBar, "BOTTOMLEFT", 0, -12)
    local sat = W.Slider(picker, 0, 1, 0.01,
        function() return picker.s end,
        function(v) picker.s = v; Commit() end,
        function(v) return string.format("%d%%", v * 100 + 0.5) end)
    sat:SetPoint("TOPLEFT", satLabel, "TOPRIGHT", 10, 6)
    sat:SetPoint("RIGHT", picker, "RIGHT", 0, 0)
    picker.sat = sat

    local valLabel = W.Text(picker, "BRIGHTNESS", 10, C.textFaint)
    valLabel:SetPoint("TOPLEFT", satLabel, "BOTTOMLEFT", 0, -14)
    local val = W.Slider(picker, 0, 1, 0.01,
        function() return picker.v end,
        function(v) picker.v = v; Commit() end,
        function(v) return string.format("%d%%", v * 100 + 0.5) end)
    val:SetPoint("TOPLEFT", valLabel, "TOPRIGHT", 10, 6)
    val:SetPoint("RIGHT", picker, "RIGHT", 0, 0)
    picker.val = val

    hex:SetScript("OnEnterPressed", function(self)
        local r, g, b = T.HexToRGB(self:GetText())
        if r then
            picker.h, picker.s, picker.v = T.RGBtoHSV(r, g, b)
            if setRGB then setRGB(r, g, b) end
        end
        self:ClearFocus()
        picker:Refresh()
    end)
    hex:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        picker:Refresh()
    end)

    -- Quick presets, kept as shortcuts rather than the only choice.
    picker.presets = {}
    for i, preset in ipairs(T.accentPresets) do
        local dot = CreateFrame("Button", nil, picker)
        dot:SetSize(18, 18)
        dot:SetPoint("TOPLEFT", hexBox, "BOTTOMLEFT", (i - 1) * 22, -10)
        local fill = dot:CreateTexture(nil, "ARTWORK")
        fill:SetTexture(WHITE)
        fill:SetPoint("TOPLEFT", 1, -1)
        fill:SetPoint("BOTTOMRIGHT", -1, 1)
        fill:SetColorTexture(preset.color[1], preset.color[2], preset.color[3], 1)
        W.Border(dot, C.borderSoft)
        dot:SetScript("OnClick", function()
            picker.h, picker.s, picker.v = T.RGBtoHSV(preset.color[1], preset.color[2], preset.color[3])
            if setRGB then setRGB(preset.color[1], preset.color[2], preset.color[3]) end
            picker:Refresh()
        end)
        picker.presets[i] = dot
    end

    -- skipInputs is set while dragging so we do not fight the widget being used.
    function picker:Refresh(skipInputs)
        local r, g, b = T.HSVtoRGB(self.h, self.s, self.v)
        self.swatchFill:SetColorTexture(r, g, b, 1)
        if not skipInputs then
            self.hueBar:SetHue(self.h)
            self.sat:Refresh()
            self.val:Refresh()
        end
        if not hex:HasFocus() then
            hex:SetText(T.RGBtoHex(r, g, b))
        end
    end

    function picker:Load()
        local r, g, b = getRGB()
        self.h, self.s, self.v = T.RGBtoHSV(r, g, b)
        self:Refresh()
    end

    picker:Load()
    return picker
end


--------------------------------------------------------------------------------
-- Scrollable page
--------------------------------------------------------------------------------
-- Settings pages grow with their text, and the text grows with the font size
-- setting. Anything taller than the content area scrolls rather than running
-- off the bottom of the window.
function W.ScrollPage(parent)
    local clip = CreateFrame("Frame", nil, parent)
    clip:SetAllPoints(parent)
    clip:SetClipsChildren(true)
    clip:EnableMouseWheel(true)
    clip.offset = 0
    clip.contentHeight = 0

    local content = CreateFrame("Frame", nil, clip)
    content:SetHeight(1)
    clip.content = content

    local bar = CreateFrame("Frame", nil, clip)
    bar:SetWidth(3)
    bar:SetPoint("TOPRIGHT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", 0, 0)
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetTexture(WHITE)
    track:SetAllPoints(bar)
    track:SetColorTexture(1, 1, 1, 0.05)
    local thumb = bar:CreateTexture(nil, "ARTWORK")
    thumb:SetTexture(WHITE)
    thumb:SetWidth(3)
    thumb:SetColorTexture(1, 1, 1, 0.25)
    clip.scrollThumb = thumb

    function clip:MaxScroll()
        return math.max(0, (self.contentHeight or 0) - (self:GetHeight() or 0))
    end

    function clip:Update()
        local maxScroll = self:MaxScroll()
        if self.offset > maxScroll then self.offset = maxScroll end
        if self.offset < 0 then self.offset = 0 end

        content:ClearAllPoints()
        content:SetPoint("TOPLEFT", self, "TOPLEFT", 0, self.offset)
        content:SetPoint("TOPRIGHT", self, "TOPRIGHT", -8, self.offset)

        if maxScroll <= 0 then
            bar:Hide()
            return
        end
        bar:Show()
        local h = self:GetHeight() or 1
        local visibleFraction = h / math.max(1, self.contentHeight)
        local thumbH = math.max(20, h * visibleFraction)
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", bar, "TOP", 0, -(self.offset / maxScroll) * (h - thumbH))
    end

    function clip:SetContentHeight(height)
        self.contentHeight = height or 0
        content:SetHeight(math.max(1, self.contentHeight))
        self:Update()
    end

    clip:SetScript("OnMouseWheel", function(self, delta)
        self.offset = self.offset - delta * 34
        self:Update()
    end)
    clip:SetScript("OnSizeChanged", function(self) self:Update() end)

    clip:Update()
    return clip
end

--------------------------------------------------------------------------------
-- Resizable column header
--------------------------------------------------------------------------------
-- Owns the column widths and the drag handles between them. Rows ask it where
-- each column starts and how wide it is, so the header and the rows can never
-- disagree about the layout.
function W.ColumnHeader(parent, columns, onResize)
    local head = CreateFrame("Frame", nil, parent)
    head:SetHeight(22)
    head.columns = columns
    head.labels = {}
    head.handles = {}

    local underline = W.Divider(head)
    underline:SetPoint("BOTTOMLEFT", 0, 0)
    underline:SetPoint("BOTTOMRIGHT", 0, 0)

    for i, col in ipairs(columns) do
        col.width = col.width or col.default or 100

        local label = W.Text(head, col.title:upper(), 10, C.textFaint)
        label:SetJustifyH(col.justify or "LEFT")
        label:SetWordWrap(false)
        head.labels[i] = label

        -- No handle after the last column: there is nothing to its right to
        -- take the space from.
        if i < #columns then
            local handle = CreateFrame("Button", nil, head)
            handle:SetWidth(9)
            handle:SetPoint("TOP", 0, 0)
            handle:SetPoint("BOTTOM", 0, 0)
            handle:RegisterForClicks("LeftButtonDown", "RightButtonUp")
            handle:EnableMouse(true)

            local grip = handle:CreateTexture(nil, "ARTWORK")
            grip:SetTexture(WHITE)
            grip:SetPoint("TOP", 0, -3)
            grip:SetPoint("BOTTOM", 0, 2)
            grip:SetWidth(1)
            grip:SetColorTexture(1, 1, 1, 0.08)
            handle.grip = grip
            handle.index = i

            handle:SetScript("OnEnter", function(self)
                self.grip:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 0.9)
            end)
            handle:SetScript("OnLeave", function(self)
                if not self.dragging then self.grip:SetColorTexture(1, 1, 1, 0.08) end
            end)
            head.handles[i] = handle
        end
    end

    -- col.width is what the user chose and what gets saved. col.render is what
    -- actually gets drawn after fitting to the available space. Keeping them
    -- separate matters: squeezing col.width directly meant a narrow window
    -- permanently destroyed the user's widths, and widening it again never
    -- brought them back.
    function head:TotalWidth()
        local total = 0
        for _, col in ipairs(self.columns) do total = total + (col.render or col.width) end
        return total
    end

    function head:Layout()
        local available = (self:GetWidth() or 0)
        if available <= 0 then return end

        local fixed, flexIndex = 0, nil
        for i, col in ipairs(self.columns) do
            col.render = col.width
            if col.flex then flexIndex = i else fixed = fixed + col.width end
        end

        if flexIndex then
            local col = self.columns[flexIndex]
            col.render = math.max(col.min or 60, available - fixed)
        end

        -- If the flexible column has bottomed out at its minimum, take the
        -- overflow off the others in proportion to the slack each has above its
        -- own minimum, so the row never runs off the right edge.
        local overflow = self:TotalWidth() - available
        if overflow > 0.01 then
            local slack = 0
            for i, col in ipairs(self.columns) do
                if i ~= flexIndex then slack = slack + (col.render - (col.min or 40)) end
            end
            if slack > 0 then
                local take = math.min(overflow, slack)
                for i, col in ipairs(self.columns) do
                    if i ~= flexIndex then
                        local colSlack = col.render - (col.min or 40)
                        col.render = col.render - take * (colSlack / slack)
                    end
                end
            end
            -- Anything still over means every column is at its minimum and the
            -- header is genuinely too narrow; text truncates from here.
        end

        local x = 0
        for i, col in ipairs(self.columns) do
            col.offset = x
            local label = self.labels[i]
            label:ClearAllPoints()
            label:SetPoint("LEFT", self, "LEFT", x + (col.pad or 4), 0)
            label:SetWidth(math.max(10, col.render - (col.pad or 4) * 2))

            local handle = self.handles[i]
            if handle then
                handle:ClearAllPoints()
                handle:SetPoint("TOP", self, "TOPLEFT", x + col.render, 0)
                handle:SetPoint("BOTTOM", self, "BOTTOMLEFT", x + col.render, 0)
            end
            x = x + col.render
        end
        if onResize then onResize(self.columns) end
    end

    -- Dragging is expressed as "put divider i at position x", not "set column i
    -- to width w". The old version resized the column to the left of the
    -- divider, which cannot work when a flexible column sits further left: it
    -- absorbs the change, every column after it slides, and the divider itself
    -- never moves. Worse, the width was derived from the column's own offset,
    -- which the resize then changed, so each frame fed the next and the columns
    -- shot off sideways.
    --
    -- Moving a divider is a transfer between exactly the two columns it
    -- separates. If one of them is the flexible column it needs no explicit
    -- adjustment, since it absorbs whatever the other gives up.
    function head:SetDivider(index, targetX)
        local a, b = self.columns[index], self.columns[index + 1]
        if not a or not b then return end

        local current = (a.offset or 0) + (a.render or a.width)
        local delta = targetX - current
        if delta == 0 then return end

        local flex, flexRender
        for _, col in ipairs(self.columns) do
            if col.flex then flex, flexRender = col, col.render or col.width end
        end

        -- Neither column may go below its minimum...
        if not b.flex then
            delta = math.min(delta, (b.render or b.width) - (b.min or 40))
        end
        if not a.flex then
            delta = math.max(delta, -((a.render or a.width) - (a.min or 40)))
        end

        -- ...and neither may the flexible column, which is what actually gives
        -- up the space when the divider borders it.
        if flex then
            if a.flex then
                delta = math.max(delta, (flex.min or 60) - flexRender)
            elseif b.flex then
                delta = math.min(delta, flexRender - (flex.min or 60))
            end
        end

        if delta == 0 then return end

        if not a.flex then a.width = (a.render or a.width) + delta end
        if not b.flex then b.width = (b.render or b.width) - delta end

        self:Layout()
    end

    local function DragUpdate(handle)
        local scale = head:GetEffectiveScale() or 1
        local left = head:GetLeft()
        if not left then return end
        local cursorX = (GetCursorPosition()) / scale
        head:SetDivider(handle.index, cursorX - left)
    end

    for _, handle in pairs(head.handles) do
        handle:SetScript("OnMouseDown", function(self, button)
            if button ~= "LeftButton" then return end
            self.dragging = true
            self:SetScript("OnUpdate", DragUpdate)
        end)
        handle:SetScript("OnMouseUp", function(self)
            self.dragging = false
            self:SetScript("OnUpdate", nil)
            self.grip:SetColorTexture(1, 1, 1, 0.08)
            if head.onCommit then head.onCommit(head.columns) end
        end)
        handle:SetScript("OnClick", function(self, button)
            if button == "RightButton" and head.onReset then head.onReset() end
        end)
        handle:SetScript("OnHide", function(self)
            self.dragging = false
            self:SetScript("OnUpdate", nil)
        end)
    end

    head:SetScript("OnSizeChanged", function(self) self:Layout() end)
    return head
end

--------------------------------------------------------------------------------
-- Meter
--------------------------------------------------------------------------------
-- A 0-100 bar with a tick at the halfway mark, so "average" is visible rather
-- than something the reader has to infer from the fill length.
function W.Meter(parent)
    local meter = CreateFrame("Frame", nil, parent)
    meter:SetHeight(6)

    meter.track = meter:CreateTexture(nil, "BACKGROUND")
    meter.track:SetTexture(WHITE)
    meter.track:SetAllPoints(meter)
    meter.track:SetColorTexture(1, 1, 1, 0.06)

    meter.fill = meter:CreateTexture(nil, "ARTWORK")
    meter.fill:SetTexture(WHITE)
    meter.fill:SetPoint("TOPLEFT", 0, 0)
    meter.fill:SetPoint("BOTTOMLEFT", 0, 0)
    T:Track(meter.fill, "texture")

    meter.tick = meter:CreateTexture(nil, "OVERLAY")
    meter.tick:SetTexture(WHITE)
    meter.tick:SetWidth(1)
    meter.tick:SetPoint("TOP", meter, "TOP", 0, 2)
    meter.tick:SetPoint("BOTTOM", meter, "BOTTOM", 0, -2)
    meter.tick:SetColorTexture(1, 1, 1, 0.22)

    function meter:SetPercent(pct, color)
        local width = self:GetWidth() or 0
        if pct == nil then
            self.fill:Hide()
            return
        end
        self.fill:Show()
        pct = math.max(0, math.min(100, pct))
        self.fill:SetWidth(math.max(1, width * pct / 100))
        if color then
            self.fill:SetColorTexture(color[1], color[2], color[3], 1)
        else
            self.fill:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 1)
        end
        self.percent = pct
    end

    meter:SetScript("OnSizeChanged", function(self)
        if self.percent then self:SetPercent(self.percent) end
    end)
    return meter
end
