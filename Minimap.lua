-- LunRollHistory :: Minimap.lua
-- Minimap button plus an entry in the addon compartment (the menu behind the
-- icon next to the minimap clock).

local ADDON, ns = ...

local T = ns.Theme
local W = ns.Widgets
local C = T.colors

local RADIUS = 80
local button

--------------------------------------------------------------------------------
-- Addon compartment
--------------------------------------------------------------------------------
-- Hooked up by the TOC via AddonCompartmentFunc, which is the taint-free route:
-- the client calls us, we never write into a Blizzard table.
function LunRollHistory_OnAddonCompartmentClick(_, mouseButton)
    if mouseButton == "RightButton" then
        ns.UI:Show("capture")
    else
        ns.UI:Toggle()
    end
end

--------------------------------------------------------------------------------
-- Minimap button
--------------------------------------------------------------------------------
local function Angle()
    local db = LunRollHistoryDB
    return (db and db.settings.minimapAngle) or 198
end

local function Reposition()
    if not button or not Minimap then return end
    local rad = math.rad(Angle())
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER",
        math.cos(rad) * RADIUS, math.sin(rad) * RADIUS)
end

local function OnDragUpdate(self)
    local mx, my = Minimap:GetCenter()
    if not mx then return end
    local scale = Minimap:GetEffectiveScale() or 1
    local cx, cy = GetCursorPosition()
    cx, cy = cx / scale, cy / scale
    local angle = math.deg(math.atan2(cy - my, cx - mx))
    if LunRollHistoryDB then LunRollHistoryDB.settings.minimapAngle = angle end
    Reposition()
end

local function ShowTooltip(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("LunRollHistory")
    local db = LunRollHistoryDB
    if db then
        local rolls = 0
        for i = 1, #db.log do
            local e = db.log[i]
            if e.t == "drop" and type(e.rolls) == "table" then rolls = rolls + #e.rolls end
        end
        GameTooltip:AddLine(string.format("%d entries, %d rolls recorded", #db.log, rolls),
            0.6, 0.58, 0.66)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Left click: open the history", 1, 1, 1)
    GameTooltip:AddLine("Right click: capture settings", 1, 1, 1)
    GameTooltip:AddLine("Drag: move this button", 0.6, 0.58, 0.66)
    GameTooltip:Show()
end

local function Build()
    if button or not Minimap then return button end

    button = CreateFrame("Button", "LunRollHistoryMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetMovable(true)

    -- Icon, cropped to lose the baked bevel, then a dark ring drawn from flat
    -- textures so it matches the window rather than Blizzard's tracking border.
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(T.LOGO)
    icon:SetTexCoord(T.LOGO_COORDS[1], T.LOGO_COORDS[2], T.LOGO_COORDS[3], T.LOGO_COORDS[4])
    icon:SetSize(20 * T.LOGO_ASPECT, 20)
    icon:SetPoint("CENTER", 0, 0)
    button.icon = icon

    local backdrop = button:CreateTexture(nil, "BACKGROUND")
    backdrop:SetTexture("Interface\\Buttons\\WHITE8X8")
    backdrop:SetPoint("TOPLEFT", 4, -4)
    backdrop:SetPoint("BOTTOMRIGHT", -4, 4)
    backdrop:SetColorTexture(C.window[1], C.window[2], C.window[3], 0.9)

    local ring = CreateFrame("Frame", nil, button)
    ring:SetPoint("TOPLEFT", 3, -3)
    ring:SetPoint("BOTTOMRIGHT", -3, 3)
    W.Border(ring, C.border, true)
    button.ring = ring

    button:SetScript("OnEnter", function(self)
        ShowTooltip(self)
        self.icon:SetVertexColor(1, 1, 1)
    end)
    button:SetScript("OnLeave", function(self)
        if GameTooltip then GameTooltip:Hide() end
        self.icon:SetVertexColor(0.85, 0.85, 0.85)
    end)
    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then
            ns.UI:Show("capture")
        else
            ns.UI:Toggle()
        end
    end)
    button:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", OnDragUpdate)
        if GameTooltip then GameTooltip:Hide() end
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    button.icon:SetVertexColor(0.85, 0.85, 0.85)
    Reposition()
    return button
end

--------------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------------
ns.Minimap = {}

function ns.Minimap:Refresh()
    local db = LunRollHistoryDB
    if not db then return end
    if db.settings.minimapHide then
        if button then button:Hide() end
        return
    end
    Build()
    if button then
        Reposition()
        button:Show()
    end
end

function ns.Minimap:Toggle(hidden)
    if LunRollHistoryDB then LunRollHistoryDB.settings.minimapHide = hidden and true or false end
    self:Refresh()
end

local prevOnDBReady = ns.OnDBReady
function ns.OnDBReady()
    if prevOnDBReady then prevOnDBReady() end
    ns.Minimap:Refresh()
end
