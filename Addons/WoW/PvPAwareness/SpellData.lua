local addon = PvPAwareness

----------------------------------------------------------------
-- Stealth spells: spellID → true
----------------------------------------------------------------
addon.STEALTH_SPELLS = {
    [1784]  = true,  -- Stealth (Rogue)
    [1785]  = true,  -- Stealth rank 2
    [1786]  = true,  -- Stealth rank 3
    [1787]  = true,  -- Stealth rank 4
    [1856]  = true,  -- Vanish (Rogue)
    [1857]  = true,  -- Vanish rank 2
    [5215]  = true,  -- Prowl (Druid)
    [6783]  = true,  -- Prowl rank 2
    [9913]  = true,  -- Prowl rank 3
    [20580] = true,  -- Shadowmeld (Night Elf racial)
}

-- Spells that break stealth (so we can mark the stealther as visible again)
addon.STEALTH_BREAK_SPELLS = {
    [8676]  = true,  -- Ambush
    [8724]  = true,  -- Ambush rank 2
    [8725]  = true,  -- Ambush rank 3
    [11267] = true,  -- Ambush rank 4
    [11268] = true,  -- Ambush rank 5
    [11269] = true,  -- Ambush rank 6
    [8647]  = true,  -- Cheap Shot
    [1833]  = true,  -- Cheap Shot (alt id)
    [2590]  = true,  -- Sap
    [2070]  = true,  -- Sap rank 2
    [11297] = true,  -- Sap rank 3
    [6770]  = true,  -- Sap (base)
    [5221]  = true,  -- Shred
    [6800]  = true,  -- Shred rank 2
    [8992]  = true,  -- Shred rank 3
    [9829]  = true,  -- Shred rank 4
    [9830]  = true,  -- Shred rank 5
    [27001] = true,  -- Shred rank 6
    [9005]  = true,  -- Pounce
    [9823]  = true,  -- Pounce rank 2
    [9827]  = true,  -- Pounce rank 3
    [24132] = true,  -- Wrath of Air Totem? Actually just include opener spells
    [1752]  = true,  -- Sinister Strike (breaks stealth on use)
    [53]    = true,  -- Backstab
}

