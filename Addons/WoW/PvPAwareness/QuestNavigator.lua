local addon = PvPAwareness
local UI = addon.UI

----------------------------------------------------------------
-- Quest Navigator
--
-- Reads the quest log to find the nearest incomplete objective,
-- grabs the player's current position and facing, and encodes
-- navigation data into the pixel grid for the companion app.
--
-- Also tracks nearby gathering nodes (herbs/ore) when tracking
-- is active, and provides profession-related state.
--
-- The companion app uses this to steer the character toward
-- objectives while the player is AFK.
----------------------------------------------------------------

local NAV_UPDATE_RATE = 0.15   -- ~7 Hz nav data updates

----------------------------------------------------------------
-- Navigation state (shared with StateEncoder)
----------------------------------------------------------------
addon._navData = {
    playerX = 0,
    playerY = 0,
    facing = 0,          -- radians, 0 = north, increases clockwise
    targetX = 0,
    targetY = 0,
    targetType = 0,      -- 0=none, 1=quest, 2=herb, 3=ore, 4=vendor, 5=mailbox, 6=waypoint
    targetName = "",
    distToTarget = 0,
    hasTarget = false,
    questCount = 0,
    playerLevel = 0,
    playerSpeed = 0,     -- current movement speed as % of base
    isMoving = false,
    isMounted = false,
    isDead = false,
    isIndoors = false,
    isSwimming = false,
    isFlying = false,
    mapID = 0,
    zoneText = "",
    subZoneText = "",
    nearestQuestIndex = 0,
}

local nav = addon._navData

----------------------------------------------------------------
-- Quest log scanner
----------------------------------------------------------------
local questCache = {}
local lastQuestScan = 0
local QUEST_SCAN_INTERVAL = 2.0

local function ScanQuestLog()
    local now = GetTime()
    if now - lastQuestScan < QUEST_SCAN_INTERVAL then return end
    lastQuestScan = now

    wipe(questCache)

    local numEntries = GetNumQuestLogEntries()
    for i = 1, numEntries do
        local title, level, _, isHeader, _, isComplete, _, questID = GetQuestLogTitle(i)
        if not isHeader and not isComplete then
            -- Try to get quest POI / objective location
            local x, y, mapId = nil, nil, nil

            -- Classic Era: use QuestPOI if available
            if C_QuestLog and C_QuestLog.GetNextWaypoint then
                mapId, x, y = C_QuestLog.GetNextWaypoint(questID)
            end

            -- Fallback: try GetQuestLogSpecialItemInfo for quest items
            -- that give location hints
            if not x then
                -- Some quests expose POI through the world map
                if QuestPOIGetIconInfo then
                    _, _, _, _, _, x, y = QuestPOIGetIconInfo(questID)
                end
            end

            table.insert(questCache, {
                index = i,
                title = title or "Unknown Quest",
                level = level or 0,
                questID = questID,
                x = x,
                y = y,
                mapId = mapId,
                isComplete = isComplete,
            })
        end
    end

    nav.questCount = #questCache
end

----------------------------------------------------------------
-- Convert map-normalized (0-1) coords to approximate world coords
-- using C_Map.GetMapWorldSize when available, else rough estimate.
----------------------------------------------------------------
local function MapToWorld(mapId, normX, normY)
    if not normX or not normY then return nil, nil end
    if C_Map and C_Map.GetMapWorldSize then
        local width, height = C_Map.GetMapWorldSize(mapId)
        if width and width > 0 then
            return normX * width, normY * height
        end
    end
    -- Fallback: typical zone is ~3000x3000 yards centered around origin
    -- This is rough but keeps distances in a comparable yard range
    local APPROX_ZONE = 3000
    return normX * APPROX_ZONE, normY * APPROX_ZONE
end

----------------------------------------------------------------
-- Find nearest quest with coordinates
----------------------------------------------------------------
local function FindNearestQuest()
    if #questCache == 0 then return nil end

    local px, py = UnitPosition("player")
    if not px then return nil end

    local best = nil
    local bestDist = math.huge

    for _, quest in ipairs(questCache) do
        if quest.x and quest.y then
            local wx, wy = MapToWorld(quest.mapId, quest.x, quest.y)
            if wx then
                local dist = addon:Dist2D(px, py, wx, wy)
                if dist < bestDist then
                    bestDist = dist
                    best = quest
                    best._worldX = wx
                    best._worldY = wy
                end
            end
        end
    end

    return best, bestDist
end

