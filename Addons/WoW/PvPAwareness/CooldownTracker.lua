local addon = PvPAwareness
local UI = addon.UI

-- enemyCooldowns[guid][spellID] = { expires, data }
local enemyCooldowns = {}
-- enemyInfo[guid] = { name, class }
-- Shared via addon._trackedEnemies so StateEncoder can read it
local enemyInfo = {}
addon._trackedEnemies = enemyInfo

local MAX_ENEMIES = 6
local BAR_WIDTH = 185

----------------------------------------------------------------
-- Category colors — muted tones that read well on dark bg
----------------------------------------------------------------
local CAT_COLORS = {
    interrupt  = {0.90, 0.25, 0.25},  -- red
    cc         = {0.95, 0.55, 0.10},  -- orange
    defensive  = {0.25, 0.60, 0.95},  -- blue
    offensive  = {0.85, 0.20, 0.55},  -- magenta
    mobility   = {0.20, 0.85, 0.35},  -- green
    trinket    = {0.90, 0.85, 0.15},  -- yellow
}

----------------------------------------------------------------
-- Main tracker panel
----------------------------------------------------------------
local tracker = UI:CreatePanel("PvPAwarenessCDTracker", UIParent, BAR_WIDTH + UI.INNER_PADDING * 2, 200)
tracker:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -30, -220)
tracker:Hide()

local titleText = UI:CreateHeader(tracker, "COOLDOWNS", -(UI.INNER_PADDING - 1))
titleText:SetFont(UI.FONT, UI.FONT_SIZE_SM, "OUTLINE")
titleText:SetTextColor(unpack(UI.TEXT_DIM))

-- Thin accent line under title
local titleLine = tracker:CreateTexture(nil, "ARTWORK")
titleLine:SetTexture(UI.FLAT_TEXTURE)
titleLine:SetVertexColor(unpack(UI.ACCENT_COLOR))
titleLine:SetHeight(1)
titleLine:SetPoint("TOPLEFT", tracker, "TOPLEFT", UI.INNER_PADDING, -(UI.HEADER_HEIGHT + UI.INNER_PADDING))
titleLine:SetPoint("TOPRIGHT", tracker, "TOPRIGHT", -UI.INNER_PADDING, -(UI.HEADER_HEIGHT + UI.INNER_PADDING))

----------------------------------------------------------------
-- Bar pool
----------------------------------------------------------------
local barPool = {}
local barPoolIdx = 0

local function ResetBarPool()
    for _, b in ipairs(barPool) do
        b:Hide()
        b.inUse = false
    end
    barPoolIdx = 0
end

local function AcquireBar()
    barPoolIdx = barPoolIdx + 1
    if barPool[barPoolIdx] then
        barPool[barPoolIdx].inUse = true
        barPool[barPoolIdx]:Show()
        return barPool[barPoolIdx]
    end

    local b = UI:CreateBar(tracker, BAR_WIDTH, UI.BAR_HEIGHT)
    b.inUse = true
    barPool[barPoolIdx] = b
    return b
end

-- Header labels (enemy names)
local headerPool = {}
local headerPoolIdx = 0

local function ResetHeaderPool()
    for _, h in ipairs(headerPool) do h:Hide() end
    headerPoolIdx = 0
end

local function AcquireHeader()
    headerPoolIdx = headerPoolIdx + 1
    if headerPool[headerPoolIdx] then
        headerPool[headerPoolIdx]:Show()
        return headerPool[headerPoolIdx]
    end

    local f = CreateFrame("Frame", nil, tracker)
    f:SetSize(BAR_WIDTH, 14)

    -- Class-colored left accent dot
    f.dot = f:CreateTexture(nil, "ARTWORK")
    f.dot:SetTexture(UI.FLAT_TEXTURE)
    f.dot:SetSize(8, 8)
    f.dot:SetPoint("LEFT", 0, 0)

    f.text = f:CreateFontString(nil, "OVERLAY")
    f.text:SetFont(UI.FONT, UI.FONT_SIZE_SM, "OUTLINE")
    f.text:SetPoint("LEFT", f.dot, "RIGHT", 4, 0)
    f.text:SetTextColor(unpack(UI.TEXT_NORMAL))

    headerPool[headerPoolIdx] = f
    return f
end

