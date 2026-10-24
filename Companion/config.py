import os

# OpenRouter API
OPENROUTER_API_KEY = os.environ.get("OPENROUTER_API_KEY", "")
OPENROUTER_DECISIONS_URL = "https://openrouter.ai/api/alpha/decisions"
JEV_MODEL = "typesafe/jev-1.13"

# Screen capture region for the pixel grid (must match StateEncoder.lua)
PIXEL_GRID_X = 0
PIXEL_GRID_Y = 0
PIXEL_GRID_COLS = 20
PIXEL_GRID_ROWS = 5
PIXEL_SIZE = 3

# Sync marker bytes (must match StateEncoder.lua)
SYNC_R = 0xDE
SYNC_G = 0xAD
SYNC_B = 0x01

# Timing
CAPTURE_INTERVAL = 0.1      # 10 Hz screen reads
DECISION_INTERVAL = 2.0     # Jev calls every 2 seconds
INPUT_TICK = 0.05            # 20 Hz executor tick

# Class index mapping (must match StateEncoder.lua)
CLASS_NAMES = {
    0: "Unknown",
    1: "Warrior",
    2: "Paladin",
    3: "Hunter",
    4: "Rogue",
    5: "Priest",
    6: "Shaman",
    7: "Mage",
    8: "Warlock",
    9: "Druid",
}

# Zone flags from pixel encoding
ZONE_FLAGS = {
    1: "in_combat",
    2: "battleground",
    4: "arena",
    8: "world_pvp",
}

# Navigation pixel layout (must match StateEncoder.lua)
NAV_PIXEL_START = 18
COORD_OFFSET = 32768

# Navigation tuning
NAV_CAPTURE_INTERVAL = 0.15    # ~7 Hz nav reads
NAV_DECISION_INTERVAL = 30.0   # Jev route decisions every 30s
NAV_ARRIVE_DIST = 8.0          # Yards — close enough to target
NAV_FACING_DEADZONE = 0.08     # Radians — stop turning within this

# Movement speed constants (yards/sec)
BASE_RUN_SPEED = 7.0
MOUNT_SPEED_MULT = 1.6         # 60% mount

# Target type names (must match QuestNavigator.lua)
TARGET_TYPES = {
    0: "none",
    1: "quest",
    2: "herb",
    3: "ore",
    4: "vendor",
    5: "mailbox",
    6: "waypoint",
}

# Keybinds for the executor (customize per player setup)
KEYBINDS = {
    "trinket": "f",
    "kick": "e",
    "primary_burst": "1",
    "defensive": "2",
    "cc": "3",
    "mobility": "4",
    "move_forward": "w",
    "move_backward": "s",
    "turn_left": "a",
    "turn_right": "d",
    "interact": "numpad5",
    "jump": "space",
}