----------------------------------------------------------------
-- PvP cooldowns: spellID → { cd = seconds, name = label, class = CLASS, category = string }
-- Categories: "interrupt", "defensive", "offensive", "cc", "mobility", "trinket"
----------------------------------------------------------------
addon.PVP_COOLDOWNS = {
    -- ROGUE
    [1766]  = {cd = 10,  name = "Kick",           class = "ROGUE",   cat = "interrupt"},
    [2094]  = {cd = 180, name = "Blind",           class = "ROGUE",   cat = "cc"},
    [1856]  = {cd = 300, name = "Vanish",          class = "ROGUE",   cat = "defensive"},
    [5277]  = {cd = 300, name = "Evasion",         class = "ROGUE",   cat = "defensive"},
    [2983]  = {cd = 300, name = "Sprint",          class = "ROGUE",   cat = "mobility"},
    [14177] = {cd = 180, name = "Cold Blood",      class = "ROGUE",   cat = "offensive"},
    [14185] = {cd = 600, name = "Preparation",     class = "ROGUE",   cat = "offensive"},
    [1725]  = {cd = 300, name = "Distract",        class = "ROGUE",   cat = "cc"},
    [8647]  = {cd = 1,   name = "Cheap Shot",      class = "ROGUE",   cat = "cc"},
    [408]   = {cd = 20,  name = "Kidney Shot",     class = "ROGUE",   cat = "cc"},

    -- MAGE
    [2139]  = {cd = 30,  name = "Counterspell",    class = "MAGE",    cat = "interrupt"},
    [11958] = {cd = 300, name = "Ice Block",       class = "MAGE",    cat = "defensive"},
    [1953]  = {cd = 15,  name = "Blink",           class = "MAGE",    cat = "mobility"},
    [12472] = {cd = 600, name = "Cold Snap",       class = "MAGE",    cat = "offensive"},
    [11129] = {cd = 180, name = "Combustion",      class = "MAGE",    cat = "offensive"},
    [12051] = {cd = 480, name = "Evocation",       class = "MAGE",    cat = "defensive"},
    [12042] = {cd = 180, name = "Arcane Power",    class = "MAGE",    cat = "offensive"},
    [12043] = {cd = 180, name = "Presence of Mind", class = "MAGE",   cat = "offensive"},

    -- WARRIOR
    [6552]  = {cd = 10,  name = "Pummel",          class = "WARRIOR", cat = "interrupt"},
    [72]    = {cd = 12,  name = "Shield Bash",     class = "WARRIOR", cat = "interrupt"},
    [20252] = {cd = 30,  name = "Intercept",       class = "WARRIOR", cat = "mobility"},
    [100]   = {cd = 15,  name = "Charge",          class = "WARRIOR", cat = "mobility"},
    [5246]  = {cd = 180, name = "Intimidating Shout", class = "WARRIOR", cat = "cc"},
    [871]   = {cd = 1800, name = "Shield Wall",    class = "WARRIOR", cat = "defensive"},
    [1719]  = {cd = 1800, name = "Recklessness",   class = "WARRIOR", cat = "offensive"},
    [20230] = {cd = 300, name = "Retaliation",     class = "WARRIOR", cat = "defensive"},
    [18499] = {cd = 30,  name = "Berserker Rage",  class = "WARRIOR", cat = "defensive"},
    [23920] = {cd = 10,  name = "Spell Reflect",   class = "WARRIOR", cat = "defensive"},
    [12292] = {cd = 180, name = "Death Wish",      class = "WARRIOR", cat = "offensive"},

    -- PRIEST
    [10890] = {cd = 30,  name = "Psychic Scream",  class = "PRIEST",  cat = "cc"},
    [15487] = {cd = 45,  name = "Silence",         class = "PRIEST",  cat = "interrupt"},
    [10060] = {cd = 180, name = "Power Infusion",  class = "PRIEST",  cat = "offensive"},
    [15286] = {cd = 180, name = "Vampiric Embrace", class = "PRIEST", cat = "offensive"},
    [10947] = {cd = 15,  name = "Mind Blast",      class = "PRIEST",  cat = "offensive"},
    [586]   = {cd = 30,  name = "Fade",            class = "PRIEST",  cat = "defensive"},

    -- WARLOCK
    [17926] = {cd = 120, name = "Death Coil",      class = "WARLOCK", cat = "cc"},
    [19647] = {cd = 24,  name = "Spell Lock",      class = "WARLOCK", cat = "interrupt"},
    [18708] = {cd = 900, name = "Fel Domination",  class = "WARLOCK", cat = "offensive"},
    [17962] = {cd = 60,  name = "Conflagrate",     class = "WARLOCK", cat = "offensive"},
    [18288] = {cd = 180, name = "Amplify Curse",   class = "WARLOCK", cat = "offensive"},
    [7812]  = {cd = 30,  name = "Sacrifice",       class = "WARLOCK", cat = "defensive"},
    [19505] = {cd = 15,  name = "Devour Magic",    class = "WARLOCK", cat = "defensive"},

    -- HUNTER
    [19503] = {cd = 30,  name = "Scatter Shot",    class = "HUNTER",  cat = "cc"},
    [5384]  = {cd = 30,  name = "Feign Death",     class = "HUNTER",  cat = "defensive"},
    [19263] = {cd = 300, name = "Deterrence",      class = "HUNTER",  cat = "defensive"},
    [19577] = {cd = 60,  name = "Intimidation",    class = "HUNTER",  cat = "cc"},
    [19386] = {cd = 12,  name = "Wyvern Sting",    class = "HUNTER",  cat = "cc"},
    [3045]  = {cd = 300, name = "Rapid Fire",      class = "HUNTER",  cat = "offensive"},
    [23989] = {cd = 300, name = "Readiness",       class = "HUNTER",  cat = "offensive"},
    [1543]  = {cd = 20,  name = "Flare",           class = "HUNTER",  cat = "cc"},

    -- PALADIN
    [10308] = {cd = 60,  name = "Hammer of Justice", class = "PALADIN", cat = "cc"},
    [642]   = {cd = 300, name = "Divine Shield",   class = "PALADIN", cat = "defensive"},
    [1022]  = {cd = 300, name = "Blessing of Protection", class = "PALADIN", cat = "defensive"},
    [10310] = {cd = 3600, name = "Lay on Hands",   class = "PALADIN", cat = "defensive"},
    [20066] = {cd = 60,  name = "Repentance",      class = "PALADIN", cat = "cc"},
    [6940]  = {cd = 120, name = "Blessing of Sacrifice", class = "PALADIN", cat = "defensive"},
    [20216] = {cd = 120, name = "Divine Favor",    class = "PALADIN", cat = "offensive"},

    -- SHAMAN
    [8042]  = {cd = 6,   name = "Earth Shock",     class = "SHAMAN",  cat = "interrupt"},
    [8177]  = {cd = 15,  name = "Grounding Totem", class = "SHAMAN",  cat = "defensive"},
    [16188] = {cd = 180, name = "Nature's Swiftness", class = "SHAMAN", cat = "offensive"},
    [16166] = {cd = 180, name = "Elemental Mastery", class = "SHAMAN", cat = "offensive"},
    [30823] = {cd = 120, name = "Shamanistic Rage", class = "SHAMAN", cat = "defensive"},

    -- DRUID
    [16979] = {cd = 15,  name = "Feral Charge",    class = "DRUID",   cat = "mobility"},
    [5211]  = {cd = 60,  name = "Bash",            class = "DRUID",   cat = "cc"},
    [17116] = {cd = 180, name = "Nature's Swiftness", class = "DRUID", cat = "offensive"},
    [29166] = {cd = 360, name = "Innervate",       class = "DRUID",   cat = "offensive"},
    [22812] = {cd = 60,  name = "Barkskin",        class = "DRUID",   cat = "defensive"},
    [22842] = {cd = 180, name = "Frenzied Regen",  class = "DRUID",   cat = "defensive"},

    -- RACIALS
    [20600] = {cd = 120, name = "Perception",      class = nil, cat = "defensive"},
    [7744]  = {cd = 120, name = "Will of the Forsaken", class = nil, cat = "defensive"},
    [20549] = {cd = 120, name = "War Stomp",       class = nil, cat = "cc"},
    [26297] = {cd = 180, name = "Berserking",      class = nil, cat = "offensive"},
    [20572] = {cd = 120, name = "Blood Fury",      class = nil, cat = "offensive"},
    [20594] = {cd = 180, name = "Stoneform",       class = nil, cat = "defensive"},
    [20589] = {cd = 60,  name = "Escape Artist",   class = nil, cat = "defensive"},

    -- PVP TRINKET
    [23273] = {cd = 300, name = "PvP Trinket",     class = nil, cat = "trinket"},
    [23274] = {cd = 300, name = "PvP Trinket",     class = nil, cat = "trinket"},
    [23451] = {cd = 300, name = "PvP Trinket",     class = nil, cat = "trinket"},
}

