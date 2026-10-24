"""
Navigation autopilot — PID-style steering controller.

Compares player facing to target bearing and issues movement
inputs (W for forward, A/D for turning) with humanized timing.
Handles obstacle avoidance via stuck detection and random unstick maneuvers.
"""

import math
import time
import random

from config import KEYBINDS, NAV_ARRIVE_DIST, NAV_FACING_DEADZONE
from executor import Executor, gauss_clamp

_pdi = None

def _get_pdi():
    global _pdi
    if _pdi is None:
        try:
            import pydirectinput
            _pdi = pydirectinput
        except ImportError:
            pass
    return _pdi


def normalize_angle(a):
    """Normalize angle to [-PI, PI]."""
    while a > math.pi:
        a -= 2 * math.pi
    while a < -math.pi:
        a += 2 * math.pi
    return a


class StuckDetector:
    """Detects when the player isn't making progress toward the target."""

    def __init__(self):
        self.last_x = None
        self.last_y = None
        self.last_check = 0
        self.stuck_count = 0
        self.check_interval = 2.0
        self.min_move_dist = 3.0

    def update(self, px, py):
        now = time.time()
        if now - self.last_check < self.check_interval:
            return False

        self.last_check = now
        is_stuck = False

        if self.last_x is not None:
            dx = px - self.last_x
            dy = py - self.last_y
            moved = math.sqrt(dx * dx + dy * dy)
            if moved < self.min_move_dist:
                self.stuck_count += 1
                is_stuck = self.stuck_count >= 2
            else:
                self.stuck_count = 0

        self.last_x = px
        self.last_y = py
        return is_stuck

    def reset(self):
        self.stuck_count = 0
        self.last_x = None
        self.last_y = None


class Navigator:
    """
    Steers the character toward the current navigation target.

    Uses bearing comparison: if the target is to the right of where
    the player faces, press D to turn right (and vice versa).
    Always holds W to move forward while navigating.
    """

    def __init__(self, executor: Executor):
        self.executor = executor
        self.stuck = StuckDetector()
        self.active = False
        self.last_nav_time = 0
        self.nav_tick_rate = 0.15

        self._forward_held = False
        self._turn_held = None  # "left" or "right" or None
        self._unstick_until = 0

    def start(self):
        self.active = True
        self.stuck.reset()
        print("[Nav] Autopilot engaged.")

    def stop(self):
        self.active = False
        self._release_all()
        self.stuck.reset()
        print("[Nav] Autopilot disengaged.")

    def _release_all(self):
        """Release all movement keys."""
        if not self.executor.execute:
            return
        pdi = _get_pdi()
        if pdi:
            for key in ("move_forward", "move_backward", "turn_left", "turn_right"):
                bind = KEYBINDS.get(key)
                if bind:
                    pdi.keyUp(bind)
        self._forward_held = False
        self._turn_held = None

    def _hold_key(self, action):
        """Hold a movement key down."""
        if not self.executor.execute:
            return
        bind = KEYBINDS.get(action)
        if not bind:
            return
        pdi = _get_pdi()
        if pdi:
            pdi.keyDown(bind)

    def _release_key(self, action):
        """Release a movement key."""
        if not self.executor.execute:
            return
        bind = KEYBINDS.get(action)
        if not bind:
            return
        pdi = _get_pdi()
        if pdi:
            pdi.keyUp(bind)

    def _do_unstick(self):
        """Random maneuver to get unstuck: back up, turn randomly, jump."""
        if not self.executor.execute:
            print("  [Nav] STUCK — would unstick (advisory mode)")
            return

        self._release_all()

        # Back up briefly
        self._hold_key("move_backward")
        time.sleep(gauss_clamp(0.8, 0.2, 0.5, 1.2))
        self._release_key("move_backward")

        # Random turn
        turn = random.choice(["turn_left", "turn_right"])
        self._hold_key(turn)
        time.sleep(gauss_clamp(0.6, 0.2, 0.3, 1.0))
        self._release_key(turn)

        # Jump
        self.executor.press_key(KEYBINDS.get("jump", "space"))

        self._unstick_until = time.time() + gauss_clamp(1.5, 0.3, 1.0, 2.5)

    def update(self, nav_state):
        """
        Called each tick with the decoded nav state dict.
        Steers the character toward the target.
        """
        if not self.active:
            return

        now = time.time()
        if now - self.last_nav_time < self.nav_tick_rate:
            return
        self.last_nav_time = now

        if not nav_state or not nav_state.get("has_target"):
            self._release_all()
            return

        if nav_state.get("is_dead"):
            self._release_all()
            return

        # Still in unstick cooldown
        if now < self._unstick_until:
            return

        px = nav_state["player_x"]
        py = nav_state["player_y"]
        tx = nav_state["target_x"]
        ty = nav_state["target_y"]
        facing = nav_state["facing"]
        dist = nav_state.get("dist_to_target", 0)

        # Check arrival
        if dist > 0 and dist < NAV_ARRIVE_DIST:
            self._release_all()
            print(f"  [Nav] Arrived at target ({dist:.0f} yards)")
            return

        # Stuck detection
        if nav_state.get("is_moving") and self.stuck.update(px, py):
            print("  [Nav] Stuck detected — attempting unstick maneuver")
            self._do_unstick()
            self.stuck.reset()
            return

        # Calculate bearing to target
        dx = tx - px
        dy = ty - py
        bearing = math.atan2(dx, dy)  # radians from north, CW positive
        angle_diff = normalize_angle(bearing - facing)

        # Advisory output
        if not self.executor.execute:
            dir_str = "LEFT" if angle_diff < 0 else "RIGHT"
            print(f"  [Nav] Bearing: {math.degrees(bearing):.0f}° "
                  f"Facing: {math.degrees(facing):.0f}° "
                  f"Turn: {math.degrees(abs(angle_diff)):.0f}° {dir_str} "
                  f"Dist: {dist:.0f}yd")

        # Steering: turn toward target
        if abs(angle_diff) > NAV_FACING_DEADZONE:
            if angle_diff > 0:
                # Need to turn right
                if self._turn_held != "right":
                    if self._turn_held == "left":
                        self._release_key("turn_left")
                    self._hold_key("turn_right")
                    self._turn_held = "right"
            else:
                # Need to turn left
                if self._turn_held != "left":
                    if self._turn_held == "right":
                        self._release_key("turn_right")
                    self._hold_key("turn_left")
                    self._turn_held = "left"
        else:
            # Facing close enough — stop turning
            if self._turn_held:
                self._release_key("turn_left" if self._turn_held == "left" else "turn_right")
                self._turn_held = None

        # Always move forward when we have a target
        if not self._forward_held:
            self._hold_key("move_forward")
            self._forward_held = True

        # Jump occasionally for terrain obstacles
        if random.random() < 0.02:
            self.executor.press_key(KEYBINDS.get("jump", "space"))

    def format_status(self, nav_state):
        """One-line nav status for the console."""
        if not nav_state or not nav_state.get("has_target"):
            return "[Nav] No target"

        ttype = nav_state.get("target_type", "unknown")
        dist = nav_state.get("dist_to_target", 0)
        mounted = " (mounted)" if nav_state.get("is_mounted") else ""
        dead = " DEAD" if nav_state.get("is_dead") else ""
        swimming = " swimming" if nav_state.get("is_swimming") else ""

        return (f"[Nav] -> {ttype} | {dist:.0f}yd"
                f"{mounted}{swimming}{dead}")
