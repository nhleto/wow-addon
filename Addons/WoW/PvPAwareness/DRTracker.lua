local addon = PvPAwareness
local UI = addon.UI

-- drState[guid] = { _name, _class, [category] = { count, expires } }
local drState = {}

local DR_DURATION = 18.0
local MAX_TARGETS = 5
local CELL_WIDTH  = 54
local CELL_HEIGHT = 32
local ROW_HEIGHT  = 36
local NAME_WIDTH  = 80

----------------------------------------------------------------
-- DR level definitions
----------------------------------------------------------------
local DR_LEVELS = {
    [0] = {label = "FULL",   r = 0.20, g = 0.90, b = 0.20},
    [1] = {label = "1/2",    r = 0.95, g = 0.85, b = 0.15},
    [2] = {label = "1/4",    r = 0.95, g = 0.45, b = 0.10},
    [3] = {label = "IMMUNE", r = 0.95, g = 0.12, b = 0.12},
}

----------------------------------------------------------------
-- Main DR panel
----------------------------------------------------------------
local panel = UI:CreatePanel("PvPAwarenessDRFrame", UIParent, 340, 150)
panel:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 30, -220)
panel:Hide()

local titleText = UI:CreateHeader(panel, "DIMINISHING RETURNS", -(UI.INNER_PADDING - 1))
titleText:SetFont(UI.FONT, UI.FONT_SIZE_SM, "OUTLINE")
titleText:SetTextColor(unpack(UI.TEXT_DIM))

local titleLine = panel:CreateTexture(nil, "ARTWORK")
titleLine:SetTexture(UI.FLAT_TEXTURE)
titleLine:SetVertexColor(unpack(UI.ACCENT_COLOR))
titleLine:SetHeight(1)
titleLine:SetPoint("TOPLEFT", panel, "TOPLEFT", UI.INNER_PADDING, -(UI.HEADER_HEIGHT + UI.INNER_PADDING))
titleLine:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -UI.INNER_PADDING, -(UI.HEADER_HEIGHT + UI.INNER_PADDING))

----------------------------------------------------------------
-- Row + cell pools
----------------------------------------------------------------
local rowPool = {}
local rowPoolIdx = 0

local function ResetRowPool()
    for _, row in ipairs(rowPool) do
        row:Hide()
        for _, cell in ipairs(row._cells or {}) do cell:Hide() end
    end
    rowPoolIdx = 0
end

local function AcquireRow()
    rowPoolIdx = rowPoolIdx + 1
    if rowPool[rowPoolIdx] then
        rowPool[rowPoolIdx]:Show()
        return rowPool[rowPoolIdx]
    end

    local row = CreateFrame("Frame", nil, panel)
    row:SetSize(320, ROW_HEIGHT)

    -- Class dot
    row.dot = row:CreateTexture(nil, "ARTWORK")
    row.dot:SetTexture(UI.FLAT_TEXTURE)
    row.dot:SetSize(6, 6)
    row.dot:SetPoint("LEFT", 0, 0)

    -- Name label
    row.nameText = row:CreateFontString(nil, "OVERLAY")
    row.nameText:SetFont(UI.FONT, UI.FONT_SIZE_SM, "OUTLINE")
    row.nameText:SetPoint("LEFT", row.dot, "RIGHT", 4, 0)
    row.nameText:SetWidth(NAME_WIDTH - 10)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)

    row._cells = {}
    rowPool[rowPoolIdx] = row
    return row
end