-- Reverse lookup: spellName → spellID (built at load time for combat log matching)
addon.SPELL_NAME_TO_IDS = {}
for id, data in pairs(addon.PVP_COOLDOWNS) do
    local name = data.name
    if not addon.SPELL_NAME_TO_IDS[name] then
        addon.SPELL_NAME_TO_IDS[name] = {}
    end
    table.insert(addon.SPELL_NAME_TO_IDS[name], id)
end

----------------------------------------------------------------
-- Diminishing returns categories
-- spellID → DR category string
----------------------------------------------------------------
addon.DR_CATEGORIES = {
    -- Stun
    [8647]  = "stun",  -- Cheap Shot
    [1833]  = "stun",  -- Cheap Shot
    [408]   = "stun",  -- Kidney Shot
    [10308] = "stun",  -- Hammer of Justice
    [853]   = "stun",  -- Hammer of Justice rank 1
    [5588]  = "stun",  -- Hammer of Justice rank 2
    [5589]  = "stun",  -- Hammer of Justice rank 3
    [5211]  = "stun",  -- Bash
    [6798]  = "stun",  -- Bash rank 2
    [8983]  = "stun",  -- Bash rank 3
    [20252] = "stun",  -- Intercept stun
    [20253] = "stun",  -- Intercept stun rank 2
    [19577] = "stun",  -- Intimidation
    [20549] = "stun",  -- War Stomp
    [12809] = "stun",  -- Concussion Blow
    [9005]  = "stun",  -- Pounce
    [9823]  = "stun",  -- Pounce rank 2
    [9827]  = "stun",  -- Pounce rank 3

    -- Fear
    [5782]  = "fear",  -- Fear
    [6213]  = "fear",  -- Fear rank 2
    [6215]  = "fear",  -- Fear rank 3
    [8122]  = "fear",  -- Psychic Scream
    [8124]  = "fear",  -- Psychic Scream rank 2
    [10888] = "fear",  -- Psychic Scream rank 3
    [10890] = "fear",  -- Psychic Scream rank 4
    [5484]  = "fear",  -- Howl of Terror
    [17928] = "fear",  -- Howl of Terror rank 2
    [5246]  = "fear",  -- Intimidating Shout

    -- Polymorph / Incapacitate (long)
    [118]   = "incapacitate_long", -- Polymorph
    [12824] = "incapacitate_long", -- Polymorph rank 2
    [12825] = "incapacitate_long", -- Polymorph rank 3
    [12826] = "incapacitate_long", -- Polymorph rank 4
    [20066] = "incapacitate_long", -- Repentance

    -- Incapacitate (short) / Disorient
    [2094]  = "incapacitate_short", -- Blind
    [1776]  = "incapacitate_short", -- Gouge
    [1777]  = "incapacitate_short", -- Gouge rank 2
    [8629]  = "incapacitate_short", -- Gouge rank 3
    [11285] = "incapacitate_short", -- Gouge rank 4
    [11286] = "incapacitate_short", -- Gouge rank 5
    [19503] = "disorient",          -- Scatter Shot

    -- Sap (own DR)
    [6770]  = "sap",  -- Sap
    [2070]  = "sap",  -- Sap rank 2
    [11297] = "sap",  -- Sap rank 3

    -- Root
    [339]   = "root",  -- Entangling Roots
    [1062]  = "root",  -- Entangling Roots rank 2
    [5195]  = "root",  -- Entangling Roots rank 3
    [5196]  = "root",  -- Entangling Roots rank 4
    [9852]  = "root",  -- Entangling Roots rank 5
    [9853]  = "root",  -- Entangling Roots rank 6
    [122]   = "root",  -- Frost Nova
    [865]   = "root",  -- Frost Nova rank 2
    [6131]  = "root",  -- Frost Nova rank 3
    [10230] = "root",  -- Frost Nova rank 4

    -- Silence
    [15487] = "silence", -- Silence (Priest)
    [18469] = "silence", -- Silenced - Counterspell
    [19647] = "silence", -- Spell Lock silence
    [18425] = "silence", -- Silenced - Kick

    -- Sleep
    [2637]  = "sleep",  -- Hibernate
    [18657] = "sleep",  -- Hibernate rank 2
    [18658] = "sleep",  -- Hibernate rank 3

    -- Horror
    [17926] = "horror", -- Death Coil
    [17925] = "horror", -- Death Coil rank 2
    [27223] = "horror", -- Death Coil rank 3
}

addon.DR_CATEGORY_NAMES = {
    stun                = "|cffff0000STUN|r",
    fear                = "|cff9900ccFEAR|r",
    incapacitate_long   = "|cff00ffffPOLY|r",
    incapacitate_short  = "|cffff9900INCAP|r",
    disorient           = "|cffff6600DISORIENT|r",
    sap                 = "|cffffff00SAP|r",
    root                = "|cff00ff00ROOT|r",
    silence             = "|cff6666ffSILENCE|r",
    sleep               = "|cff9999ffSLEEP|r",
    horror              = "|cff660099HORROR|r",
}
