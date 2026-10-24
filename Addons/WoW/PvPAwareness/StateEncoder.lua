local addon = PvPAwareness
local UI = addon.UI

----------------------------------------------------------------
-- Pixel-based state encoder for external companion app
--
-- Renders game state as colored pixels in a small frame.
-- An external Python app captures this region and decodes
-- the pixel colors back into structured game state.
--
-- Encoding: each pixel's R, G, B channels carry one byte (0-255).
-- The frame is positioned at the top-left corner of the screen
-- and is nearly invisible (1px dots on a dark background).
----------------------------------------------------------------

local GRID_COLS    = 20
local GRID_ROWS    = 5
local PIXEL_SIZE   = 3
local FRAME_X      = 0
local FRAME_Y      = 0
local UPDATE_RATE  = 0.1   -- 10 Hz state updates
local MAX_ENEMIES  = 5

-- Sync marker so the companion app can find our pixel grid
local SYNC_R = 0xDE
local SYNC_G = 0xAD
local SYNC_B = 0x01   -- protocol version 1

-- Class index mapping (must match companion app)
local CLASS_INDEX = {
    WARRIOR     = 1,
    PALADIN     = 2,
    HUNTER      = 3,
    ROGUE       = 4,
    PRIEST      = 5,
    SHAMAN      = 6,
    MAGE        = 7,
    WARLOCK     = 8,
    DRUID       = 9,
}

----------------------------------------------------------------
-- Pixel grid frame
----------------------------------------------------------------
local frame = CreateFrame("Frame", "PvPAwarenessStateEncoder", UIParent)
frame:SetSize(GRID_COLS * PIXEL_SIZE, GRID_ROWS * PIXEL_SIZE)
frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", FRAME_X, -FRAME_Y)
frame:SetFrameStrata("TOOLTIP")
frame:SetFrameLevel(100)

local bgTex = frame:CreateTexture(nil, "BACKGROUND")
bgTex:SetAllPoints()
bgTex:SetTexture(UI.FLAT_TEXTURE)
bgTex:SetVertexColor(0, 0, 0, 1)

-- Create pixel textures
local pixels = {}
for row = 0, GRID_ROWS - 1 do
    pixels[row] = {}
    for col = 0, GRID_COLS - 1 do
        local px = frame:CreateTexture(nil, "OVERLAY")
        px:SetTexture(UI.FLAT_TEXTURE)
        px:SetSize(PIXEL_SIZE, PIXEL_SIZE)
        px:SetPoint("TOPLEFT", frame, "TOPLEFT", col * PIXEL_SIZE, -(row * PIXEL_SIZE))
        px:SetVertexColor(0, 0, 0, 1)
        pixels[row][col] = px
    end
end

----------------------------------------------------------------
-- Pixel write helper
----------------------------------------------------------------
local function SetPixel(index, r, g, b)
    local row = math.floor(index / GRID_COLS)
    local col = index % GRID_COLS
    if row >= GRID_ROWS then return end
    local px = pixels[row] and pixels[row][col]
    if px then
        px:SetVertexColor(r / 255, g / 255, b / 255, 1)
    end
end

local function Clamp(val, low, high)
    if val < low then return low end
    if val > high then return high end
    return math.floor(val)
end

local function PctByte(current, maximum)
    if not maximum or maximum == 0 then return 0 end
    return Clamp((current / maximum) * 255, 0, 255)
end

