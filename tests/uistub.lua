-- Frame stub with an explicit method whitelist. Anything the addon calls that
-- is NOT a real WoW widget method returns nil and therefore blows up loudly,
-- which is the point: invented API is the failure mode worth catching.
local M = {}
M.used = {}

local NOOP_METHODS = {
    -- Region / Frame
    "SetPoint","ClearAllPoints","SetAllPoints","SetFrameStrata","SetFrameLevel",
    "SetClipsChildren","SetMovable","SetResizable","SetClampedToScreen","StartMoving",
    "StopMovingOrSizing","EnableMouse","EnableMouseWheel","RegisterForDrag",
    "RegisterForClicks","RegisterEvent","UnregisterEvent","UnregisterAllEvents",
    "SetAlpha","GetAlpha","SetParent","Lower","SetToplevel","SetPropagateKeyboardInput",
    -- Texture
    "SetTexture","SetColorTexture","SetTexCoord","SetVertexColor","SetGradient",
    "SetDrawLayer","SetBlendMode","SetAtlas","SetTexCoord","GetChildren","SetDesaturated",
    -- FontString
    "SetTextColor","SetJustifyH","SetJustifyV","SetWordWrap","SetSpacing",
    "SetNonSpaceWrap","SetShadowColor","SetShadowOffset","SetMaxLines",
    -- Button
    "SetNormalTexture","SetHighlightTexture","SetPushedTexture","SetDisabledTexture",
    "SetEnabled","Enable","Disable","Click","GetFontString","SetNormalFontObject",
    "SetFontObject",
    -- EditBox
    "EnableKeyboard","SetMultiLine","SetMaxLetters","SetAutoFocus","SetFocus","ClearFocus",
    "HighlightText","SetCursorPosition","SetTextInsets","Insert","SetNumeric",
    -- ScrollFrame
    "SetScrollChild","GetScrollChild","SetVerticalScroll","UpdateScrollChildRect",
    "SetHorizontalScroll",
}

