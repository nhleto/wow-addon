local addon = PvPAwareness
local UI = addon.UI

----------------------------------------------------------------
-- Config
----------------------------------------------------------------
local DOT_SIZE       = 8
local DOT_FADE_TIME  = 30
local MAX_DOTS       = 16
local STALE_ALPHA    = 0.15
local FRESH_ALPHA    = 0.95

-- Minimap yard radius per outdoor zoom level (Classic Era fallback)
-- Used only when C_Minimap.GetViewRadius() is unavailable
local MINIMAP_YARD_SCALES = {
    [0] = 233,
    [1] = 200,
    [2] = 167,
    [3] = 133,
    [4] = 100,
    [5] = 67,
}
local INDOOR_YARD_SCALE = 50

-- Cached yard radius — refreshed on zoom change or periodically
local cachedYardRadius = 133
local hasViewRadiusAPI = (C_Minimap and C_Minimap.GetViewRadius) ~= nil

----------------------------------------------------------------
-- State
----------------------------------------------------------------
-- contacts[guid] = { name, class, x, y, time, isStealthed }
local contacts = {}

----------------------------------------------------------------
-- Dot pool — parented to Minimap
----------------------------------------------------------------
local dotPool = {}

local function GetDot(index)
    if dotPool[index] then
        dotPool[index]:Show()
        return dotPool[index]
    end

    local dot = CreateFrame("Frame", nil, Minimap)
    dot:SetSize(DOT_SIZE, DOT_SIZE)
    dot:SetFrameStrata("HIGH")
    dot:SetFrameLevel(Minimap:GetFrameLevel() + 10)

    -- Core dot texture
    dot.tex = dot:CreateTexture(nil, "OVERLAY")
    dot.tex:SetTexture(UI.FLAT_TEXTURE)
    dot.tex:SetAllPoints()

    -- Soft glow behind the dot
    dot.glow = dot:CreateTexture(nil, "ARTWORK")
    dot.glow:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    dot.glow:SetSize(DOT_SIZE + 10, DOT_SIZE + 10)
    dot.glow:SetPoint("CENTER")
    dot.glow:SetBlendMode("ADD")

    -- 1px dark outline for readability on the minimap
    dot.outline = dot:CreateTexture(nil, "BORDER")
    dot.outline:SetTexture(UI.FLAT_TEXTURE)
    dot.outline:SetPoint("TOPLEFT", -1, 1)
    dot.outline:SetPoint("BOTTOMRIGHT", 1, -1)
    dot.outline:SetVertexColor(0, 0, 0, 0.9)

    -- Name label on hover
    dot.nameText = dot:CreateFontString(nil, "OVERLAY")
    dot.nameText:SetFont(UI.FONT, 9, "OUTLINE")
    dot.nameText:SetPoint("TOP", dot, "BOTTOM", 0, -3)
    dot.nameText:SetShadowOffset(1, -1)
    dot.nameText:SetShadowColor(0, 0, 0, 1)
    dot.nameText:Hide()

    -- Age label (small text showing seconds since last seen)
    dot.ageText = dot:CreateFontString(nil, "OVERLAY")
    dot.ageText:SetFont(UI.FONT, 7, "OUTLINE")
    dot.ageText:SetPoint("BOTTOM", dot, "TOP", 0, 1)
    dot.ageText:SetTextColor(0.6, 0.6, 0.6, 0.8)

    dot:EnableMouse(true)
    dot:SetScript("OnEnter", function(self)
        self.nameText:Show()
        self.ageText:Show()
    end)
    dot:SetScript("OnLeave", function(self)
        self.nameText:Hide()
        -- Keep age visible for stealthed units
        if not self._isStealthed then
            self.ageText:Hide()
        end
    end)

    dotPool[index] = dot
    return dot
end

local function HideAllDots()
    for _, dot in ipairs(dotPool) do
        dot:Hide()
    end
end

----------------------------------------------------------------
-- Minimap geometry helpers
----------------------------------------------------------------
local function RefreshYardRadius()
    if hasViewRadiusAPI then
        local r = C_Minimap.GetViewRadius()
        if r and r > 0 then
            cachedYardRadius = r
            return
        end
    end
    -- Classic Era fallback: check indoor vs outdoor zoom
    local insideZoom = tonumber(GetCVar("minimapInsideZoom")) or 0
    local outsideZoom = tonumber(GetCVar("minimapZoom")) or 0
    local _, inInstance = IsInInstance()
    local isIndoors = (inInstance ~= "none") or (insideZoom > 0 and outsideZoom == 0)
    if isIndoors then
        cachedYardRadius = INDOOR_YARD_SCALE
    else
        local zoom = Minimap:GetZoom()
        cachedYardRadius = MINIMAP_YARD_SCALES[zoom] or 133
    end
end

local function MinimapRotates()
    local val = GetCVar("rotateMinimap")
    return val == "1"
end

-- Listen for zoom changes to update cached radius
local zoomFrame = CreateFrame("Frame")
zoomFrame:RegisterEvent("MINIMAP_UPDATE_ZOOM")
zoomFrame:RegisterEvent("PLAYER_LOGIN")
zoomFrame:SetScript("OnEvent", function()
    RefreshYardRadius()
end)