----------------------------------------------------------------
-- Collect enemy state from addon modules
----------------------------------------------------------------
local function GetEnemyData()
    local enemies = {}

    -- Pull from CombatRadar contacts via addon internal state
    -- CombatRadar exposes contacts through the combat callback system
    -- We read the shared radar contacts + any active CD/DR state

    -- Check if CooldownTracker has tracked enemies
    if addon._trackedEnemies then
        for guid, data in pairs(addon._trackedEnemies) do
            if not enemies[guid] then
                enemies[guid] = {
                    name = data.name or "Unknown",
                    class = data.class,
                    guid = guid,
                    healthPct = 0,
                    hasCDs = false,
                    isStealthed = false,
                    drCount = 0,
                    distance = 0,
                }
            end
        end
    end

    -- Enrich from nameplates, target, focus
    for guid, enemy in pairs(enemies) do
        local unitID = nil
        -- Check nameplates
        for n = 1, 40 do
            local uid = "nameplate" .. n
            if UnitExists(uid) and UnitGUID(uid) == guid then
                unitID = uid
                break
            end
        end
        -- Check target/focus
        if not unitID then
            for _, uid in ipairs({"target", "focus", "mouseover"}) do
                if UnitGUID(uid) == guid then
                    unitID = uid
                    break
                end
            end
        end

        if unitID then
            local hp = UnitHealth(unitID)
            local hpMax = UnitHealthMax(unitID)
            enemy.healthPct = PctByte(hp, hpMax)

            local px, py = UnitPosition("player")
            local ex, ey = UnitPosition(unitID)
            if px and ex then
                enemy.distance = Clamp(addon:Dist2D(px, py, ex, ey), 0, 255)
            end
        end
    end

    -- Also add current target if hostile player not already tracked
    if UnitExists("target") and UnitIsPlayer("target") and UnitIsEnemy("player", "target") then
        local guid = UnitGUID("target")
        if guid and not enemies[guid] then
            local _, class = UnitClass("target")
            local hp = UnitHealth("target")
            local hpMax = UnitHealthMax("target")
            enemies[guid] = {
                name = UnitName("target") or "Unknown",
                class = class,
                guid = guid,
                healthPct = PctByte(hp, hpMax),
                hasCDs = false,
                isStealthed = false,
                drCount = 0,
                distance = 0,
            }
            local px, py = UnitPosition("player")
            local ex, ey = UnitPosition("target")
            if px and ex then
                enemies[guid].distance = Clamp(addon:Dist2D(px, py, ex, ey), 0, 255)
            end
        end
    end

    -- Convert to sorted list (closest first)
    local sorted = {}
    for _, e in pairs(enemies) do
        table.insert(sorted, e)
    end
    table.sort(sorted, function(a, b) return a.distance < b.distance end)

    return sorted
end

----------------------------------------------------------------
-- Encode 16-bit coordinate as two bytes (high, low)
-- Range: 0-65535, maps from signed world coords via offset
----------------------------------------------------------------
local COORD_OFFSET = 32768

local function CoordHigh(worldVal)
    local v = Clamp((worldVal or 0) + COORD_OFFSET, 0, 65535)
    return math.floor(v / 256)
end

local function CoordLow(worldVal)
    local v = Clamp((worldVal or 0) + COORD_OFFSET, 0, 65535)
    return v % 256
end

local function FacingByte(radians)
    -- Map 0..2*PI to 0..255
    local r = (radians or 0) % (2 * math.pi)
    return Clamp(r / (2 * math.pi) * 255, 0, 255)
end

