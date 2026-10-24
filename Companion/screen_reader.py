"""
Screen capture and pixel grid decoder.

Captures the StateEncoder pixel grid from the WoW window
and decodes it into structured game state.
"""

import mss
from PIL import Image
import math
from config import (
    PIXEL_GRID_X, PIXEL_GRID_Y, PIXEL_GRID_COLS, PIXEL_GRID_ROWS,
    PIXEL_SIZE, SYNC_R, SYNC_G, SYNC_B, CLASS_NAMES, ZONE_FLAGS,
    NAV_PIXEL_START, COORD_OFFSET, TARGET_TYPES,
)


def capture_grid():
    """Capture the pixel grid region from the screen."""
    width = PIXEL_GRID_COLS * PIXEL_SIZE
    height = PIXEL_GRID_ROWS * PIXEL_SIZE
    region = {
        "left": PIXEL_GRID_X,
        "top": PIXEL_GRID_Y,
        "width": width,
        "height": height,
    }
    with mss.mss() as sct:
        screenshot = sct.grab(region)
        return Image.frombytes("RGB", screenshot.size, screenshot.bgra, "raw", "BGRX")


def read_pixel(image, index):
    """Read RGB values from a pixel at the given grid index."""
    col = index % PIXEL_GRID_COLS
    row = index // PIXEL_GRID_COLS
    if row >= PIXEL_GRID_ROWS:
        return 0, 0, 0
    # Sample the center of each pixel cell
    x = col * PIXEL_SIZE + PIXEL_SIZE // 2
    y = row * PIXEL_SIZE + PIXEL_SIZE // 2
    if x >= image.width or y >= image.height:
        return 0, 0, 0
    return image.getpixel((x, y))


def verify_sync(image):
    """Check that the sync marker pixel is present."""
    r, g, b = read_pixel(image, 0)
    # Allow small tolerance for color compression artifacts
    return (abs(r - SYNC_R) <= 5
            and abs(g - SYNC_G) <= 5
            and abs(b - SYNC_B) <= 5)


def decode_state(image):
    """
    Decode the pixel grid into a structured game state dict.

    Returns None if the sync marker is missing.
    """
    if not verify_sync(image):
        return None

    state = {}

    # Pixel 1: Player health / power / flags
    r, g, b = read_pixel(image, 1)
    state["player_health_pct"] = round(r / 255 * 100, 1)
    state["player_power_pct"] = round(g / 255 * 100, 1)

    flags = b
    state["in_combat"] = bool(flags & 1)
    state["zone_type"] = "none"
    if flags & 2:
        state["zone_type"] = "battleground"
    elif flags & 4:
        state["zone_type"] = "arena"
    elif flags & 8:
        state["zone_type"] = "world_pvp"

    # Pixel 2: Player class, enemy count, stealth nearby
    r, g, b = read_pixel(image, 2)
    state["player_class"] = CLASS_NAMES.get(r, "Unknown")
    state["enemy_count"] = g
    state["stealth_nearby"] = bool(b)

    # Pixels 3+: Per-enemy data (3 pixels each, up to 5 enemies)
    enemies = []
    for i in range(min(state["enemy_count"], 5)):
        base = 3 + i * 3

        # Enemy pixel 1: health%, class, stealthed
        r1, g1, b1 = read_pixel(image, base)
        # Enemy pixel 2: distance, DR count, hasCDs
        r2, g2, b2 = read_pixel(image, base + 1)

        enemy = {
            "index": i,
            "health_pct": round(r1 / 255 * 100, 1),
            "class": CLASS_NAMES.get(g1, "Unknown"),
            "is_stealthed": bool(b1),
            "distance_yards": r2,
            "dr_count": g2,
            "has_cooldowns_active": bool(b2),
        }
        enemies.append(enemy)

    state["enemies"] = enemies

    # --- Navigation data (pixels 18-23) ---
    nav = {}

    # Pixel 18: Player X high, Player Y high, facing byte
    r18, g18, b18 = read_pixel(image, NAV_PIXEL_START)
    # Pixel 19: Player X low, Player Y low, player level
    r19, g19, b19 = read_pixel(image, NAV_PIXEL_START + 1)

    nav["player_x"] = (r18 * 256 + r19) - COORD_OFFSET
    nav["player_y"] = (g18 * 256 + g19) - COORD_OFFSET
    nav["facing"] = b18 / 255.0 * 2 * math.pi
    nav["player_level"] = b19

    # Pixel 20: Target X high, Target Y high, target type
    r20, g20, b20 = read_pixel(image, NAV_PIXEL_START + 2)
    # Pixel 21: Target X low, Target Y low, has_target
    r21, g21, b21 = read_pixel(image, NAV_PIXEL_START + 3)

    nav["target_x"] = (r20 * 256 + r21) - COORD_OFFSET
    nav["target_y"] = (g20 * 256 + g21) - COORD_OFFSET
    nav["target_type"] = TARGET_TYPES.get(b20, "unknown")
    nav["has_target"] = bool(b21)

    # Pixel 22: Movement flags, speed byte, quest count
    r22, g22, b22 = read_pixel(image, NAV_PIXEL_START + 4)
    nav["is_moving"] = bool(r22 & 1)
    nav["is_mounted"] = bool(r22 & 2)
    nav["is_dead"] = bool(r22 & 4)
    nav["is_indoors"] = bool(r22 & 8)
    nav["is_swimming"] = bool(r22 & 16)
    nav["is_flying"] = bool(r22 & 32)
    nav["speed_pct"] = round(g22 / 255.0 * 14, 1)  # yards/sec
    nav["quest_count"] = b22

    # Pixel 23: Distance high, distance low, map ID low
    r23, g23, b23 = read_pixel(image, NAV_PIXEL_START + 5)
    nav["dist_to_target"] = r23 * 256 + g23
    nav["map_id"] = b23

    state["nav"] = nav
    return state