----------------------------------------------------------------
-- Contact count indicator (subtle text on minimap border)
----------------------------------------------------------------
local countFrame = CreateFrame("Frame", nil, Minimap)
countFrame:SetSize(40, 16)
countFrame:SetPoint("BOTTOMLEFT", Minimap, "BOTTOMLEFT", 4, 4)
countFrame:SetFrameStrata("HIGH")
countFrame:SetFrameLevel(Minimap:GetFrameLevel() + 15)
countFrame:Hide()

local countBg = countFrame:CreateTexture(nil, "BACKGROUND")
countBg:SetAllPoints()
countBg:SetTexture(UI.FLAT_TEXTURE)
countBg:SetVertexColor(0, 0, 0, 0.6)

local countText = countFrame:CreateFontString(nil, "OVERLAY")
countText:SetFont(UI.FONT, 9, "OUTLINE")
countText:SetPoint("CENTER")
countText:SetTextColor(0.9, 0.35, 0.35, 1)

----------------------------------------------------------------
-- Update loop — position dots on minimap every frame
----------------------------------------------------------------
local updateFrame = CreateFrame("Frame")
updateFrame.elapsed = 0
updateFrame:SetScript("OnUpdate", function(self, dt)
    self.elapsed = self.elapsed + dt
    if self.elapsed < 0.05 then return end
    self.elapsed = 0

    if not addon.db or not addon.db.radar then
        HideAllDots()
        countFrame:Hide()
        return
    end

    local now = GetTime()
    local px, py = UnitPosition("player")
    local facing = GetPlayerFacing()

    -- Merge contacts from TargetScan module
    if addon._radarContacts then
        for guid, c in pairs(addon._radarContacts) do
            local existing = contacts[guid]
            if existing then
                existing.name = c.name or existing.name
                existing.class = c.class or existing.class
                existing.time = c.time
                if c.x then
                    existing.x = c.x
                    existing.y = c.y
                end
            else
                contacts[guid] = c
            end
        end
        wipe(addon._radarContacts)
    end

    -- Expire old contacts
    for guid, c in pairs(contacts) do
        if now - c.time > DOT_FADE_TIME then
            contacts[guid] = nil
        end
    end

    -- Count and sort
    local sorted = {}
    for guid, c in pairs(contacts) do
        if c.x and c.y then
            table.insert(sorted, {guid = guid, c = c, age = now - c.time})
        end
    end

    if #sorted == 0 or not px then
        HideAllDots()
        countFrame:Hide()
        return
    end

    table.sort(sorted, function(a, b) return a.age < b.age end)

    -- Show contact count
    countText:SetText(#sorted)
    countFrame:Show()

    HideAllDots()

    local mmRadius = Minimap:GetWidth() / 2
    local yardRadius = cachedYardRadius
    local rotates = MinimapRotates()

    for i, entry in ipairs(sorted) do
        if i > MAX_DOTS then break end

        local c = entry.c
        local dx = c.x - px
        local dy = c.y - py

        -- When rotateMinimap is ON in Classic Era, the Minimap frame
        -- rotates its children automatically. We need to supply
        -- north-up world coordinates and let the frame handle rotation.
        --
        -- When rotateMinimap is OFF (north-up), we also supply
        -- north-up coordinates. Either way: north-up is correct.
        --
        -- Note: In retail (Shadowlands+), the Minimap does NOT rotate
        -- its children — HereBeDragons manually rotates pin coords.
        -- But in Classic Era (our target), children ARE auto-rotated,
        -- so we always use raw north-up world-space offsets.

        -- Convert yards to minimap pixels
        local scale = mmRadius / yardRadius
        local dotX = dx * scale
        local dotY = dy * scale

        -- Clamp to minimap circle (with margin for dot size)
        local edgeMargin = DOT_SIZE / 2 + 2
        local dist = math.sqrt(dotX * dotX + dotY * dotY)
        local clamped = false
        if dist > mmRadius - edgeMargin then
            local clampScale = (mmRadius - edgeMargin) / dist
            dotX = dotX * clampScale
            dotY = dotY * clampScale
            clamped = true
        end

        local dot = GetDot(i)
        dot:ClearAllPoints()
        dot:SetPoint("CENTER", Minimap, "CENTER", dotX, dotY)

        -- Class-colored dot
        local cr, cg, cb = addon:ClassColor(c.class)
        dot.tex:SetVertexColor(cr, cg, cb, 1)
        dot.glow:SetVertexColor(cr, cg, cb, 0.25)

        -- Stealthed: red pulsing dot, slightly larger
        dot._isStealthed = c.isStealthed
        dot.outline:ClearAllPoints()
        if c.isStealthed then
            local pulse = 0.7 + 0.3 * math.sin(now * 5)
            dot.tex:SetVertexColor(1, 0.15, 0.15, pulse)
            dot.glow:SetVertexColor(1, 0.05, 0.05, 0.4)
            dot:SetSize(DOT_SIZE + 3, DOT_SIZE + 3)
            dot.outline:SetPoint("TOPLEFT", -2, 2)
            dot.outline:SetPoint("BOTTOMRIGHT", 2, -2)
            dot.ageText:Show()
        else
            dot:SetSize(DOT_SIZE, DOT_SIZE)
            dot.outline:SetPoint("TOPLEFT", -1, 1)
            dot.outline:SetPoint("BOTTOMRIGHT", 1, -1)
            dot.ageText:Hide()
        end

        -- Fade by age
        local agePct = entry.age / DOT_FADE_TIME
        local alpha = FRESH_ALPHA - (FRESH_ALPHA - STALE_ALPHA) * agePct
        dot:SetAlpha(alpha)

        -- Edge marker: if clamped, rotate the dot texture 45° (diamond)
        -- to indicate "enemy is beyond minimap range in this direction"
        if clamped then
            dot.tex:SetRotation(math.rad(45))
        else
            dot.tex:SetRotation(0)
        end

        -- Labels
        dot.nameText:SetText(addon:ClassColoredName(c.name, c.class))
        dot.ageText:SetText(math.floor(entry.age) .. "s")
    end
end)

----------------------------------------------------------------
-- Combat log: record enemy contacts
----------------------------------------------------------------
local TRACKED_EVENTS = {
    SPELL_CAST_SUCCESS     = true,
    SPELL_DAMAGE           = true,
    SPELL_AURA_APPLIED     = true,
    SWING_DAMAGE           = true,
    RANGE_DAMAGE           = true,
    SPELL_HEAL             = true,
    SPELL_PERIODIC_DAMAGE  = true,
    SPELL_MISSED           = true,
    SWING_MISSED           = true,
}

-- Cache the nameplate unit list (rebuild occasionally, not every event)
local nameplateUnits = {}
local lastNameplateRefresh = 0

local function RefreshNameplates()
    local now = GetTime()
    if now - lastNameplateRefresh < 0.5 then return end
    lastNameplateRefresh = now
    wipe(nameplateUnits)
    for n = 1, 40 do
        local uid = "nameplate" .. n
        if UnitExists(uid) then
            local guid = UnitGUID(uid)
            if guid then nameplateUnits[guid] = uid end
        end
    end
end

local function TryGetPosition(guid, name)
    -- Fast path: check known unitIDs for this GUID
    RefreshNameplates()

    local unitID = nameplateUnits[guid]
    if unitID then
        local x, y = UnitPosition(unitID)
        if x then return x, y end
    end

    -- Check target/focus/mouseover
    for _, uid in ipairs({"target", "focus", "mouseover"}) do
        if UnitGUID(uid) == guid then
            local x, y = UnitPosition(uid)
            if x then return x, y end
        end
    end

    return nil, nil
end

local function RecordContact(guid, name, flags, stealthOverride)
    if not guid or not addon:IsEnemy(flags) then return end

    local _, class = GetPlayerInfoByGUID(guid)
    local x, y = TryGetPosition(guid, name)

    local existing = contacts[guid]
    if existing then
        existing.name = name or existing.name
        existing.class = class or existing.class
        existing.time = GetTime()
        if x then
            existing.x = x
            existing.y = y
        end
        if stealthOverride ~= nil then
            existing.isStealthed = stealthOverride
        end
    else
        contacts[guid] = {
            name = name or "Unknown",
            class = class,
            x = x,
            y = y,
            time = GetTime(),
            isStealthed = stealthOverride or false,
        }
    end
end

addon:RegisterCombatCallback("radar", function(info)
    if not addon.db or not addon.db.radar then return end

    local subevent   = info[2]
    local sourceGUID = info[4]
    local sourceName = info[5]
    local sourceFlags = info[6]
    local destGUID   = info[8]
    local destName   = info[9]
    local destFlags  = info[10]
    local spellID    = info[12]

    if TRACKED_EVENTS[subevent] then
        RecordContact(sourceGUID, sourceName, sourceFlags, nil)
        if destGUID ~= sourceGUID then
            RecordContact(destGUID, destName, destFlags, nil)
        end
    end

    -- Stealth tracking
    if (subevent == "SPELL_CAST_SUCCESS" or subevent == "SPELL_AURA_APPLIED")
        and addon.STEALTH_SPELLS[spellID]
        and addon:IsEnemy(sourceFlags)
    then
        RecordContact(sourceGUID, sourceName, sourceFlags, true)
    end

    if subevent == "SPELL_AURA_REMOVED" and addon.STEALTH_SPELLS[spellID] then
        if contacts[sourceGUID] then contacts[sourceGUID].isStealthed = false end
        if contacts[destGUID]   then contacts[destGUID].isStealthed = false end
    end
end)

----------------------------------------------------------------
-- Reset
----------------------------------------------------------------
function addon:ResetRadar()
    wipe(contacts)
    HideAllDots()
    countFrame:Hide()
end

local origOnZoneChange = addon.OnZoneChange
function addon:OnZoneChange()
    if origOnZoneChange then origOnZoneChange(self) end
    if self.ResetRadar then self:ResetRadar() end
end
