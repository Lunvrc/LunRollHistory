-- LunRollHistory :: Theme.lua
-- Colors, fonts, and registries so changing the accent, the font, or the font
-- size re-skins every live element without rebuilding the window.

local ADDON, ns = ...

local T = {}
ns.Theme = T

T.LOGO = "Interface\\AddOns\\LunRollHistory\\media\\Logo"
-- The art is padded into a square canvas; these coords crop the side padding.
T.LOGO_COORDS = { 0.0547, 0.9453, 0, 1 }
T.LOGO_ASPECT = 0.8906

T.colors = {
    window     = { 0.043, 0.031, 0.063, 1 },
    sidebar    = { 0.067, 0.043, 0.086, 1 },
    headerBg   = { 0.055, 0.039, 0.075, 1 },
    footerBg   = { 0.055, 0.039, 0.075, 1 },
    panel      = { 0.094, 0.067, 0.129, 1 },
    panelHover = { 0.129, 0.094, 0.176, 1 },
    row        = { 0.078, 0.055, 0.106, 1 },
    rowAlt     = { 0.098, 0.071, 0.133, 1 },
    border     = { 0.169, 0.129, 0.216, 1 },
    borderSoft = { 0.118, 0.090, 0.153, 1 },
    text       = { 1.000, 1.000, 1.000 },
    textDim    = { 0.612, 0.576, 0.659 },
    textFaint  = { 0.435, 0.396, 0.475 },
    track      = { 0.180, 0.145, 0.220, 1 },
    toggleOff  = { 0.259, 0.231, 0.290, 1 },
    win        = { 0.400, 0.878, 0.510 },
    bad        = { 0.898, 0.443, 0.443 },
    pass       = { 0.478, 0.443, 0.522 },
}

T.accent = { 0.898, 0.522, 0.808 }
T.DEFAULT_ACCENT = { 0.898, 0.522, 0.808 }

-- Kept only as starting points for the picker, not as the whole choice.
T.accentPresets = {
    { key = "orchid", color = { 0.898, 0.522, 0.808 } },
    { key = "arcane", color = { 0.478, 0.612, 0.949 } },
    { key = "fel",    color = { 0.502, 0.851, 0.435 } },
    { key = "ember",  color = { 0.949, 0.573, 0.353 } },
    { key = "void",   color = { 0.678, 0.475, 0.949 } },
    { key = "frost",  color = { 0.451, 0.855, 0.878 } },
}

--------------------------------------------------------------------------------
-- Color maths
--------------------------------------------------------------------------------
function T.HSVtoRGB(h, s, v)
    h = h % 360
    local c = v * s
    local x = c * (1 - math.abs((h / 60) % 2 - 1))
    local m = v - c
    local r, g, b
    if     h <  60 then r, g, b = c, x, 0
    elseif h < 120 then r, g, b = x, c, 0
    elseif h < 180 then r, g, b = 0, c, x
    elseif h < 240 then r, g, b = 0, x, c
    elseif h < 300 then r, g, b = x, 0, c
    else                r, g, b = c, 0, x end
    return r + m, g + m, b + m
end

function T.RGBtoHSV(r, g, b)
    local maxc = math.max(r, g, b)
    local minc = math.min(r, g, b)
    local d = maxc - minc
    local h = 0
    if d > 0 then
        if maxc == r then h = 60 * (((g - b) / d) % 6)
        elseif maxc == g then h = 60 * (((b - r) / d) + 2)
        else h = 60 * (((r - g) / d) + 4) end
    end
    local s = (maxc > 0) and (d / maxc) or 0
    return h % 360, s, maxc
end