----------------------------------------------------------------
-- Encode state into pixel grid
----------------------------------------------------------------
local function EncodeState()
    -- Clear all pixels to black
    for i = 0, (GRID_COLS * GRID_ROWS) - 1 do
        SetPixel(i, 0, 0, 0)
    end

    local idx = 0

    -- Pixel 0: Sync marker
    SetPixel(idx, SYNC_R, SYNC_G, SYNC_B)
    idx = idx + 1

    -- Pixel 1: Player health / power / flags
    local playerHP = PctByte(UnitHealth("player"), UnitHealthMax("player"))
    local playerPower = PctByte(UnitPower("player"), UnitPowerMax("player"))
    local flags = 0
    if UnitAffectingCombat("player") then flags = flags + 1 end
    local _, instanceType = IsInInstance()
    if instanceType == "pvp" then flags = flags + 2
    elseif instanceType == "arena" then flags = flags + 4
    elseif instanceType == "none" then
        local pvpType = GetZonePVPInfo()
        if pvpType == "combat" or pvpType == "contested" then flags = flags + 8 end
    end
    SetPixel(idx, playerHP, playerPower, flags)
    idx = idx + 1

    -- Pixel 2: Player class + enemy count + stealth nearby flag
    local _, playerClass = UnitClass("player")
    local classIdx = CLASS_INDEX[playerClass] or 0
    local enemies = GetEnemyData()
    local enemyCount = math.min(#enemies, MAX_ENEMIES)
    local stealthNearby = 0
    for _, e in ipairs(enemies) do
        if e.isStealthed then stealthNearby = 1 break end
    end
    SetPixel(idx, classIdx, enemyCount, stealthNearby)
    idx = idx + 1

    -- Pixels 3-17: Per-enemy data (3 pixels each)
    for i = 1, MAX_ENEMIES do
        local e = enemies[i]
        if e then
            local eClassIdx = CLASS_INDEX[e.class] or 0

            -- Enemy pixel 1: health%, class, stealthed
            SetPixel(idx, e.healthPct, eClassIdx, e.isStealthed and 1 or 0)
            idx = idx + 1

            -- Enemy pixel 2: distance, DR count, hasCDs
            SetPixel(idx, e.distance, e.drCount, e.hasCDs and 1 or 0)
            idx = idx + 1

            -- Enemy pixel 3: reserved for expansion
            SetPixel(idx, 0, 0, 0)
            idx = idx + 1
        else
            -- Empty enemy slots
            SetPixel(idx, 0, 0, 0); idx = idx + 1
            SetPixel(idx, 0, 0, 0); idx = idx + 1
            SetPixel(idx, 0, 0, 0); idx = idx + 1
        end
    end

    -- idx is now 18
    -- ============================================================
    -- NAVIGATION DATA (pixels 18-29)
    -- Populated by QuestNavigator.lua via addon._navData
    -- ============================================================
    local nav = addon._navData
    if nav then
        -- Pixel 18: Player X (high byte), Player Y (high byte), facing
        SetPixel(18, CoordHigh(nav.playerX), CoordHigh(nav.playerY), FacingByte(nav.facing))

        -- Pixel 19: Player X (low byte), Player Y (low byte), player level
        SetPixel(19, CoordLow(nav.playerX), CoordLow(nav.playerY), Clamp(nav.playerLevel or 0, 0, 255))

        -- Pixel 20: Target X (high byte), Target Y (high byte), target type
        SetPixel(20, CoordHigh(nav.targetX), CoordHigh(nav.targetY), Clamp(nav.targetType or 0, 0, 255))

        -- Pixel 21: Target X (low byte), Target Y (low byte), hasTarget flag
        SetPixel(21, CoordLow(nav.targetX), CoordLow(nav.targetY), nav.hasTarget and 1 or 0)

        -- Pixel 22: Movement flags + speed
        local moveFlags = 0
        if nav.isMoving   then moveFlags = moveFlags + 1 end
        if nav.isMounted  then moveFlags = moveFlags + 2 end
        if nav.isDead     then moveFlags = moveFlags + 4 end
        if nav.isIndoors  then moveFlags = moveFlags + 8 end
        if nav.isSwimming then moveFlags = moveFlags + 16 end
        if nav.isFlying   then moveFlags = moveFlags + 32 end
        local speedByte = Clamp((nav.playerSpeed or 0) / 14 * 255, 0, 255)
        SetPixel(22, moveFlags, speedByte, Clamp(nav.questCount or 0, 0, 255))

        -- Pixel 23: Distance to target (high byte, low byte), map ID low byte
        local dist16 = Clamp(nav.distToTarget or 0, 0, 65535)
        SetPixel(23, math.floor(dist16 / 256), dist16 % 256, (nav.mapID or 0) % 256)
    end
end

----------------------------------------------------------------
-- Update timer
----------------------------------------------------------------
local updateFrame = CreateFrame("Frame")
updateFrame.elapsed = 0
updateFrame:SetScript("OnUpdate", function(self, dt)
    self.elapsed = self.elapsed + dt
    if self.elapsed < UPDATE_RATE then return end
    self.elapsed = 0

    if not addon.db then return end

    EncodeState()
end)

-- Expose the encoder frame position for the companion app
addon.stateEncoderInfo = {
    x = FRAME_X,
    y = FRAME_Y,
    cols = GRID_COLS,
    rows = GRID_ROWS,
    pixelSize = PIXEL_SIZE,
}
