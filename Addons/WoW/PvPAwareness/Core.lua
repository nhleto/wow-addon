PvPAwareness = {}
local addon = PvPAwareness

addon.version = "1.0.0"
addon.callbacks = {}

local defaults = {
    stealthAlerts = true,
    stealthSound = true,
    cooldownTracker = true,
    drTracker = true,
    radar = true,
    targetScan = true,
}

function addon:RegisterCombatCallback(name, fn)
    self.callbacks[name] = fn
end

-- Core event frame
local frame = CreateFrame("Frame", "PvPAwarenessCore", UIParent)
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        PvPAwarenessDB = PvPAwarenessDB or {}
        addon.db = PvPAwarenessDB
        for k, v in pairs(defaults) do
            if addon.db[k] == nil then addon.db[k] = v end
        end
        print("|cff18b818[PvP Awareness]|r v" .. addon.version .. " loaded — |cffa0a0a0/pvpa|r for options")

    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local info = {CombatLogGetCurrentEventInfo()}
        for _, fn in pairs(addon.callbacks) do
            fn(info)
        end

    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        if addon.OnZoneChange then addon:OnZoneChange() end
    end
end)

----------------------------------------------------------------
-- UI CONSTANTS — ElvUI-inspired dark flat style
----------------------------------------------------------------
local UI = {}
addon.UI = UI

UI.FONT           = "Fonts\\FRIZQT__.TTF"
UI.FONT_BOLD      = "Fonts\\MORPHEUS.TTF"
UI.BAR_TEXTURE    = "Interface\\TargetingFrame\\UI-StatusBar"
UI.FLAT_TEXTURE   = "Interface\\Buttons\\WHITE8x8"
UI.BG_COLOR       = {0.06, 0.06, 0.06, 0.92}
UI.BORDER_COLOR   = {0.12, 0.12, 0.12, 1.0}
UI.ACCENT_COLOR   = {0.18, 0.72, 0.18, 1.0}
UI.TEXT_DIM       = {0.55, 0.55, 0.55, 1.0}
UI.TEXT_NORMAL    = {0.85, 0.85, 0.85, 1.0}
UI.BORDER_SIZE    = 1
UI.INNER_PADDING  = 6
UI.BAR_HEIGHT     = 18
UI.HEADER_HEIGHT  = 16
UI.SPACING        = 2
UI.FONT_SIZE_SM   = 9
UI.FONT_SIZE_MD   = 11
UI.FONT_SIZE_LG   = 13
UI.FONT_SIZE_XL   = 26

----------------------------------------------------------------
-- Shared UI builders
----------------------------------------------------------------

-- Pixel-perfect 1px border (ElvUI style)
function UI:CreateBorder(f, r, g, b, a)
    r = r or UI.BORDER_COLOR[1]
    g = g or UI.BORDER_COLOR[2]
    b = b or UI.BORDER_COLOR[3]
    a = a or UI.BORDER_COLOR[4]

    if not f._borders then f._borders = {} end

    local function mkBorder(point1, rel, point2, x1, y1, x2, y2)
        local t = f:CreateTexture(nil, "BORDER")
        t:SetTexture(UI.FLAT_TEXTURE)
        t:SetVertexColor(r, g, b, a)
        t:SetPoint("TOPLEFT", f, point1, x1, y1)
        t:SetPoint("BOTTOMRIGHT", f, point2, x2, y2)
        table.insert(f._borders, t)
        return t
    end

    mkBorder("TOPLEFT",    f, "TOPRIGHT",     0,  1,  0,  0)  -- top
    mkBorder("BOTTOMLEFT", f, "BOTTOMRIGHT",  0,  0,  0, -1)  -- bottom
    mkBorder("TOPLEFT",    f, "BOTTOMLEFT",  -1,  1,  0, -1)  -- left
    mkBorder("TOPRIGHT",   f, "BOTTOMRIGHT",  0,  1,  1, -1)  -- right

    f.SetBorderColor = function(self, nr, ng, nb, na)
        for _, t in ipairs(self._borders) do
            t:SetVertexColor(nr, ng, nb, na or 1)
        end
    end
end

-- Outer shadow/glow (2px dark outline around a frame)
function UI:CreateShadow(f)
    local s = CreateFrame("Frame", nil, f)
    s:SetPoint("TOPLEFT", -2, 2)
    s:SetPoint("BOTTOMRIGHT", 2, -2)
    s:SetFrameLevel(math.max(0, f:GetFrameLevel() - 1))

    local bg = s:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(UI.FLAT_TEXTURE)
    bg:SetVertexColor(0, 0, 0, 0.6)
    f._shadow = s
end