----------------------------------------------------------------
-- Update display
----------------------------------------------------------------
local updateFrame = CreateFrame("Frame")
updateFrame.elapsed = 0
updateFrame:SetScript("OnUpdate", function(self, dt)
    self.elapsed = self.elapsed + dt
    if self.elapsed < 0.05 then return end
    self.elapsed = 0

    if not addon.db or not addon.db.cooldownTracker then
        tracker:Hide()
        return
    end

    local now = GetTime()
    local hasAnything = false

    ResetBarPool()
    ResetHeaderPool()

    -- Collect active cooldowns per enemy
    local entries = {}
    for guid, cds in pairs(enemyCooldowns) do
        local info = enemyInfo[guid] or {name = "Unknown", class = "WARRIOR"}
        local activeCDs = {}

        for spellID, cd in pairs(cds) do
            if cd.expires > now then
                table.insert(activeCDs, {
                    spellID = spellID,
                    remaining = cd.expires - now,
                    total = cd.data.cd,
                    data = cd.data,
                })
                hasAnything = true
            else
                cds[spellID] = nil
            end
        end

        if #activeCDs > 0 then
            table.sort(activeCDs, function(a, b) return a.remaining < b.remaining end)
            table.insert(entries, {
                guid = guid,
                name = info.name,
                class = info.class,
                cooldowns = activeCDs,
            })
        end
    end

    if not hasAnything then
        tracker:Hide()
        return
    end

    table.sort(entries, function(a, b)
        if a.class == b.class then return a.name < b.name end
        return a.class < b.class
    end)

    -- Render
    local yOff = -(UI.HEADER_HEIGHT + UI.INNER_PADDING + 4)

    for i, entry in ipairs(entries) do
        if i > MAX_ENEMIES then break end

        -- Enemy name header
        local header = AcquireHeader()
        header:SetParent(tracker)
        header:SetPoint("TOPLEFT", tracker, "TOPLEFT", UI.INNER_PADDING, yOff)
        header.text:SetText(addon:ClassColoredName(entry.name, entry.class))
        local cr, cg, cb = addon:ClassColor(entry.class)
        header.dot:SetVertexColor(cr, cg, cb, 1)

        yOff = yOff - 16

        for _, cd in ipairs(entry.cooldowns) do
            local b = AcquireBar()
            b:SetParent(tracker)
            b:SetPoint("TOPLEFT", tracker, "TOPLEFT", UI.INNER_PADDING, yOff)

            local pct = cd.remaining / cd.total
            b:SmoothSet(pct)

            local color = CAT_COLORS[cd.data.cat] or {0.4, 0.4, 0.4}
            b:SetColor(color[1] * 0.7, color[2] * 0.7, color[3] * 0.7)

            b.label:SetText(cd.data.name)

            -- Color time text: red when almost ready, dim otherwise
            if cd.remaining < 3 then
                b.timer:SetTextColor(1, 0.3, 0.3)
            elseif cd.remaining < 10 then
                b.timer:SetTextColor(0.95, 0.75, 0.25)
            else
                b.timer:SetTextColor(unpack(UI.TEXT_DIM))
            end
            b.timer:SetText(addon:FormatTime(cd.remaining))

            yOff = yOff - (UI.BAR_HEIGHT + UI.SPACING)
        end

        yOff = yOff - 4 -- gap between enemies
    end

    tracker:SetHeight(math.abs(yOff) + UI.INNER_PADDING)
    tracker:Show()
end)

----------------------------------------------------------------
-- Combat log: track enemy spell casts
----------------------------------------------------------------
addon:RegisterCombatCallback("cooldowns", function(info)
    if not addon.db or not addon.db.cooldownTracker then return end

    local subevent   = info[2]
    local sourceGUID = info[4]
    local sourceName = info[5]
    local sourceFlags = info[6]
    local spellID    = info[12]

    if subevent ~= "SPELL_CAST_SUCCESS" then return end
    if not addon:IsEnemy(sourceFlags) then return end
    if not spellID then return end

    local data = addon.PVP_COOLDOWNS[spellID]
    if not data then return end

    if sourceName and sourceGUID then
        local _, class = GetPlayerInfoByGUID(sourceGUID)
        enemyInfo[sourceGUID] = {name = sourceName, class = class or "WARRIOR"}
    end

    if not enemyCooldowns[sourceGUID] then
        enemyCooldowns[sourceGUID] = {}
    end
    enemyCooldowns[sourceGUID][spellID] = {
        expires = GetTime() + data.cd,
        data = data,
    }
end)

----------------------------------------------------------------
-- Reset / zone change
----------------------------------------------------------------
function addon:ResetCooldowns()
    wipe(enemyCooldowns)
    wipe(enemyInfo)
    ResetBarPool()
    ResetHeaderPool()
    tracker:Hide()
end

local prevOnZoneChange = addon.OnZoneChange
function addon:OnZoneChange()
    if prevOnZoneChange then prevOnZoneChange(self) end
    if addon.ResetCooldowns then addon:ResetCooldowns() end
    if addon.ResetDR then addon:ResetDR() end
end