function T.RGBtoHex(r, g, b)
    return string.format("%02X%02X%02X",
        math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

function T.HexToRGB(hex)
    if type(hex) ~= "string" then return nil end
    hex = hex:gsub("#", ""):gsub("|", "")
    hex = hex:match("(%x%x%x%x%x%x)%s*$")
    if not hex then return nil end
    return tonumber(hex:sub(1, 2), 16) / 255,
           tonumber(hex:sub(3, 4), 16) / 255,
           tonumber(hex:sub(5, 6), 16) / 255
end

function T:AccentHex()
    return self.RGBtoHex(self.accent[1], self.accent[2], self.accent[3])
end

--------------------------------------------------------------------------------
-- Fonts
--------------------------------------------------------------------------------
local FALLBACK = "Fonts\\FRIZQT__.TTF"

-- Fonts shipped with the client. Locale packs are probed, never assumed.
local CLIENT_FONTS = {
    { name = "Friz Quadrata",  path = "Fonts\\FRIZQT__.TTF" },
    { name = "Arial Narrow",   path = "Fonts\\ARIALN.TTF" },
    { name = "Skurri",         path = "Fonts\\skurri.TTF" },
    { name = "Morpheus",       path = "Fonts\\MORPHEUS.TTF" },
    { name = "Nimrod",         path = "Fonts\\NIM_____.ttf" },
    { name = "2002",           path = "Fonts\\2002.TTF" },
    { name = "2002 Bold",      path = "Fonts\\2002B.TTF" },
    { name = "AR CrystalHei",  path = "Fonts\\ARHei.ttf" },
    { name = "AR KaiTi",       path = "Fonts\\ARKai_T.ttf" },
    { name = "Damage",         path = "Fonts\\K_Damage.TTF" },
    { name = "Pagetext",       path = "Fonts\\K_Pagetext.TTF" },
}

T.fontPath  = FALLBACK
T.fontScale = 1.0
T.fontList  = {}

-- Weak keys: a discarded FontString should not be kept alive by the registry.
local fontRegistry = setmetatable({}, { __mode = "k" })

local probeHost, probe

local function CanUse(path)
    if not probe or type(path) ~= "string" then return false end
    local ok = pcall(probe.SetFont, probe, path, 12, "")
    if not ok then return false end
    local got = probe:GetFont()
    if got == nil then return true end
    return tostring(got):lower() == path:lower()
end
T.CanUseFont = CanUse

-- The list other addons would call "global": client fonts that actually load,
-- plus anything registered with LibSharedMedia if the user happens to have it.
function T:BuildFontList()
    local list = {}
    for _, entry in ipairs(CLIENT_FONTS) do
        if CanUse(entry.path) then
            list[#list + 1] = { name = entry.name, path = entry.path }
        end
    end

    local ok, lsm = pcall(function()
        return LibStub and LibStub("LibSharedMedia-3.0", true)
    end)
    if ok and lsm then
        local okHash, hash = pcall(lsm.HashTable, lsm, "font")
        if okHash and type(hash) == "table" then
            local seen = {}
            for _, e in ipairs(list) do seen[e.path:lower()] = true end
            for name, path in pairs(hash) do
                if type(path) == "string" and not seen[path:lower()] and CanUse(path) then
                    list[#list + 1] = { name = name, path = path, shared = true }
                    seen[path:lower()] = true
                end
            end
        end
    end

    table.sort(list, function(a, b) return a.name < b.name end)
    self.fontList = list
    return list
end

function T:FontNameFor(path)
    for _, entry in ipairs(self.fontList or {}) do
        if entry.path == path then return entry.name end
    end
    return (type(path) == "string" and path:match("([^\\]+)$")) or "Default"
end

function T:Init()
    probeHost = probeHost or CreateFrame("Frame")
    probeHost:Hide()
    probe = probeHost:CreateFontString(nil, "BACKGROUND", "GameFontNormal")

    local ok, path = pcall(function() return (GameFontNormal:GetFont()) end)
    if ok and path then FALLBACK = path end
    self.fontPath = FALLBACK
    self:BuildFontList()
end

-- Registers the FontString and paints it. Everything text-shaped in the addon
-- goes through here, which is what makes live font changes possible.
function T:SetFont(fontString, size, weight, family)
    fontRegistry[fontString] = { size = size or 12, weight = weight, family = family }
    self:ApplyFontTo(fontString, fontRegistry[fontString])
end

function T:ApplyFontTo(fontString, info)
    local path = self.fontPath or FALLBACK
    local size = (info.size or 12) * (self.fontScale or 1)
    local flags = (info.weight == "outline") and "OUTLINE" or ""
    if not pcall(fontString.SetFont, fontString, path, size, flags) then
        pcall(fontString.SetFont, fontString, FALLBACK, size, flags)
    end
end

function T:ApplyFonts()
    for fontString, info in pairs(fontRegistry) do
        self:ApplyFontTo(fontString, info)
    end
    if self.onFontsChanged then self.onFontsChanged() end
end

function T:SetFontFamily(path)
    self.fontPath = path or FALLBACK
    if LunRollHistoryDB then LunRollHistoryDB.settings.fontPath = self.fontPath end
    self:ApplyFonts()
end

function T:SetFontScale(scale)
    if scale < 0.7 then scale = 0.7 elseif scale > 1.6 then scale = 1.6 end
    self.fontScale = scale
    if LunRollHistoryDB then LunRollHistoryDB.settings.fontScale = scale end
    self:ApplyFonts()
end

--------------------------------------------------------------------------------
-- Accent registry
--------------------------------------------------------------------------------
local tracked = setmetatable({}, { __mode = "k" })

-- kind: "texture" | "text" | "callback"
function T:Track(obj, kind, alpha)
    tracked[obj] = { kind = kind, alpha = alpha or 1 }
    self:ApplyTo(obj, tracked[obj])
    return obj
end

function T:ApplyTo(obj, info)
    local r, g, b = self.accent[1], self.accent[2], self.accent[3]
    if info.kind == "texture" then
        pcall(obj.SetColorTexture, obj, r, g, b, info.alpha)
    elseif info.kind == "text" then
        pcall(obj.SetTextColor, obj, r, g, b, info.alpha)
    elseif info.kind == "callback" then
        pcall(obj, r, g, b, info.alpha)
    end
end

function T:SetAccent(r, g, b, skipSave)
    self.accent[1], self.accent[2], self.accent[3] = r, g, b
    for obj, info in pairs(tracked) do
        self:ApplyTo(obj, info)
    end
    if not skipSave and LunRollHistoryDB then
        LunRollHistoryDB.settings.accentColor = { r, g, b }
    end
end

function T:SetAccentByKey(key)
    for _, preset in ipairs(self.accentPresets) do
        if preset.key == key then
            self:SetAccent(preset.color[1], preset.color[2], preset.color[3])
            return true
        end
    end
    return false
end

-- Reads whatever the saved variables hold, including the old preset-key format.
function T:LoadFromSettings(settings)
    if not settings then return end

    local c = settings.accentColor
    if type(c) == "table" and #c == 3 then
        self:SetAccent(c[1], c[2], c[3], true)
    elseif type(settings.accent) == "string" then
        self:SetAccentByKey(settings.accent)
    end

    if settings.fontPath and CanUse(settings.fontPath) then
        self.fontPath = settings.fontPath
    end
    if type(settings.fontScale) == "number" then
        self.fontScale = math.max(0.7, math.min(1.6, settings.fontScale))
    end
    self:ApplyFonts()
end

--------------------------------------------------------------------------------
-- Class colors for the roll list
--------------------------------------------------------------------------------
function T:ClassColor(class)
    if class and type(RAID_CLASS_COLORS) == "table" then
        local c = RAID_CLASS_COLORS[class]
        if c then return c.r, c.g, c.b end
    end
    local d = self.colors.textDim
    return d[1], d[2], d[3]
end