-- Standard dark panel
function UI:CreatePanel(name, parent, width, height)
    local f = CreateFrame("Frame", name, parent or UIParent)
    f:SetSize(width, height)
    f:SetFrameStrata("MEDIUM")

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(UI.FLAT_TEXTURE)
    bg:SetVertexColor(unpack(UI.BG_COLOR))
    f._bg = bg

    UI:CreateBorder(f, 0.18, 0.18, 0.18, 1)
    UI:CreateShadow(f)

    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    return f
end

-- StatusBar with smooth texture and label/timer
function UI:CreateBar(parent, width, height)
    height = height or UI.BAR_HEIGHT
    width = width or 170

    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetSize(width, height)
    bar:SetStatusBarTexture(UI.BAR_TEXTURE)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)

    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(UI.FLAT_TEXTURE)
    bg:SetVertexColor(0.08, 0.08, 0.08, 0.9)
    bar._bg = bg

    bar.label = bar:CreateFontString(nil, "OVERLAY")
    bar.label:SetFont(UI.FONT, UI.FONT_SIZE_SM, "OUTLINE")
    bar.label:SetPoint("LEFT", 4, 0)
    bar.label:SetTextColor(unpack(UI.TEXT_NORMAL))

    bar.timer = bar:CreateFontString(nil, "OVERLAY")
    bar.timer:SetFont(UI.FONT, UI.FONT_SIZE_SM, "OUTLINE")
    bar.timer:SetPoint("RIGHT", -4, 0)
    bar.timer:SetTextColor(unpack(UI.TEXT_DIM))

    -- Smooth value animation
    bar._targetVal = 1
    bar._curVal = 1
    bar:SetScript("OnUpdate", function(self, dt)
        if math.abs(self._curVal - self._targetVal) > 0.001 then
            self._curVal = self._curVal + (self._targetVal - self._curVal) * math.min(1, dt * 12)
            self:SetValue(self._curVal)
        end
    end)

    function bar:SmoothSet(val)
        self._targetVal = val
    end

    function bar:SetColor(r, g, b, a)
        self:SetStatusBarColor(r, g, b, a or 0.85)
    end

    return bar
end

-- Section header text
function UI:CreateHeader(parent, text, yOffset)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(UI.FONT, UI.FONT_SIZE_MD, "OUTLINE")
    fs:SetText(text)
    fs:SetTextColor(unpack(UI.ACCENT_COLOR))
    if yOffset then
        fs:SetPoint("TOPLEFT", parent, "TOPLEFT", UI.INNER_PADDING, yOffset)
    end
    return fs
end

----------------------------------------------------------------
-- Center-screen flash alert (reworked with glow border)
----------------------------------------------------------------
local alertFrame = CreateFrame("Frame", "PvPAwarenessAlert", UIParent)
alertFrame:SetSize(420, 50)
alertFrame:SetPoint("CENTER", 0, 220)
alertFrame:SetFrameStrata("HIGH")
alertFrame:Hide()

local alertBg = alertFrame:CreateTexture(nil, "BACKGROUND")
alertBg:SetAllPoints()
alertBg:SetTexture(UI.FLAT_TEXTURE)
alertBg:SetVertexColor(0, 0, 0, 0.7)

UI:CreateBorder(alertFrame, 0.8, 0.15, 0.15, 1)

alertFrame.text = alertFrame:CreateFontString(nil, "OVERLAY")
alertFrame.text:SetFont(UI.FONT, UI.FONT_SIZE_XL, "OUTLINE")
alertFrame.text:SetPoint("CENTER", 0, 0)
alertFrame.text:SetShadowOffset(2, -2)
alertFrame.text:SetShadowColor(0, 0, 0, 0.8)

alertFrame.sub = alertFrame:CreateFontString(nil, "OVERLAY")
alertFrame.sub:SetFont(UI.FONT, UI.FONT_SIZE_MD, "OUTLINE")
alertFrame.sub:SetPoint("TOP", alertFrame.text, "BOTTOM", 0, -2)
alertFrame.sub:SetTextColor(0.7, 0.7, 0.7)

alertFrame.elapsed = 0
alertFrame.duration = 2.0

alertFrame:SetScript("OnUpdate", function(self, dt)
    self.elapsed = self.elapsed + dt
    if self.elapsed >= self.duration then
        self:Hide()
        return
    end
    -- Smooth fade in/out
    local alpha
    if self.elapsed < 0.12 then
        alpha = self.elapsed / 0.12
    elseif self.elapsed < self.duration - 0.5 then
        alpha = 1
    else
        alpha = (self.duration - self.elapsed) / 0.5
    end
    self:SetAlpha(alpha)

    -- Pulse border
    local pulse = 0.5 + 0.5 * math.sin(self.elapsed * 8)
    if self._borders then
        for _, t in ipairs(self._borders) do
            t:SetVertexColor(0.8 + 0.2 * pulse, 0.1, 0.1, 1)
        end
    end
end)