----------------------------------------------------------------
-- Gathering node detection via minimap tooltip scanning
----------------------------------------------------------------
local GATHERING_NODE_TYPES = {
    -- Herb keywords
    ["Peacebloom"] = 2, ["Silverleaf"] = 2, ["Earthroot"] = 2,
    ["Mageroyal"] = 2, ["Briarthorn"] = 2, ["Stranglekelp"] = 2,
    ["Bruiseweed"] = 2, ["Wild Steelbloom"] = 2, ["Grave Moss"] = 2,
    ["Kingsblood"] = 2, ["Liferoot"] = 2, ["Fadeleaf"] = 2,
    ["Goldthorn"] = 2, ["Khadgar's Whisker"] = 2, ["Wintersbite"] = 2,
    ["Firebloom"] = 2, ["Purple Lotus"] = 2, ["Arthas' Tears"] = 2,
    ["Sungrass"] = 2, ["Blindweed"] = 2, ["Ghost Mushroom"] = 2,
    ["Gromsblood"] = 2, ["Golden Sansam"] = 2, ["Dreamfoil"] = 2,
    ["Mountain Silversage"] = 2, ["Plaguebloom"] = 2,
    ["Icecap"] = 2, ["Black Lotus"] = 2,

    -- Ore keywords
    ["Copper Vein"] = 3, ["Tin Vein"] = 3, ["Silver Vein"] = 3,
    ["Iron Deposit"] = 3, ["Gold Vein"] = 3, ["Mithril Deposit"] = 3,
    ["Truesilver Deposit"] = 3, ["Dark Iron Deposit"] = 3,
    ["Small Thorium Vein"] = 3, ["Rich Thorium Vein"] = 3,
}

local nearestNode = nil
local lastNodeScan = 0
local NODE_SCAN_INTERVAL = 0.5

local function ScanGatheringNodes()
    local now = GetTime()
    if now - lastNodeScan < NODE_SCAN_INTERVAL then return end
    lastNodeScan = now
    nearestNode = nil

    -- Check mouseover for gathering node tooltip
    if GameTooltipTextLeft1 then
        local text = GameTooltipTextLeft1:GetText()
        if text then
            local nodeType = GATHERING_NODE_TYPES[text]
            if nodeType then
                -- Mouseover has a node — get its position if possible
                if UnitExists("mouseover") then
                    local x, y = UnitPosition("mouseover")
                    if x then
                        nearestNode = {
                            name = text,
                            type = nodeType,
                            x = x,
                            y = y,
                        }
                    end
                end
            end
        end
    end

    -- Check minimap tracking pings
    -- In Classic, gathering tracking shows icons on the minimap
    -- We can detect them via the minimap's child frames
    local numPOIs = GetNumTrackingTypes and GetNumTrackingTypes() or 0
    for i = 1, numPOIs do
        local name, _, active = GetTrackingInfo(i)
        if active and (name == "Find Herbs" or name == "Find Minerals") then
            -- Tracking is active — nodes appear on minimap
            -- The companion app can also read minimap dots
            nav.trackingActive = true
            break
        end
    end
end

----------------------------------------------------------------
-- Player movement state
----------------------------------------------------------------
local function UpdatePlayerState()
    local px, py = UnitPosition("player")
    local facing = GetPlayerFacing()

    if px then
        nav.playerX = px
        nav.playerY = py
    end
    nav.facing = facing or 0

    nav.playerLevel = UnitLevel("player")
    nav.isDead = UnitIsDead("player")
    nav.isMounted = IsMounted()
    nav.isSwimming = IsSwimming()
    nav.isIndoors = IsIndoors()
    nav.isFlying = IsFlying and IsFlying() or false
    nav.isMoving = GetUnitSpeed("player") > 0
    nav.playerSpeed = GetUnitSpeed("player")

    -- Zone info
    nav.zoneText = GetZoneText() or ""
    nav.subZoneText = GetSubZoneText() or ""

    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    nav.mapID = mapID or 0
end

----------------------------------------------------------------
-- Pick navigation target (priority: quest > node > none)
----------------------------------------------------------------
local function UpdateNavTarget()
    ScanQuestLog()
    ScanGatheringNodes()
    UpdatePlayerState()

    -- Priority 1: Nearby gathering node
    if nearestNode then
        nav.targetX = nearestNode.x
        nav.targetY = nearestNode.y
        nav.targetType = nearestNode.type
        nav.targetName = nearestNode.name
        nav.hasTarget = true
        nav.distToTarget = addon:Dist2D(nav.playerX, nav.playerY, nearestNode.x, nearestNode.y)
        return
    end

    -- Priority 2: Nearest quest objective
    local quest, dist = FindNearestQuest()
    if quest and quest._worldX then
        nav.targetX = quest._worldX
        nav.targetY = quest._worldY
        nav.targetType = 1
        nav.targetName = quest.title
        nav.hasTarget = true
        nav.distToTarget = dist or 0
        nav.nearestQuestIndex = quest.index
        return
    end

    -- No target
    nav.hasTarget = false
    nav.targetType = 0
    nav.targetX = 0
    nav.targetY = 0
    nav.distToTarget = 0
    nav.targetName = ""
