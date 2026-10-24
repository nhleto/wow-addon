"""
Input executor — translates Jev decisions into game inputs.

Uses pydirectinput for DirectInput-compatible key injection
that WoW's input system will accept.

Input humanization:
- Gaussian-distributed reaction delays (not uniform random)
- Variable key hold times modeled on real keystroke dynamics
- Per-session baseline drift (simulates fatigue / focus shifts)
- Occasional skipped inputs (humans miss keys)
- Inter-action micro-delays that vary naturally

IMPORTANT: This module is disabled by default. Pass --execute
to main.py to enable actual key injection. In advisory mode,
it only prints recommendations to the console.
"""

import time
import random
import math

try:
    import pydirectinput
    HAS_DIRECTINPUT = True
except ImportError:
    HAS_DIRECTINPUT = False

from config import KEYBINDS


def gauss_clamp(mean, stddev, low, high):
    """Gaussian random clamped to [low, high]."""
    return max(low, min(high, random.gauss(mean, stddev)))


class HumanProfile:
    """
    Models a human player's input characteristics.

    Reaction times, key hold durations, and error rates are drawn
    from distributions based on real typing/gaming studies.
    Baseline drifts over time to simulate fatigue.
    """

    def __init__(self):
        # Base reaction speed (ms) — varies per "player"
        self.base_reaction_ms = gauss_clamp(220, 40, 150, 350)

        # How much reaction time varies moment to moment
        self.reaction_jitter_ms = gauss_clamp(60, 15, 30, 120)

        # Key hold duration profile (ms)
        self.hold_mean_ms = gauss_clamp(85, 20, 50, 140)
        self.hold_stddev_ms = gauss_clamp(25, 8, 10, 50)

        # Probability of "missing" an input (fat finger, distraction)
        self.miss_rate = gauss_clamp(0.03, 0.015, 0.0, 0.08)

        # Probability of a double-tap (pressing too fast, key bounces)
        self.double_tap_rate = gauss_clamp(0.01, 0.005, 0.0, 0.03)

        # Fatigue: reaction time drifts upward over the session
        self.session_start = time.time()
        self.fatigue_rate_ms_per_hour = gauss_clamp(15, 8, 0, 40)

        # Micro-pause: occasional longer hesitation between actions
        self.micro_pause_rate = gauss_clamp(0.08, 0.03, 0.02, 0.15)
        self.micro_pause_ms = gauss_clamp(400, 150, 150, 800)

    def get_reaction_delay(self):
        """Reaction time in seconds, including fatigue drift."""
        hours = (time.time() - self.session_start) / 3600
        fatigue = self.fatigue_rate_ms_per_hour * hours
        base = self.base_reaction_ms + fatigue
        delay_ms = gauss_clamp(base, self.reaction_jitter_ms, 80, 600)
        return delay_ms / 1000.0

    def get_hold_time(self):
        """Key hold duration in seconds."""
        hold_ms = gauss_clamp(self.hold_mean_ms, self.hold_stddev_ms, 30, 250)
        return hold_ms / 1000.0

    def should_miss(self):
        """Whether to skip this input (simulates human error)."""
        return random.random() < self.miss_rate

    def should_double_tap(self):
        """Whether to press the key twice (accidental double-press)."""
        return random.random() < self.double_tap_rate

    def get_inter_action_delay(self):
        """Delay between consecutive actions in a batch."""
        if random.random() < self.micro_pause_rate:
            pause_ms = gauss_clamp(
                self.micro_pause_ms, self.micro_pause_ms * 0.3, 100, 1500
            )
            return pause_ms / 1000.0
        # Normal inter-action gap
        gap_ms = gauss_clamp(120, 40, 50, 300)
        return gap_ms / 1000.0


class Executor:
    def __init__(self, execute=False):
        self.execute = execute and HAS_DIRECTINPUT
        self.last_actions = {}
        self.cooldowns = {}
        self.human = HumanProfile()
        self.action_count = 0
        if self.execute:
            pydirectinput.PAUSE = 0.0  # We handle all timing ourselves

    def can_execute(self, action_type):
        """Check if an action is off cooldown."""
        now = time.time()
        cd = self.cooldowns.get(action_type, 0)
        return now >= cd

    def set_cooldown(self, action_type, duration):
        """Put an action type on cooldown with slight jitter."""
        jitter = gauss_clamp(0, 0.3, -0.5, 0.5)
        self.cooldowns[action_type] = time.time() + duration + jitter

    def press_key(self, key):
        """Press a key with humanized hold time."""
        if not self.execute or not HAS_DIRECTINPUT:
            return False

        hold = self.human.get_hold_time()

        try:
            pydirectinput.keyDown(key)
            time.sleep(hold)
            pydirectinput.keyUp(key)

            # Rare double-tap
            if self.human.should_double_tap():
                gap = gauss_clamp(30, 10, 15, 60) / 1000.0
                time.sleep(gap)
                hold2 = self.human.get_hold_time() * 0.7
                pydirectinput.keyDown(key)
                time.sleep(hold2)
                pydirectinput.keyUp(key)

            return True
        except Exception as e:
            print(f"[Executor] Key press error: {e}")
            return False

    def execute_action(self, action_type, description):
        """
        Execute or recommend an action.

        In advisory mode (default), prints the recommendation.
        In execute mode, waits a humanized reaction delay
        then presses the keybind.
        """
        prefix = "[EXEC]" if self.execute else "[ADVISE]"
        print(f"  {prefix} {description}")

        if not self.execute:
            return

        if not self.can_execute(action_type):
            return

        # Simulate human miss
        if self.human.should_miss():
            print(f"  [MISS] (simulated input miss)")
            return

        keybind = KEYBINDS.get(action_type)
        if not keybind:
            return

        # Humanized reaction delay
        delay = self.human.get_reaction_delay()
        time.sleep(delay)

        if action_type == "trinket":
            if self.press_key(keybind):
                self.set_cooldown("trinket", 120)

        elif action_type == "defensive":
            if self.press_key(keybind):
                self.set_cooldown("defensive", 2)

        elif action_type == "burst":
            if self.press_key(keybind):
                self.set_cooldown("burst", 3)

        self.action_count += 1

    def process_actions(self, actions):
        """
        Process a list of action recommendations from the decision engine.

        Args:
            actions: list of (priority, action_type, description) tuples
        """
        if not actions:
            return

        print("\n--- Jev Decisions ---")
        for i, (priority, action_type, description) in enumerate(actions):
            self.execute_action(action_type, description)

            # Inter-action delay between consecutive inputs
            if self.execute and i < len(actions) - 1:
                gap = self.human.get_inter_action_delay()
                time.sleep(gap)

        print("--------------------")

        # Periodically log humanization stats
        if self.execute and self.action_count % 20 == 0 and self.action_count > 0:
            hours = (time.time() - self.human.session_start) / 3600
            fatigue = self.human.fatigue_rate_ms_per_hour * hours
            print(f"  [Human profile] base={self.human.base_reaction_ms:.0f}ms "
                  f"fatigue=+{fatigue:.0f}ms "
                  f"actions={self.action_count}")