def format_state_summary(state):
    """Format game state as a readable string for Jev's state input."""
    if not state:
        return "No game state available."

    lines = []
    lines.append(f"Player: {state['player_class']}, "
                 f"HP={state['player_health_pct']:.0f}%, "
                 f"Power={state['player_power_pct']:.0f}%")
    lines.append(f"Zone: {state['zone_type']}, "
                 f"In Combat: {state['in_combat']}")

    if state["stealth_nearby"]:
        lines.append("WARNING: Stealthed enemy nearby!")

    if not state["enemies"]:
        lines.append("No enemies detected.")
    else:
        lines.append(f"Enemies ({state['enemy_count']}):")
        for e in state["enemies"]:
            status = []
            if e["is_stealthed"]:
                status.append("STEALTHED")
            if e["has_cooldowns_active"]:
                status.append("CDs used")
            if e["dr_count"] > 0:
                status.append(f"DR x{e['dr_count']}")
            tag = f" [{', '.join(status)}]" if status else ""
            lines.append(f"  - {e['class']}: HP={e['health_pct']:.0f}%, "
                         f"Dist={e['distance_yards']}yd{tag}")

    # Navigation state
    nav = state.get("nav")
    if nav and nav.get("has_target"):
        ttype = nav.get("target_type", "unknown")
        dist = nav.get("dist_to_target", 0)
        lines.append(f"Nav: -> {ttype} ({dist:.0f}yd) | "
                     f"Pos: ({nav['player_x']:.0f}, {nav['player_y']:.0f}) "
                     f"Facing: {math.degrees(nav.get('facing', 0)):.0f}°")
        flags = []
        if nav.get("is_mounted"):
            flags.append("mounted")
        if nav.get("is_swimming"):
            flags.append("swimming")
        if nav.get("is_dead"):
            flags.append("DEAD")
        if flags:
            lines.append(f"  State: {', '.join(flags)}")
        lines.append(f"  Quests: {nav.get('quest_count', 0)} active, "
                     f"Level: {nav.get('player_level', 0)}")

    return "\n".join(lines)
