"""
PvP Awareness Companion — Jev-powered decision layer for WoW PvP.

Reads game state from the PvP Awareness addon's pixel encoder,
sends it to Jev for tactical decisions, and either advises
or executes the recommended actions.

Usage:
    set OPENROUTER_API_KEY=your_key_here
    python main.py              # Advisory mode (default)
    python main.py --execute    # Input execution mode (careful!)
    python main.py --navigate   # Navigation autopilot
    python main.py --debug      # Show raw state + skip Jev calls
"""

import sys
import time

from config import (
    CAPTURE_INTERVAL, DECISION_INTERVAL, OPENROUTER_API_KEY,
    NAV_CAPTURE_INTERVAL, NAV_DECISION_INTERVAL,
)
from screen_reader import capture_grid, decode_state, format_state_summary
from jev_client import JevClient
from decisions import build_questions, interpret_decisions
from executor import Executor
from navigator import Navigator
from route_planner import (
    build_nav_questions, interpret_nav_decisions, format_route_summary,
)


def print_header():
    print("=" * 50)
    print("  PvP Awareness Companion")
    print("  Jev Decision Layer for WoW PvP")
    print("=" * 50)
    print()


def check_config():
    if not OPENROUTER_API_KEY:
        print("[WARNING] OPENROUTER_API_KEY not set.")
        print("  Set it: export OPENROUTER_API_KEY=your_key")
        print("  Running in debug mode (no Jev calls).\n")
        return False
    print(f"[OK] API key loaded (ends ...{OPENROUTER_API_KEY[-4:]})")
    return True


def capture_state(interval):
    """Capture screen and decode state, handling sync loss. Returns (state, no_sync_count_delta)."""
    try:
        image = capture_grid()
        return decode_state(image), 0
    except Exception as e:
        print(f"[Capture error] {e}")
        time.sleep(1)
        return None, 0


class SyncTracker:
    """Tracks consecutive sync failures and prints warnings."""

    def __init__(self):
        self.count = 0

    def lost(self, interval):
        self.count += 1
        if self.count == 30:
            print("[WARNING] No sync marker found. "
                  "Is WoW running with PvP Awareness loaded?")
        if self.count % 100 == 0:
            print(".", end="", flush=True)
        time.sleep(interval)

    def recovered(self):
        if self.count > 0:
            print("\n[OK] Sync marker found! Reading game state.")
            self.count = 0


def run_pvp_mode(debug_mode, execute_mode, has_key):
    """Original PvP decision loop."""
    jev = JevClient() if has_key else None
    executor = Executor(execute=execute_mode)
    sync = SyncTracker()

    last_decision_time = 0

    print("Waiting for WoW pixel grid...")

    while True:
        loop_start = time.time()

        state, _ = capture_state(CAPTURE_INTERVAL)

        if state is None:
            sync.lost(CAPTURE_INTERVAL)
            continue
        sync.recovered()

        now = time.time()

        if debug_mode:
            summary = format_state_summary(state)
            print(f"\n[{time.strftime('%H:%M:%S')}] {summary}")
            time.sleep(0.5)
            continue

        if jev and (now - last_decision_time) >= DECISION_INTERVAL:
            last_decision_time = now

            questions = build_questions(state)
            if questions:
                state_text = format_state_summary(state)
                answers = jev.decide(state_text, questions)

                if answers:
                    actions = interpret_decisions(answers, jev)
                    executor.process_actions(actions)

                    if jev.last_cost > 0:
                        print(f"  [cost: ${jev.last_cost:.6f}]")
                else:
                    print(f"[{time.strftime('%H:%M:%S')}] "
                          "Jev returned no answers.")

        elapsed = time.time() - loop_start
        sleep_time = max(0, CAPTURE_INTERVAL - elapsed)
        time.sleep(sleep_time)


def run_navigate_mode(execute_mode, has_key):
    """Navigation autopilot loop."""
    jev = JevClient() if has_key else None
    executor = Executor(execute=execute_mode)
    nav = Navigator(executor)
    nav.start()
    sync = SyncTracker()

    last_route_decision = 0
    last_status_print = 0
    route_settings = {
        "gather_along_way": True,
        "priority_mode": "nearest",
        "needs_vendor": False,
    }

    print("Waiting for WoW pixel grid...")

    while True:
        loop_start = time.time()

        state, _ = capture_state(NAV_CAPTURE_INTERVAL)

        if state is None:
            sync.lost(NAV_CAPTURE_INTERVAL)
            continue
        sync.recovered()

        nav_state = state.get("nav", {})
        now = time.time()

        # Pause navigation during combat
        if state.get("in_combat"):
            if nav.active:
                print("[Nav] In combat — pausing autopilot")
                nav.stop()
        elif not nav.active:
            print("[Nav] Combat over — resuming autopilot")
            nav.start()

        # Steering tick
        nav.update(nav_state)

        # Periodic status line
        if now - last_status_print > 3.0:
            last_status_print = now
            status = nav.format_status(nav_state)
            route_info = format_route_summary(route_settings)
            print(f"[{time.strftime('%H:%M:%S')}] {status} | {route_info}")

        # Jev route planning (infrequent)
        if jev and (now - last_route_decision) >= NAV_DECISION_INTERVAL:
            last_route_decision = now
            questions = build_nav_questions(state)
            if questions:
                state_text = format_state_summary(state)
                answers = jev.decide(state_text, questions)
                if answers:
                    route_settings = interpret_nav_decisions(answers, jev)
                    print(f"  [Route] {format_route_summary(route_settings)}")
                    if jev.last_cost > 0:
                        print(f"  [cost: ${jev.last_cost:.6f}]")

        elapsed = time.time() - loop_start
        sleep_time = max(0, NAV_CAPTURE_INTERVAL - elapsed)
        time.sleep(sleep_time)


def main():
    print_header()

    debug_mode = "--debug" in sys.argv
    execute_mode = "--execute" in sys.argv
    navigate_mode = "--navigate" in sys.argv

    has_key = check_config()
    if debug_mode:
        has_key = False
        print("[MODE] Debug — showing state, skipping Jev.\n")

    if navigate_mode:
        if execute_mode:
            print("[MODE] NAVIGATE + EXECUTE — autopilot will steer the character!")
        else:
            print("[MODE] NAVIGATE advisory — showing steering recommendations.\n")
    elif execute_mode:
        print("[MODE] EXECUTE — inputs will be injected into the game!")
    else:
        print("[MODE] Advisory — showing recommendations only.\n")

    print("Press Ctrl+C to stop.\n")

    try:
        if navigate_mode:
            run_navigate_mode(execute_mode, has_key)
        else:
            run_pvp_mode(debug_mode, execute_mode, has_key)

    except KeyboardInterrupt:
        print("\n\nStopping companion app.")
        print("Goodbye.")


if __name__ == "__main__":
    main()
