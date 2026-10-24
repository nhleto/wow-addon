"""
Jev Decisions API client via OpenRouter.

Sends structured game state and PvP decision questions,
returns typed answers with probabilities.
"""

import requests
from config import OPENROUTER_API_KEY, OPENROUTER_DECISIONS_URL, JEV_MODEL


class JevClient:
    def __init__(self, api_key=None, model=None):
        self.api_key = api_key or OPENROUTER_API_KEY
        self.model = model or JEV_MODEL
        self.session = requests.Session()
        self.session.headers.update({
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
        })
        self.last_cost = 0.0

    def decide(self, state, questions):
        """
        Send a decisions request to Jev.

        Args:
            state: Game state as a string or dict.
            questions: Dict of question_id -> question definition.
                       Each question has 'type', 'instructions', 'criteria'.

        Returns:
            Dict of question_id -> answer, or None on error.
        """
        if not self.api_key:
            return None

        payload = {
            "model": self.model,
            "state": state,
            "questions": questions,
        }

        try:
            resp = self.session.post(
                OPENROUTER_DECISIONS_URL,
                json=payload,
                timeout=5,
            )
            resp.raise_for_status()
            data = resp.json()

            if "usage" in data and "cost" in data["usage"]:
                self.last_cost = data["usage"]["cost"]

            return data.get("answers", {})

        except requests.exceptions.Timeout:
            print("[Jev] Request timed out")
            return None
        except requests.exceptions.RequestException as e:
            print(f"[Jev] Request error: {e}")
            return None
        except (ValueError, KeyError) as e:
            print(f"[Jev] Response parse error: {e}")
            return None

    def get_choice(self, answers, question_id):
        """Extract a choice answer."""
        ans = answers.get(question_id)
        if not ans or ans.get("type") != "choice":
            return None, 0.0
        choice = ans.get("choice")
        confidence = ans.get("confidence", 0.0)
        return choice, confidence

    def get_noul(self, answers, question_id):
        """Extract a noul (yes probability) answer."""
        ans = answers.get(question_id)
        if not ans or ans.get("type") != "noul":
            return 0.0
        return ans.get("noul", 0.0)

    def get_score(self, answers, question_id):
        """Extract a score answer."""
        ans = answers.get(question_id)
        if not ans or ans.get("type") != "score":
            return 0.0, {}
        score = ans.get("score", 0.0)
        probs = ans.get("probabilities", {})
        return score, probs
