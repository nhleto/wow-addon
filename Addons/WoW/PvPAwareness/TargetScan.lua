local addon = PvPAwareness
local UI = addon.UI

----------------------------------------------------------------
-- Target Scanner
--
-- Rapidly cycles /targetenemy to detect nearby hostile players
-- that haven't appeared in the combat log yet (around corners,
-- approaching from behind, hiding but not stealthed).
--
-- Feeds detected contacts into the radar system.
--
-- How it works:
--   1. Save current target
--   2. Run TargetNearestEnemy() to cycle through nearby hostiles
--   3. For each new hostile player found, record their GUID/name/class
--      and attempt to grab their position via UnitPosition("target")
--   4. Restore original target
--   5. Feed contacts into CombatRadar's contact list
--
-- This runs on a throttled timer to avoid spamming the target system.
-- The player's actual target is restored so fast they never see it change.
----------------------------------------------------------------

local SCAN_INTERVAL = 0.8   -- seconds between scans
local MAX_CYCLE     = 12    -- max targetenemy cycles per scan

----------------------------------------------------------------
-- Scan state
----------------------------------------------------------------
local scanFrame = CreateFrame("Frame")
scanFrame.elapsed = 0
scanFrame.scanning = false

-- Detected contacts this scan cycle
local scanContacts = {}

----------------------------------------------------------------
-- Notification: small flash when new enemies are found
----------------------------------------------------------------
local function NotifyNewContacts(newNames)
    if #newNames == 0 then return end
    local msg
    if #newNames == 1 then
        msg = newNames[1] .. " detected nearby"
    else
        msg = #newNames .. " enemies detected nearby"
    end
    print("|cff18b818[PvP Awareness]|r |cffff9900Scan:|r " .. msg)
end

----------------------------------------------------------------
-- Core scan logic
----------------------------------------------------------------
local knownGUIDs = {} -- guid → last scan time (to avoid re-alerting)
local KNOWN_TIMEOUT = 15

local function RunScan()
    if not addon.db or not addon.db.targetScan then return end
    if InCombatLockdown() then return end -- can't change target in combat

    -- Save current target
    local hadTarget = UnitExists("target")
    local origGUID = hadTarget and UnitGUID("target") or nil

    local seen = {}
    local newNames = {}

    -- Cycle through nearby enemies
    for i = 1, MAX_CYCLE do
        TargetNearestEnemy()

        if not UnitExists("target") then break end

        local guid = UnitGUID("target")
        if not guid or seen[guid] then break end -- wrapped around
        seen[guid] = true

        local isPlayer = UnitIsPlayer("target")
        local isEnemy = UnitIsEnemy("player", "target")

        if isPlayer and isEnemy then
            local name = UnitName("target")
            local _, class = UnitClass("target")
            local x, y = UnitPosition("target")

            -- Feed into radar contacts
            if addon.db.radar then
                local existing = false
                -- Access CombatRadar's RecordContact indirectly via a shared table
                if not addon._radarContacts then
                    addon._radarContacts = {}
                end
                addon._radarContacts[guid] = {
                    name = name or "Unknown",
                    class = class,
                    x = x,
                    y = y,
                    time = GetTime(),
                    isStealthed = false,
                }
            end

            -- Check if this is a new detection
            local now = GetTime()
            if not knownGUIDs[guid] or (now - knownGUIDs[guid]) > KNOWN_TIMEOUT then
                local colored = addon:ClassColoredName(name, class)
                table.insert(newNames, colored)
            end
            knownGUIDs[guid] = now
        end
    end

    -- Restore original target
    if hadTarget and origGUID then
        -- Target by GUID isn't available in Classic addon API directly,
        -- so we use TargetLastEnemy or clear target
        if UnitGUID("target") ~= origGUID then
            -- Try to re-acquire original target via macro-style targeting
            -- In practice, we use TargetLastTarget
            TargetLastTarget()
            -- If still wrong, clear to avoid confusion
            if UnitGUID("target") ~= origGUID then
                ClearTarget()
            end
        end
    elseif not hadTarget then
        ClearTarget()
    end

    NotifyNewContacts(newNames)
end

----------------------------------------------------------------
-- Scan timer
----------------------------------------------------------------
scanFrame:SetScript("OnUpdate", function(self, dt)
    self.elapsed = self.elapsed + dt
    if self.elapsed < SCAN_INTERVAL then return end
    self.elapsed = 0

    if not addon.db or not addon.db.targetScan then return end

    -- Only scan when in PvP-relevant zones
    local _, instanceType = IsInInstance()
    local pvpInfo = instanceType == "none" and GetZonePVPInfo() or nil
    local isPvPZone = instanceType == "pvp"
                   or instanceType == "arena"
                   or pvpInfo == "combat"
                   or pvpInfo == "contested"

    if not isPvPZone then return end

    RunScan()
end)

----------------------------------------------------------------
-- Expire old known GUIDs periodically
----------------------------------------------------------------
local expireFrame = CreateFrame("Frame")
expireFrame.elapsed = 0
expireFrame:SetScript("OnUpdate", function(self, dt)
    self.elapsed = self.elapsed + dt
    if self.elapsed < 5 then return end
    self.elapsed = 0
    local now = GetTime()
    for guid, t in pairs(knownGUIDs) do
        if now - t > KNOWN_TIMEOUT * 2 then
            knownGUIDs[guid] = nil
        end
    end
end)