function addon:FlashAlert(text, r, g, b, duration, subtext)
    if not text then return end
    alertFrame.text:SetText(text)
    alertFrame.text:SetTextColor(r or 1, g or 0.2, b or 0.2, 1)
    alertFrame.sub:SetText(subtext or "")
    alertFrame.duration = duration or 2.0
    alertFrame.elapsed = 0
    alertFrame:SetAlpha(0)
    alertFrame:Show()
    -- Resize to fit text
    local w = math.max(300, alertFrame.text:GetStringWidth() + 60)
    alertFrame:SetWidth(w)
    if self.db and self.db.stealthSound then
        PlaySound(8959, "Master")
    end
end

----------------------------------------------------------------
-- Shared utilities
----------------------------------------------------------------
function addon:FormatTime(sec)
    if sec >= 60 then
        return string.format("%d:%02d", math.floor(sec / 60), math.floor(sec) % 60)
    elseif sec >= 10 then
        return string.format("%d", math.floor(sec))
    else
        return string.format("%.1f", sec)
    end
end

local CLASS_COLORS = {
    WARRIOR     = {0.78, 0.61, 0.43},
    PALADIN     = {0.96, 0.55, 0.73},
    HUNTER      = {0.67, 0.83, 0.45},
    ROGUE       = {1.00, 0.96, 0.41},
    PRIEST      = {1.00, 1.00, 1.00},
    SHAMAN      = {0.00, 0.44, 0.87},
    MAGE        = {0.25, 0.78, 0.92},
    WARLOCK     = {0.53, 0.53, 0.93},
    DRUID       = {1.00, 0.49, 0.04},
}

function addon:ClassColor(class)
    local c = CLASS_COLORS[class]
    if c then return c[1], c[2], c[3] end
    return 0.8, 0.8, 0.8
end

function addon:ClassColoredName(name, class)
    local r, g, b = self:ClassColor(class)
    return string.format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, name or "Unknown")
end

function addon:Dist2D(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    return math.sqrt(dx * dx + dy * dy)
end

function addon:IsEnemy(flags)
    if not flags then return false end
    return bit.band(flags, COMBATLOG_OBJECT_REACTION_HOSTILE) ~= 0
        and bit.band(flags, COMBATLOG_OBJECT_TYPE_PLAYER) ~= 0
end

----------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------
SLASH_PVPA1 = "/pvpa"
SLASH_PVPA2 = "/pvpawareness"
SlashCmdList["PVPA"] = function(msg)
    local cmd = strtrim(msg):lower()
    if cmd == "stealth" then
        addon.db.stealthAlerts = not addon.db.stealthAlerts
        print("|cff18b818[PvP Awareness]|r Stealth alerts: " .. (addon.db.stealthAlerts and "|cff18b818ON|r" or "|cffcc3333OFF|r"))
    elseif cmd == "cd" then
        addon.db.cooldownTracker = not addon.db.cooldownTracker
        print("|cff18b818[PvP Awareness]|r Cooldown tracker: " .. (addon.db.cooldownTracker and "|cff18b818ON|r" or "|cffcc3333OFF|r"))
    elseif cmd == "dr" then
        addon.db.drTracker = not addon.db.drTracker
        print("|cff18b818[PvP Awareness]|r DR tracker: " .. (addon.db.drTracker and "|cff18b818ON|r" or "|cffcc3333OFF|r"))
    elseif cmd == "radar" then
        addon.db.radar = not addon.db.radar
        print("|cff18b818[PvP Awareness]|r Combat radar: " .. (addon.db.radar and "|cff18b818ON|r" or "|cffcc3333OFF|r"))
    elseif cmd == "scan" then
        addon.db.targetScan = not addon.db.targetScan
        print("|cff18b818[PvP Awareness]|r Target scan: " .. (addon.db.targetScan and "|cff18b818ON|r" or "|cffcc3333OFF|r"))
    elseif cmd == "reset" then
        if addon.ResetCooldowns then addon:ResetCooldowns() end
        if addon.ResetDR then addon:ResetDR() end
        if addon.ResetRadar then addon:ResetRadar() end
        print("|cff18b818[PvP Awareness]|r Trackers reset.")
    else
        print("|cff18b818[PvP Awareness]|r Commands:")
        print("  |cffa0a0a0/pvpa stealth|r  — toggle stealth alerts")
        print("  |cffa0a0a0/pvpa cd|r       — toggle cooldown tracker")
        print("  |cffa0a0a0/pvpa dr|r       — toggle DR tracker")
        print("  |cffa0a0a0/pvpa radar|r    — toggle combat radar")
        print("  |cffa0a0a0/pvpa scan|r     — toggle target scanning")
        print("  |cffa0a0a0/pvpa reset|r    — clear all tracked data")
    end
end