local function AcquireCell(row, index)
    if row._cells[index] then
        row._cells[index]:Show()
        return row._cells[index]
    end

    local cell = CreateFrame("Frame", nil, row)
    cell:SetSize(CELL_WIDTH, CELL_HEIGHT)

    -- Cell background
    cell.bg = cell:CreateTexture(nil, "BACKGROUND")
    cell.bg:SetAllPoints()
    cell.bg:SetTexture(UI.FLAT_TEXTURE)
    cell.bg:SetVertexColor(0.1, 0.1, 0.1, 0.9)

    -- Left accent bar showing category
    cell.catBar = cell:CreateTexture(nil, "ARTWORK")
    cell.catBar:SetTexture(UI.FLAT_TEXTURE)
    cell.catBar:SetPoint("TOPLEFT")
    cell.catBar:SetPoint("BOTTOMLEFT")
    cell.catBar:SetWidth(2)

    -- Category name (top)
    cell.catText = cell:CreateFontString(nil, "OVERLAY")
    cell.catText:SetFont(UI.FONT, 7, "OUTLINE")
    cell.catText:SetPoint("TOP", 1, -2)
    cell.catText:SetTextColor(unpack(UI.TEXT_DIM))

    -- DR level (center, large)
    cell.drText = cell:CreateFontString(nil, "OVERLAY")
    cell.drText:SetFont(UI.FONT, UI.FONT_SIZE_MD, "OUTLINE")
    cell.drText:SetPoint("CENTER", 1, 0)

    -- Timer (bottom)
    cell.timeText = cell:CreateFontString(nil, "OVERLAY")
    cell.timeText:SetFont(UI.FONT, 8, "OUTLINE")
    cell.timeText:SetPoint("BOTTOM", 1, 2)
    cell.timeText:SetTextColor(0.65, 0.65, 0.65)

    -- Progress underlay (fills from bottom)
    cell.fill = cell:CreateTexture(nil, "BORDER")
    cell.fill:SetTexture(UI.FLAT_TEXTURE)
    cell.fill:SetPoint("BOTTOMLEFT", 2, 0)
    cell.fill:SetPoint("BOTTOMRIGHT", 0, 0)

    row._cells[index] = cell
    return cell
end

----------------------------------------------------------------
-- Category display colors (for the accent bar on cells)
----------------------------------------------------------------
local CAT_DISPLAY = {
    stun                = {r = 0.95, g = 0.15, b = 0.15, short = "STN"},
    fear                = {r = 0.60, g = 0.10, b = 0.80, short = "FEAR"},
    incapacitate_long   = {r = 0.15, g = 0.80, b = 0.90, short = "POLY"},
    incapacitate_short  = {r = 0.95, g = 0.55, b = 0.10, short = "INCAP"},
    disorient           = {r = 0.95, g = 0.40, b = 0.10, short = "DISOR"},
    sap                 = {r = 0.95, g = 0.90, b = 0.20, short = "SAP"},
    root                = {r = 0.15, g = 0.85, b = 0.25, short = "ROOT"},
    silence             = {r = 0.40, g = 0.40, b = 0.95, short = "SIL"},
    sleep               = {r = 0.60, g = 0.60, b = 0.95, short = "SLEEP"},
    horror              = {r = 0.45, g = 0.05, b = 0.65, short = "HORR"},
}

