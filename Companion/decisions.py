"""
PvP decision definitions for Jev.

Builds the questions dict from current game state
so Jev can make tactical decisions.
"""


def build_questions(state):
    """
    Build Jev decision questions based on current game state.

    Returns a dict of question_id -> question definition,
    tailored to what's happening right now.
    """
    questions = {}
    enemies = state.get("enemies", [])
    in_combat = state.get("in_combat", False)
    player_hp = state.get("player_health_pct", 100)
    zone = state.get("zone_type", "none")

    if zone == "none":
        return {}

    # --- Target priority (always relevant when enemies exist) ---
    if len(enemies) > 1:
        target_criteria = {}
        for e in enemies:
            label = f"enemy_{e['index']}_{e['class'].lower()}"
            desc_parts = [f"{e['class']} at {e['health_pct']:.0f}% HP"]
            desc_parts.append(f"{e['distance_yards']} yards away")
            if e["is_stealthed"]:
                desc_parts.append("currently stealthed")
            if e["has_cooldowns_active"]:
                desc_parts.append("major cooldowns on CD")
            if e["dr_count"] > 0:
                desc_parts.append(f"DR stacks: {e['dr_count']}")
            target_criteria[label] = ". ".join(desc_parts) + "."

        questions["focus_target"] = {
            "type": "choice",
            "instructions": (
                "Which enemy should the player focus damage on? "
                "Consider health, class vulnerability, cooldown state, "
                "and diminishing returns. Healers and low-HP targets "
                "are generally higher priority."
            ),
            "criteria": target_criteria,
        }

    # --- Engage or disengage ---
    if in_combat and enemies:
        questions["engagement"] = {
            "type": "choice",
            "instructions": (
                "What should the player do right now? "
                "Consider player health, enemy count, and cooldown states."
            ),
            "criteria": {
                "all_in": "Commit fully — use burst cooldowns and go for the kill.",
                "sustain": "Play steady — deal damage but conserve cooldowns.",
                "kite": "Create distance — use movement abilities and crowd control.",
                "defensive": "Go defensive — use defensive cooldowns, heal, pillar.",
                "retreat": "Disengage fully — escape combat and reset.",
            },
        }

    # --- Trinket usage ---
    if in_combat:
        questions["use_trinket"] = {
            "type": "noul",
            "instructions": (
                "Should the player use their PvP trinket (CC break) right now? "
                "Trinket has a 2 minute cooldown. "
                "It should be saved for critical CC chains (stuns into kills) "
                "and not wasted on short or non-threatening CC."
            ),
            "criteria": {
                "true": (
                    "The player is in dangerous CC that will lead to death "
                    "or a major disadvantage if not broken immediately."
                ),
                "false": (
                    "The CC is short, the player is safe, or trinket should "
                    "be saved for a more dangerous situation."
                ),
            },
        }

    # --- Defensive urgency ---
    if in_combat and player_hp < 60:
        questions["defensive_urgency"] = {
            "type": "score",
            "instructions": (
                f"The player is at {player_hp:.0f}% health. "
                "How urgently do they need to use a defensive cooldown?"
            ),
            "criteria": [
                "Safe — health will recover naturally, no pressure.",
                "Moderate — some pressure, might need a defensive soon.",
                "Urgent — use a defensive cooldown now or risk dying.",
            ],
        }

    # --- Burst window detection ---
    if in_combat and enemies:
        lowest_hp_enemy = min(enemies, key=lambda e: e["health_pct"])
        if lowest_hp_enemy["health_pct"] < 50:
            questions["burst_window"] = {
                "type": "noul",
                "instructions": (
                    f"Enemy {lowest_hp_enemy['class']} is at "
                    f"{lowest_hp_enemy['health_pct']:.0f}% HP. "
                    "Is this a good time to use burst cooldowns for a kill attempt?"
                ),
                "criteria": {
                    "true": (
                        "The enemy is low, their defensives are on cooldown, "
                        "and a burst window is open."
                    ),
                    "false": (
                        "The enemy still has defensive cooldowns available, "
                        "or the player should wait for a better setup."
                    ),
                },
            }

    # --- Stealth response ---
    if state.get("stealth_nearby"):
        questions["stealth_response"] = {
            "type": "choice",
            "instructions": (
                "A stealthed enemy is nearby. What should the player do?"
            ),
            "criteria": {
                "aoe_reveal": "Use AoE abilities to break stealth.",
                "pre_defensive": "Pre-use a defensive cooldown before the opener.",
                "reposition": "Move to a safer position near allies or pillars.",
                "bait": "Stay put and prepare a counter-attack for when they open.",
            },
        }

    return questions


def interpret_decisions(answers, jev_client):
    """
    Interpret Jev's answers into actionable recommendations.

    Returns a list of (priority, action_type, description) tuples.
    """
    actions = []

    if not answers:
        return actions

    # Focus target
    target, conf = jev_client.get_choice(answers, "focus_target")
    if target and conf > 0.4:
        actions.append((1, "target", f"Focus: {target} (confidence: {conf:.0%})"))

    # Engagement posture
    engagement, conf = jev_client.get_choice(answers, "engagement")
    if engagement:
        actions.append((2, "posture", f"Play: {engagement} ({conf:.0%})"))

    # Trinket
    trinket_prob = jev_client.get_noul(answers, "use_trinket")
    if trinket_prob > 0.7:
        actions.append((0, "trinket", f"USE TRINKET NOW ({trinket_prob:.0%})"))

    # Defensive urgency
    score, probs = jev_client.get_score(answers, "defensive_urgency")
    if score >= 1.5:
        actions.append((0, "defensive", f"DEFENSIVE NOW (urgency: {score:.1f}/2)"))
    elif score >= 0.8:
        actions.append((3, "defensive", f"Consider defensive (urgency: {score:.1f}/2)"))

    # Burst window
    burst_prob = jev_client.get_noul(answers, "burst_window")
    if burst_prob > 0.6:
        actions.append((1, "burst", f"BURST WINDOW — go for kill ({burst_prob:.0%})"))

    # Stealth response
    stealth, conf = jev_client.get_choice(answers, "stealth_response")
    if stealth and conf > 0.3:
        actions.append((1, "stealth", f"Stealth counter: {stealth} ({conf:.0%})"))

    actions.sort(key=lambda a: a[0])
    return actions
