-- LunRollHistory :: Minimap.lua
-- Minimap button plus an entry in the addon compartment (the menu behind the
-- icon next to the minimap clock).

local ADDON, ns = ...

local T = ns.Theme
local W = ns.Widgets
local C = T.colors

-- Declared here rather than further down: the positioning helpers below are
-- part of this table and need it to exist before they are defined.
local M = {}
ns.Minimap = M

local EDGE_GAP = 5         -- how far outside the minimap edge the icon sits
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

-- Where the icon sits for a given angle.
--
-- This used to be a fixed radius of 80, which is only correct for the default
-- 140px minimap: 70 to the edge plus 10 outside it. Anyone running an enlarged
-- minimap, which most interface packs do, got the icon dragged inside the
-- circle. The radius comes from the minimap's actual size now.
function M:IconOffset(angle)
    local rad = math.rad(angle or Angle())
    local cos, sin = math.cos(rad), math.sin(rad)

    local width = (Minimap and Minimap.GetWidth and Minimap:GetWidth()) or 140
    local height = (Minimap and Minimap.GetHeight and Minimap:GetHeight()) or width
    if width <= 0 then width = 140 end
    if height <= 0 then height = width end

    local halfW = width / 2 + EDGE_GAP
    local halfH = height / 2 + EDGE_GAP

    -- Square minimaps come from other addons, which advertise the shape
    -- through this global. Following the border means clamping to the box
    -- rather than tracing a circle inside it.
    local shape = "ROUND"
    if type(_G.GetMinimapShape) == "function" then
        local ok, value = pcall(_G.GetMinimapShape)
        if ok and type(value) == "string" then shape = value end
    end
    if shape:find("SQUARE") then
        local reach = math.max(math.abs(cos), math.abs(sin))
        if reach > 0 then cos, sin = cos / reach, sin / reach end
    end

    return cos * halfW, sin * halfH
end

local function Reposition()
    if not button or not Minimap then return end
    local x, y = M:IconOffset()
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
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

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(T.LOGO)
    button.icon = icon

    -- Flat square styling: matches the addon's own window.
    local backdrop = button:CreateTexture(nil, "BACKGROUND")
    backdrop:SetTexture("Interface\\Buttons\\WHITE8X8")
    backdrop:SetPoint("TOPLEFT", 4, -4)
    backdrop:SetPoint("BOTTOMRIGHT", -4, 4)
    backdrop:SetColorTexture(C.window[1], C.window[2], C.window[3], 0.9)
    button.backdrop = backdrop

    local ring = CreateFrame("Frame", nil, button)
    ring:SetPoint("TOPLEFT", 3, -3)
    ring:SetPoint("BOTTOMRIGHT", -3, 3)
    W.Border(ring, C.border, true)
    button.ring = ring

    -- Blizzard styling: the tracking border every other addon button uses,
    -- with the art sitting square inside it, as every other addon does.
    local overlay = button:CreateTexture(nil, "OVERLAY")
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetSize(53, 53)
    overlay:SetPoint("TOPLEFT")
    button.overlay = overlay



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
    pcall(M.ApplyStyle, M)

    -- Interface packs resize the minimap after login, so a position worked out
    -- once at startup can end up wrong a moment later.
    if Minimap.HookScript then
        pcall(Minimap.HookScript, Minimap, "OnSizeChanged", function() Reposition() end)
    end

    Reposition()
    return button
end

-- Square is the addon's own look; the Blizzard ring is what every other addon
-- button wears. The round crop loses the crown tips and ear points, which is
-- the accepted cost of fitting square art into a circle.
function M:ApplyStyle()
    if not button then return end
    local db = LunRollHistoryDB
    local blizzard = db and db.settings.minimapDefaultStyle

    local icon = button.icon
    icon:ClearAllPoints()

    -- Do not change the crop between styles. Narrowing the texture coordinates
    -- to a square makes the artwork render blank on a live client, which was
    -- originally blamed on the circular mask that happened to be present at
    -- the same time. It is the crop. The art is drawn one way in both styles
    -- and only its scale and border change.
    local coords = T.LOGO_COORDS
    icon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    icon:SetPoint("CENTER", 0, 0)

    if blizzard then
        button.backdrop:Hide()
        button.ring:Hide()
        button.overlay:Show()
        icon:SetSize(17 * T.LOGO_ASPECT, 17)
    else
        button.overlay:Hide()
        button.backdrop:Show()
        button.ring:Show()
        icon:SetSize(20 * T.LOGO_ASPECT, 20)
    end

    button.style = blizzard and "blizzard" or "square"
end

--------------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------------
-- Reported by /lrh diag: enough to tell a texture that failed to load from one
-- that is simply hidden behind something.
function M:IconState()
    if not button then return "no button" end
    local icon = button.icon
    local texture = (icon.GetTexture and icon:GetTexture()) or "?"
    return string.format("style=%s texture=%s shown=%s ring=%s border=%s",
        tostring(button.style), tostring(texture), tostring(button:IsShown()),
        tostring(button.ring and button.ring:IsShown()),
        tostring(button.overlay and button.overlay:IsShown()))
end

function M:Refresh()
    local db = LunRollHistoryDB
    if not db then return end
    if db.settings.minimapHide then
        if button then button:Hide() end
        return
    end
    Build()
    if button then
        -- Showing the button comes first and is not conditional on the styling
        -- working. A failure in here previously took the whole show path with
        -- it, so turning the button back on appeared to do nothing.
        button:Show()
        pcall(self.ApplyStyle, self)
        pcall(Reposition)
    end
end

function M:Toggle(hidden)
    if LunRollHistoryDB then LunRollHistoryDB.settings.minimapHide = hidden and true or false end
    self:Refresh()
end

local prevOnDBReady = ns.OnDBReady
function ns.OnDBReady()
    if prevOnDBReady then prevOnDBReady() end
    ns.Minimap:Refresh()
end
