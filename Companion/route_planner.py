"""
Route planner — Jev integration for strategic navigation decisions.

Periodically asks Jev higher-level questions about the current route:
which quest to prioritize, whether to vendor/repair, road vs shortcut, etc.
"""


def build_nav_questions(state):
    """
    Build Jev questions for navigation strategy.

    Called less frequently than combat decisions (~every 30s)
    because route planning doesn't need split-second updates.
    """
    questions = {}
    nav = state.get("nav", {})

    if not nav:
        return {}

    quest_count = nav.get("quest_count", 0)
    player_level = nav.get("player_level", 0)
    is_dead = nav.get("is_dead", False)
    dist = nav.get("dist_to_target", 0)
    target_type = nav.get("target_type", "none")
    in_combat = state.get("in_combat", False)

    if is_dead or in_combat:
        return {}

    # Should we stop for a gathering node?
    if target_type == "quest" and dist > 50:
        questions["gathering_detour"] = {
            "type": "noul",
            "instructions": (
                f"The player is navigating to a quest objective {dist:.0f} yards away. "
                "Should they stop to gather herbs/ore nodes they pass along the way, "
                "or press straight to the objective?"
            ),
            "criteria": {
                "true": (
                    "Gathering along the way is efficient — nodes give XP and "
                    "materials, and the detour is minor."
                ),
                "false": (
                    "Better to push straight to the quest — the objective is "
                    "close or the player should focus on quest completion."
                ),
            },
        }

    # Quest priority when multiple quests are available
    if quest_count > 1:
        questions["quest_priority"] = {
            "type": "choice",
            "instructions": (
                f"The player has {quest_count} active quests and is level {player_level}. "
                "What should they prioritize?"
            ),
            "criteria": {
                "nearest": "Go to the nearest quest objective first — minimize travel time.",
                "lowest_level": "Do the lowest-level quest first — it's easiest to complete.",
                "chain": "Continue the current quest chain — momentum and story flow matter.",
                "turn_in": "Head to town first — turn in any completed quests before starting new ones.",
            },
        }

    # Vendor trip decision
    if dist > 200 and not is_dead:
        questions["vendor_trip"] = {
            "type": "noul",
            "instructions": (
                "The next objective is far away. Should the player stop by a "
                "vendor to sell junk, repair gear, and restock supplies first?"
            ),
            "criteria": {
                "true": (
                    "Bags are likely getting full and gear may need repair. "
                    "A vendor stop now prevents mid-quest backtracking."
                ),
                "false": (
                    "The player should push to the objective. Vendor trips are "
                    "wasted time unless bags are actually full."
                ),
            },
        }

    return questions


def interpret_nav_decisions(answers, jev_client):
    """
    Interpret Jev's navigation answers into route adjustments.

    Returns a dict of route settings the navigator can use.
    """
    result = {
        "gather_along_way": True,  # default: gather if tracking is on
        "priority_mode": "nearest",
        "needs_vendor": False,
    }

    if not answers:
        return result

    # Gathering detour
    gather_prob = jev_client.get_noul(answers, "gathering_detour")
    result["gather_along_way"] = gather_prob > 0.5

    # Quest priority
    priority, conf = jev_client.get_choice(answers, "quest_priority")
    if priority and conf > 0.3:
        result["priority_mode"] = priority

    # Vendor trip
    vendor_prob = jev_client.get_noul(answers, "vendor_trip")
    result["needs_vendor"] = vendor_prob > 0.6

    return result


def format_route_summary(route_settings):
    """One-line summary of current route plan."""
    parts = [f"Priority: {route_settings['priority_mode']}"]
    if route_settings["gather_along_way"]:
        parts.append("gathering ON")
    if route_settings["needs_vendor"]:
        parts.append("VENDOR NEEDED")
    return " | ".join(parts)