local function makeObject(kind, name, parent)
    local o = {
        __kind = kind, __name = name, __parent = parent,
        __scripts = {}, __w = 260, __h = 300, __shown = false, __text = "",
    }

    for _, method in ipairs(NOOP_METHODS) do
        o[method] = function() M.used[method] = true end
    end

    o.SetSize = function(self, w, h) self.__w, self.__h = w, h end
    o.SetWidth = function(self, w) self.__w = w end
    o.SetHeight = function(self, h) self.__h = h end
    o.GetWidth = function(self) return self.__w end
    o.GetHeight = function(self) return self.__h end
    o.GetLeft = function() return 0 end
    o.GetRight = function(self) return self.__w end
    o.GetTop = function(self) return self.__h end
    o.GetBottom = function() return 0 end
    o.GetEffectiveScale = function() return 1 end
    o.GetFrameLevel = function() return 1 end
    o.GetCenter = function() return 100, 100 end
    o.IsMouseOver = function() return false end
    o.Raise = function() end
    o.GetFont = function(self) return self.__font end
    o.HasFocus = function() return false end
    o.SetVertexColor = function() end
    -- Text metrics track the font size actually applied, so raising the font
    -- scale really does produce wider and taller strings the way it does in
    -- the client. Without this, layout tests cannot see a size change at all.
    o.GetStringWidth = function(self)
        local size = self.__fontSize or 12
        return #tostring(self.__text or "") * size * 0.5
    end
    o.GetStringHeight = function(self)
        local text = tostring(self.__text or "")
        local size = self.__fontSize or 12
        if text == "" then return size end
        local width = math.max(40, self.__w or 260)
        local lines = math.max(1, math.ceil((#text * size * 0.5) / width))
        return lines * (size + 2)
    end
    o.SetText = function(self, t) self.__text = t end
    o.GetText = function(self) return self.__text end
    o.SetFont = function(self, path, size, flags)
        self.__font, self.__fontSize = path, size or 12
        return true
    end
    o.Show = function(self)
        self.__shown = true
        local s = self.__scripts.OnShow
        if s then s(self) end
    end
    o.Hide = function(self) self.__shown = false end
    o.SetShown = function(self, v) if v then self:Show() else self:Hide() end end
    o.IsShown = function(self) return self.__shown end
    o.IsVisible = function(self) return self.__shown end
    o.SetScript = function(self, which, fn) self.__scripts[which] = fn end
    o.GetScript = function(self, which) return self.__scripts[which] end
    o.HookScript = function(self, which, fn) self.__scripts[which] = fn end
    o.Fire = function(self, which, ...)
        local s = self.__scripts[which]
        if s then return s(self, ...) end
    end
    o.CreateTexture = function(self) return makeObject("Texture", nil, self) end
    o.CreateFontString = function(self) return makeObject("FontString", nil, self) end
    o.GetVerticalScroll = function() return 0 end
    o.GetVerticalScrollRange = function() return 100 end
    o.GetParent = function(self) return self.__parent end
    o.GetName = function(self) return self.__name end
    return o
end
M.makeObject = makeObject

function M.install()
    _G.UIParent = makeObject("Frame", "UIParent")
    _G.UISpecialFrames = {}
    _G.SlashCmdList = {}
    _G.StaticPopupDialogs = {}
    _G.CANCEL = "Cancel"
    _G.StaticPopup_Show = function(which) M.lastPopup = which end
    _G.IsShiftKeyDown = function() return false end
    _G.InCombatLockdown = function() return M.inCombat or false end
    _G.GetCursorPosition = function() return 300, 300 end
    -- C_Timer.After runs the callback immediately, so retry loops resolve
    -- within the test instead of needing a real frame clock.
    _G.C_Timer = {
        After = function(_, fn) fn() end,
        NewTicker = function(_, fn) M.ticker = fn; return { Cancel = function() end } end,
    }
    _G.IsInInstance = function() return M.inInstance ~= false, "party" end
    -- Settable clock, so throttles and time windows can actually be exercised.
    _G.GetServerTime = function() return M.now or 1757000000 end
    _G.ITEM_ACCOUNTBOUND_UNTIL_EQUIP = "Warbound until equipped"
    _G.GetNumGroupMembers = function() return 5 end
    _G.GetLootSpecialization = function() return 268 end
    _G.GetSpecializationInfoByID = function(id) return id, "Brewmaster", "tank" end
    -- Two dungeons in the "current season", with icons and time limits.
    _G.C_ChallengeMode = {
        GetMapTable = function() return M.seasonMaps or { 501, 502 } end,
        GetMapUIInfo = function(mapID)
            local maps = {
                [501] = { "Ruby Life Pools", 501, 1920, 4062765, 4062766 },
                [502] = { "Throne of the Tides", 502, 1800, 4062767, 4062768 },
                [503] = { "The Nokhud Offensive", 503, 2400, 4062769, 4062770 },
                [504] = { "Algeth'ar Academy", 504, 1980, 4062771, 4062772 },
                [505] = { "Magisters Terrace", 505, 1800, 4062773, 4062774 },
                [506] = { "Windrunner Spire", 506, 2100, 4062775, 4062776 },
                [507] = { "Maisara Caverns", 507, 2040, 4062777, 4062778 },
                [508] = { "Nexus Point Xenas", 508, 1920, 4062779, 4062780 },
            }
            local m = maps[mapID]
            if not m then return nil end
            return m[1], m[2], m[3], m[4], m[5]
        end,
        -- Real clients often have nothing ready at the instant the event
        -- fires. completionDelay simulates that.
        GetCompletionInfo = function()
            if (M.completionDelay or 0) > 0 then
                M.completionDelay = M.completionDelay - 1
                return nil
            end
            if M.completionStruct then
                return {
                    mapChallengeModeID = M.completion.mapID,
                    level = M.completion.level,
                    time = M.completion.time,
                    onTime = M.completion.onTime,
                    keystoneUpgradeLevels = M.completion.upgrades,
                }
            end
            return M.completion.mapID, M.completion.level,
                   M.completion.time, M.completion.onTime, M.completion.upgrades
        end,
        GetActiveChallengeMapID = function() return M.activeMap end,
        GetActiveKeystoneInfo = function() return M.activeKeyLevel or 0 end,
    }
    M.completion = { mapID = 501, level = 12, time = 1500000, onTime = true, upgrades = 1 }
    -- Some clients return the completion data as a struct instead of a tuple.
    M.completionStruct = false
    _G.C_TooltipInfo = {
        GetHyperlink = function(link)
            if type(link) == "string" and link:find("WARBOUND", 1, true) then
                return { lines = { { leftText = "Warbound until equipped" } } }
            end
            return { lines = { { leftText = "Item Level 620" } } }
        end,
    }
    -- Encounter Journal: two dungeons, one with a loot table.
    _G.UnitClass = function() return "Monk", "MONK", 10 end
    _G.EJ_GetNumTiers = function() return 2 end
    _G.EJ_GetCurrentTier = function() return 2 end
    _G.EJ_SelectTier = function(t) M.ejTier = t end
    _G.EJ_GetInstanceByIndex = function(index, isRaid)
        if isRaid then return nil end
        local byTier = {
            [1] = { { 1001, "Old Dungeon" } },
            [2] = { { 1101, "Ruby Life Pools" }, { 1102, "Throne of the Tides" } },
        }
        local list = byTier[M.ejTier or 2]
        local e = list and list[index]
        if not e then return nil end
        return e[1], e[2]
    end
    _G.EJ_SelectInstance = function(id) M.ejInstance = id end
    _G.EJ_SetDifficulty = function(d) M.ejDifficulty = d end
    _G.EJ_SetLootFilter = function(classID, specID) M.ejFilter = { classID, specID } end
    _G.EJ_ResetLootFilter = function() M.ejFilter = nil end
    _G.EJ_GetNumLoot = function()
        if M.ejInstance == 1101 then return 3 end
        return 0
    end
    _G.C_EncounterJournal = {
        GetLootInfoByIndex = function(i)
            if M.journalNoNames then
                local ids = { 229876, 300001, 300002 }
                if not ids[i] then return nil end
                return { itemID = ids[i] }        -- id only, name not loaded
            end
            local items = {
                { itemID = 229876, name = "Chest Piece", link = "|cffa335ee|Hitem:229876|h[Chest Piece]|h|r", slot = "Chest" },
                { itemID = 300001, name = "Never Dropped Trinket", link = "|cffa335ee|Hitem:300001|h[Never Dropped Trinket]|h|r", slot = "Trinket" },
                { itemID = 300002, name = "Also Never Seen", link = "|cffa335ee|Hitem:300002|h[Also Never Seen]|h|r", slot = "Ring" },
            }
            return items[i]
        end,
    }
    _G.Minimap = makeObject("Frame", "Minimap")
    _G.GameTooltip = makeObject("Frame", "GameTooltip")
    _G.GameTooltip.SetOwner = function() end
    _G.GameTooltip.AddLine = function(self, text) M.tooltipLines = (M.tooltipLines or 0) + 1 end
    _G.GameFontNormal = makeObject("Font", "GameFontNormal")
    _G.GameFontNormal.GetFont = function() return "Fonts\\FRIZQT__.TTF", 12, "" end
    _G.LibStub = nil
    _G.ITEM_QUALITY_COLORS = {
        [0] = { r = 0.61568627, g = 0.61568627, b = 0.61568627, hex = "|cff9d9d9d" },
        [1] = { r = 1.00000000, g = 1.00000000, b = 1.00000000, hex = "|cffffffff" },
        [2] = { r = 0.11764706, g = 1.00000000, b = 0.00000000, hex = "|cff1eff00" },
        [3] = { r = 0.00000000, g = 0.43921570, b = 0.86666670, hex = "|cff0070dd" },
        [4] = { r = 0.63921570, g = 0.20784314, b = 0.93333334, hex = "|cffa335ee" },
        [5] = { r = 1.00000000, g = 0.50196080, b = 0.00000000, hex = "|cffff8000" },
    }
    -- classID 2 = Weapon, 4 = Armor, 7 = Tradegoods, 0 = Consumable
    _G.C_Item = {
        -- Item details are uncached until requested, which is the normal state
        -- the first time a loot table is opened.
        GetItemInfo = function(itemID)
            M.itemCache = M.itemCache or {}
            return M.itemCache[itemID]
        end,
        RequestLoadItemDataByID = function(itemID)
            M.requested = M.requested or {}
            M.requested[itemID] = true
        end,
        GetItemInfoInstant = function(itemID)
            local classes = { [229876] = 4, [12345] = 7, [99001] = 0, [99002] = 7, [77777] = 2 }
            return itemID, nil, nil, nil, nil, classes[itemID] or 15, nil
        end,
    }
    _G.RAID_CLASS_COLORS = {
        PALADIN = { r = 0.96, g = 0.55, b = 0.73 },
        ROGUE   = { r = 1.00, g = 0.96, b = 0.41 },
        PRIEST  = { r = 1.00, g = 1.00, b = 1.00 },
        MAGE    = { r = 0.25, g = 0.78, b = 0.92 },
    }
    _G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) M.lastMessage = msg end }

    local firstFrame
    _G.CreateFrame = function(kind, name, parent)
        local f = makeObject(kind or "Frame", name, parent)
        if name then _G[name] = f end
        if not firstFrame then firstFrame = f; _G.__eventFrame = f end
        return f
    end
end

return M