----------------------------------------------------------------
-- Update display
----------------------------------------------------------------
local updateFrame = CreateFrame("Frame")
updateFrame.elapsed = 0
updateFrame:SetScript("OnUpdate", function(self, dt)
    self.elapsed = self.elapsed + dt
    if self.elapsed < 0.1 then return end
    self.elapsed = 0

    if not addon.db or not addon.db.drTracker then
        panel:Hide()
        return
    end

    local now = GetTime()
    local hasAnything = false

    ResetRowPool()

    -- Collect targets with active DR
    local targets = {}
    for guid, cats in pairs(drState) do
        local activeCats = {}
        for cat, state in pairs(cats) do
            if type(state) == "table" and state.expires then
                if state.expires > now then
                    table.insert(activeCats, {
                        category = cat,
                        count = state.count,
                        remaining = state.expires - now,
                    })
                    hasAnything = true
                else
                    cats[cat] = nil
                end
            end
        end

        if #activeCats > 0 then
            table.sort(activeCats, function(a, b) return a.remaining < b.remaining end)
            table.insert(targets, {
                guid = guid,
                name = cats._name or "Unknown",
                class = cats._class,
                drs = activeCats,
            })
        end
    end

    if not hasAnything then
        panel:Hide()
        return
    end

    table.sort(targets, function(a, b) return a.name < b.name end)

    local yOff = -(UI.HEADER_HEIGHT + UI.INNER_PADDING + 4)
    local maxWidth = NAME_WIDTH

    for i, target in ipairs(targets) do
        if i > MAX_TARGETS then break end

        local row = AcquireRow()
        row:SetParent(panel)
        row:SetPoint("TOPLEFT", panel, "TOPLEFT", UI.INNER_PADDING, yOff)

        row.nameText:SetText(addon:ClassColoredName(target.name, target.class))
        local cr, cg, cb = addon:ClassColor(target.class)
        row.dot:SetVertexColor(cr, cg, cb, 1)

        for j, dr in ipairs(target.drs) do
            local cell = AcquireCell(row, j)
            cell:SetParent(row)
            cell:SetPoint("LEFT", row, "LEFT", NAME_WIDTH + (j - 1) * (CELL_WIDTH + 3), 0)

            local catInfo = CAT_DISPLAY[dr.category] or {r = 0.5, g = 0.5, b = 0.5, short = "?"}
            local level = math.min(dr.count, 3)
            local drInfo = DR_LEVELS[level]

            cell.catBar:SetVertexColor(catInfo.r, catInfo.g, catInfo.b, 1)
            cell.catText:SetText(catInfo.short)

            cell.drText:SetText(drInfo.label)
            cell.drText:SetTextColor(drInfo.r, drInfo.g, drInfo.b, 1)

            cell.timeText:SetText(addon:FormatTime(dr.remaining))

            -- Fill bar shows time remaining proportion
            local pct = dr.remaining / DR_DURATION
            cell.fill:SetHeight(math.max(1, CELL_HEIGHT * pct))
            cell.fill:SetVertexColor(drInfo.r * 0.15, drInfo.g * 0.15, drInfo.b * 0.15, 0.6)

            -- Pulse the cell bg when near expiry (DR about to reset)
            if dr.remaining < 3 then
                local pulse = 0.1 + 0.08 * math.sin(now * 6)
                cell.bg:SetVertexColor(drInfo.r * pulse * 2, drInfo.g * pulse * 2, drInfo.b * pulse * 2, 0.9)
            else
                cell.bg:SetVertexColor(0.1, 0.1, 0.1, 0.9)
            end

            local rowEndX = NAME_WIDTH + j * (CELL_WIDTH + 3)
            if rowEndX > maxWidth then maxWidth = rowEndX end
        end

        yOff = yOff - (ROW_HEIGHT + 4)
    end

    panel:SetSize(maxWidth + UI.INNER_PADDING * 2, math.abs(yOff) + UI.INNER_PADDING)

    -- Update title line width
    titleLine:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -UI.INNER_PADDING, -(UI.HEADER_HEIGHT + UI.INNER_PADDING))

    panel:Show()
end)

----------------------------------------------------------------
-- Combat log: track CC applications
----------------------------------------------------------------
addon:RegisterCombatCallback("dr", function(info)
    if not addon.db or not addon.db.drTracker then return end

    local subevent = info[2]
    local destGUID = info[8]
    local destName = info[9]
    local spellID  = info[12]

    if subevent ~= "SPELL_AURA_APPLIED" then return end
    if not spellID or not destGUID then return end

    local drCat = addon.DR_CATEGORIES[spellID]
    if not drCat then return end

    if not drState[destGUID] then
        drState[destGUID] = {}
    end

    local _, targetClass = GetPlayerInfoByGUID(destGUID)
    drState[destGUID]._name = destName
    drState[destGUID]._class = targetClass

    local now = GetTime()
    local existing = drState[destGUID][drCat]

    if not existing then
        drState[destGUID][drCat] = { count = 1, expires = now + DR_DURATION }
    elseif existing.expires > now then
        existing.count = math.min(existing.count + 1, 3)
        existing.expires = now + DR_DURATION
    else
        drState[destGUID][drCat] = { count = 1, expires = now + DR_DURATION }
    end

    -- Alert player about their own DR state
    if destGUID == UnitGUID("player") then
        local state = drState[destGUID][drCat]
        local catInfo = CAT_DISPLAY[drCat] or {short = drCat}
        if state.count == 2 then
            print("|cff18b818[PvP Awareness]|r " .. catInfo.short .. ": |cfff0d818HALF|r duration next")
        elseif state.count >= 3 then
            addon:FlashAlert(catInfo.short .. " — IMMUNE NEXT", 0.2, 0.95, 0.2, 1.5)
        end
    end
end)

----------------------------------------------------------------
-- Reset
----------------------------------------------------------------
function addon:ResetDR()
    wipe(drState)
    ResetRowPool()
    panel:Hide()
end
