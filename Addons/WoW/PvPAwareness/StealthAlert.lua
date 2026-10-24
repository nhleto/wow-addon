local addon = PvPAwareness
local UI = addon.UI

local stealthedUnits = {} -- guid → { name, class, spell, time }

local STEALTH_LABEL = {
    [1784]  = "Stealth",  [1785] = "Stealth", [1786] = "Stealth", [1787] = "Stealth",
    [1856]  = "Vanish",   [1857] = "Vanish",
    [5215]  = "Prowl",    [6783] = "Prowl",   [9913] = "Prowl",
    [20580] = "Shadowmeld",
}

local STEALTH_TIMEOUT = 30

----------------------------------------------------------------
-- Stealth tracking bar — persistent indicator below the alert
----------------------------------------------------------------
local bar = UI:CreatePanel("PvPAwarenessStealthBar", UIParent, 260, 32)
bar:SetPoint("TOP", UIParent, "TOP", 0, -100)
bar:SetFrameStrata("HIGH")
bar:Hide()

-- Accent stripe on left edge
local accent = bar:CreateTexture(nil, "ARTWORK")
accent:SetTexture(UI.FLAT_TEXTURE)
accent:SetVertexColor(0.9, 0.15, 0.15, 1)
accent:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
accent:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
accent:SetWidth(3)

-- Icon area
local iconBg = bar:CreateTexture(nil, "ARTWORK")
iconBg:SetTexture(UI.FLAT_TEXTURE)
iconBg:SetVertexColor(0.12, 0.12, 0.12, 1)
iconBg:SetPoint("TOPLEFT", accent, "TOPRIGHT", 4, -4)
iconBg:SetSize(24, 24)

local iconText = bar:CreateFontString(nil, "OVERLAY")
iconText:SetFont(UI.FONT, 14, "OUTLINE")
iconText:SetPoint("CENTER", iconBg)
iconText:SetText("?")
iconText:SetTextColor(0.9, 0.15, 0.15)

local mainText = bar:CreateFontString(nil, "OVERLAY")
mainText:SetFont(UI.FONT, UI.FONT_SIZE_LG, "OUTLINE")
mainText:SetPoint("LEFT", iconBg, "RIGHT", 6, 1)
mainText:SetTextColor(0.95, 0.3, 0.3)

local subText = bar:CreateFontString(nil, "OVERLAY")
subText:SetFont(UI.FONT, UI.FONT_SIZE_SM, "OUTLINE")
subText:SetPoint("TOPLEFT", mainText, "BOTTOMLEFT", 0, -1)
subText:SetTextColor(unpack(UI.TEXT_DIM))

----------------------------------------------------------------
-- Row pool for multi-stealth list below the header bar
----------------------------------------------------------------
local rowPool = {}

local function GetStealthRow(parent, index)
    if rowPool[index] then
        rowPool[index]:Show()
        return rowPool[index]
    end

    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(250, 20)

    local rowBg = row:CreateTexture(nil, "BACKGROUND")
    rowBg:SetAllPoints()
    rowBg:SetTexture(UI.FLAT_TEXTURE)
    rowBg:SetVertexColor(0.06, 0.06, 0.06, 0.92)

    local rowAccent = row:CreateTexture(nil, "ARTWORK")
    rowAccent:SetTexture(UI.FLAT_TEXTURE)
    rowAccent:SetPoint("TOPLEFT")
    rowAccent:SetPoint("BOTTOMLEFT")
    rowAccent:SetWidth(2)
    row._accent = rowAccent

    row.nameText = row:CreateFontString(nil, "OVERLAY")
    row.nameText:SetFont(UI.FONT, UI.FONT_SIZE_SM, "OUTLINE")
    row.nameText:SetPoint("LEFT", 8, 0)

    row.spellText = row:CreateFontString(nil, "OVERLAY")
    row.spellText:SetFont(UI.FONT, UI.FONT_SIZE_SM, "OUTLINE")
    row.spellText:SetPoint("RIGHT", -40, 0)
    row.spellText:SetTextColor(unpack(UI.TEXT_DIM))

    row.ageText = row:CreateFontString(nil, "OVERLAY")
    row.ageText:SetFont(UI.FONT, UI.FONT_SIZE_SM, "OUTLINE")
    row.ageText:SetPoint("RIGHT", -6, 0)
    row.ageText:SetTextColor(0.7, 0.7, 0.7)

    rowPool[index] = row
    return row
end

local function HideAllRows()
    for _, row in ipairs(rowPool) do
        row:Hide()
    end
end