end

----------------------------------------------------------------
-- Update timer
----------------------------------------------------------------
local navFrame = CreateFrame("Frame")
navFrame.elapsed = 0
navFrame:SetScript("OnUpdate", function(self, dt)
    self.elapsed = self.elapsed + dt
    if self.elapsed < NAV_UPDATE_RATE then return end
    self.elapsed = 0

    if not addon.db then return end

    UpdateNavTarget()
end)

----------------------------------------------------------------
-- Minimap waypoint arrow (shows where the nav system is heading)
----------------------------------------------------------------
local arrowFrame = CreateFrame("Frame", nil, Minimap)
arrowFrame:SetSize(24, 24)
arrowFrame:SetPoint("CENTER", Minimap, "CENTER", 0, 0)
arrowFrame:SetFrameStrata("HIGH")
arrowFrame:SetFrameLevel(Minimap:GetFrameLevel() + 20)

local arrowTex = arrowFrame:CreateTexture(nil, "OVERLAY")
arrowTex:SetTexture("Interface\\Minimap\\ROTATING-MINIMAPGUIDEARROW")
arrowTex:SetAllPoints()
arrowFrame:Hide()

local arrowLabel = arrowFrame:CreateFontString(nil, "OVERLAY")
arrowLabel:SetFont(UI.FONT, 8, "OUTLINE")
arrowLabel:SetPoint("TOP", arrowFrame, "BOTTOM", 0, -2)
arrowLabel:SetTextColor(0.9, 0.8, 0.2, 1)

arrowFrame:SetScript("OnUpdate", function(self, dt)
    if not nav.hasTarget or not addon.db then
        self:Hide()
        return
    end

    local px, py = nav.playerX, nav.playerY
    local tx, ty = nav.targetX, nav.targetY
    if not px or not tx or (px == 0 and py == 0) or (tx == 0 and ty == 0) then
        self:Hide()
        return
    end

    self:Show()

    -- Calculate bearing to target
    local dx = tx - px
    local dy = ty - py
    local bearing = math.atan2(dx, dy) -- radians from north

    -- Rotate arrow to point toward target relative to player facing
    local facing = nav.facing or 0
    local relAngle = bearing - facing

    arrowTex:SetRotation(-relAngle)

    -- Position arrow at edge of minimap in target direction
    local mmRadius = Minimap:GetWidth() / 2
    local edgeDist = mmRadius - 14
    local mapAngle = relAngle
    -- If minimap rotates, arrow stays at top (north-relative)
    local rotates = GetCVar("rotateMinimap") == "1"
    if not rotates then
        mapAngle = bearing
    end
    local ax = math.sin(mapAngle) * edgeDist
    local ay = math.cos(mapAngle) * edgeDist
    self:SetPoint("CENTER", Minimap, "CENTER", ax, ay)

    -- Distance label
    local dist = addon:Dist2D(px, py, tx, ty)
    if dist > 1000 then
        arrowLabel:SetText(string.format("%.1fk", dist / 1000))
    else
        arrowLabel:SetText(string.format("%d", dist))
    end
end)

----------------------------------------------------------------
-- Slash command for manual waypoints
----------------------------------------------------------------
local origSlashHandler = SlashCmdList["PVPA"]
SlashCmdList["PVPA"] = function(msg)
    local cmd, rest = strsplit(" ", strtrim(msg), 2)
    cmd = cmd:lower()

    if cmd == "goto" and rest then
        -- /pvpa goto x y — manual waypoint
        local x, y = strsplit(" ", strtrim(rest), 2)
        x, y = tonumber(x), tonumber(y)
        if x and y then
            nav.targetX = x
            nav.targetY = y
            nav.targetType = 6 -- waypoint
            nav.targetName = string.format("Waypoint (%.0f, %.0f)", x, y)
            nav.hasTarget = true
            print("|cff18b818[PvP Awareness]|r Navigating to " .. nav.targetName)
        else
            print("|cff18b818[PvP Awareness]|r Usage: /pvpa goto <x> <y>")
        end
    elseif cmd == "stop" then
        nav.hasTarget = false
        nav.targetType = 0
        print("|cff18b818[PvP Awareness]|r Navigation stopped.")
    elseif cmd == "nav" then
        if nav.hasTarget then
            print("|cff18b818[PvP Awareness]|r Navigating to: " .. nav.targetName)
            print("  Distance: " .. string.format("%.0f", nav.distToTarget) .. " yards")
        else
            print("|cff18b818[PvP Awareness]|r No navigation target.")
        end
    else
        -- Fall through to original handler
        if origSlashHandler then origSlashHandler(msg) end
    end
end