----------------------------------------------------------------
-- Timer: update stealth tracking display
----------------------------------------------------------------
local timerFrame = CreateFrame("Frame")
timerFrame.elapsed = 0
timerFrame:SetScript("OnUpdate", function(self, dt)
    self.elapsed = self.elapsed + dt
    if self.elapsed < 0.15 then return end
    self.elapsed = 0

    if not addon.db or not addon.db.stealthAlerts then
        bar:Hide()
        HideAllRows()
        return
    end

    local now = GetTime()

    -- Expire old entries
    for guid, info in pairs(stealthedUnits) do
        if now - info.time > STEALTH_TIMEOUT then
            stealthedUnits[guid] = nil
        end
    end

    -- Count and collect
    local sorted = {}
    for guid, info in pairs(stealthedUnits) do
        table.insert(sorted, {guid = guid, info = info, age = now - info.time})
    end

    if #sorted == 0 then
        bar:Hide()
        HideAllRows()
        return
    end

    table.sort(sorted, function(a, b) return a.age < b.age end)

    -- Header bar
    if #sorted == 1 then
        local e = sorted[1]
        mainText:SetText(addon:ClassColoredName(e.info.name, e.info.class))
        subText:SetText(e.info.spell .. " — " .. math.floor(e.age) .. "s ago")
        iconText:SetText(string.sub(e.info.class or "?", 1, 1))
        local r, g, b = addon:ClassColor(e.info.class)
        iconText:SetTextColor(r, g, b)
        accent:SetVertexColor(r, g, b, 1)
        bar:SetBorderColor(r * 0.4, g * 0.4, b * 0.4, 1)
    else
        mainText:SetText("|cffcc3333" .. #sorted .. " stealthed|r")
        subText:SetText("Nearby enemies hidden")
        iconText:SetText(tostring(#sorted))
        iconText:SetTextColor(0.9, 0.15, 0.15)
        accent:SetVertexColor(0.9, 0.15, 0.15, 1)
        bar:SetBorderColor(0.35, 0.06, 0.06, 1)
    end

    bar:Show()

    -- Detail rows below bar
    HideAllRows()
    if #sorted > 1 then
        for i, e in ipairs(sorted) do
            local row = GetStealthRow(bar, i)
            row:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -(i - 1) * 21 - 2)
            row:SetWidth(bar:GetWidth())
            row.nameText:SetText(addon:ClassColoredName(e.info.name, e.info.class))
            row.spellText:SetText(e.info.spell)
            row.ageText:SetText(math.floor(e.age) .. "s")
            local r, g, b = addon:ClassColor(e.info.class)
            row._accent:SetVertexColor(r, g, b, 1)
        end
    end

    -- Pulse accent bar on fresh alerts (< 3s)
    if sorted[1].age < 3 then
        local pulse = 0.6 + 0.4 * math.abs(math.sin(now * 4))
        accent:SetAlpha(pulse)
    else
        accent:SetAlpha(1)
    end
end)

----------------------------------------------------------------
-- Combat log handler
----------------------------------------------------------------
addon:RegisterCombatCallback("stealth", function(info)
    if not addon.db or not addon.db.stealthAlerts then return end

    local subevent   = info[2]
    local sourceGUID = info[4]
    local sourceName = info[5]
    local sourceFlags = info[6]
    local destGUID   = info[8]
    local spellID    = info[12]

    -- Enemy enters stealth
    if (subevent == "SPELL_CAST_SUCCESS" or subevent == "SPELL_AURA_APPLIED") then
        if addon.STEALTH_SPELLS[spellID] and addon:IsEnemy(sourceFlags) then
            local _, class = GetPlayerInfoByGUID(sourceGUID)
            local label = STEALTH_LABEL[spellID] or "Stealth"

            stealthedUnits[sourceGUID] = {
                name = sourceName or "Unknown",
                class = class or "ROGUE",
                spell = label,
                time = GetTime(),
            }

            local colored = addon:ClassColoredName(sourceName, class)
            addon:FlashAlert(label:upper(), 1, 0.2, 0.2, 2.5, colored .. " went invisible")
        end
    end

    -- Enemy breaks stealth via a known stealth-breaking ability or direct damage
    if stealthedUnits[sourceGUID] then
        local isBreak = false
        if subevent == "SWING_DAMAGE" then
            isBreak = true
        elseif subevent == "SPELL_CAST_SUCCESS" and spellID and addon.STEALTH_BREAK_SPELLS[spellID] then
            isBreak = true
        elseif subevent == "SPELL_DAMAGE" and spellID and addon.STEALTH_BREAK_SPELLS[spellID] then
            isBreak = true
        end
        if isBreak then
            local s = stealthedUnits[sourceGUID]
            local colored = addon:ClassColoredName(s.name, s.class)
            addon:FlashAlert("REVEALED", 1, 0.8, 0.2, 1.5, colored .. " broke " .. s.spell)
            stealthedUnits[sourceGUID] = nil
        end
    end

    -- Stealth aura removed
    if subevent == "SPELL_AURA_REMOVED" and addon.STEALTH_SPELLS[spellID] then
        stealthedUnits[sourceGUID] = nil
        stealthedUnits[destGUID] = nil
    end
end)
