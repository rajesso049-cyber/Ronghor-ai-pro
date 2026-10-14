"""Run with:  python -m unittest test_ai   (no network or API keys needed)."""
import sys
import types
import unittest
from datetime import datetime, timezone

import ai


class Block:
    def __init__(self, type_, text=""):
        self.type, self.text = type_, text


class Resp:
    def __init__(self, blocks, stop="end_turn"):
        self.content, self.stop_reason = blocks, stop


def install_fake_anthropic(responses, calls):
    mod = types.ModuleType("anthropic")

    class Messages:
        def create(self, **kw):
            calls.append(kw)
            return responses.pop(0)

    class Anthropic:
        def __init__(self, **kw):
            self.messages = Messages()

    mod.Anthropic = Anthropic
    sys.modules["anthropic"] = mod


class ProviderTests(unittest.TestCase):
    def test_choose(self):
        self.assertEqual(ai.choose_provider({"ANTHROPIC_API_KEY": "k"}), "anthropic")
        self.assertEqual(ai.choose_provider({"OPENAI_API_KEY": "k"}), "openai")
        self.assertEqual(ai.choose_provider({"ANTHROPIC_API_KEY": "a", "OPENAI_API_KEY": "o"}), "anthropic")
        self.assertEqual(
            ai.choose_provider({"ANTHROPIC_API_KEY": "a", "OPENAI_API_KEY": "o", "AI_PROVIDER": "openai"}), "openai"
        )
        with self.assertRaises(ai.ConfigError):
            ai.choose_provider({})
        with self.assertRaises(ai.ConfigError):
            ai.choose_provider({"AI_PROVIDER": "openai", "ANTHROPIC_API_KEY": "a"})
        with self.assertRaises(ai.ConfigError):
            ai.choose_provider({"AI_PROVIDER": "bogus", "ANTHROPIC_API_KEY": "a"})

    def test_models(self):
        self.assertEqual(ai.resolve_model("anthropic", {}), "claude-sonnet-5-5")
        self.assertEqual(ai.resolve_model("anthropic", {"ANTHROPIC_MODEL": "claude-haiku-5-5"}), "claude-haiku-5-5")
        with self.assertRaises(ai.ConfigError):
            ai.resolve_model("openai", {})

    def test_describe_config_never_leaks_keys(self):
        d = ai.describe_config({"ANTHROPIC_API_KEY": "sk-secret"})
        self.assertTrue(d["ai_configured"])
        self.assertNotIn("sk-secret", str(d))
        self.assertFalse(ai.describe_config({})["ai_configured"])


class MergeTests(unittest.TestCase):
    def test_drops_leading_assistant_and_merges(self):
        hist = [
            {"role": "assistant", "content": "Hello!"},
            {"role": "user", "content": "hi"},
            {"role": "user", "content": "are you there"},
            {"role": "assistant", "content": "yes"},
        ]
        turns = ai.merge_turns(hist, "ok thanks")
        self.assertEqual([t["role"] for t in turns], ["user", "assistant", "user"])
        self.assertEqual(turns[0]["content"], "hi\n\nare you there")
        self.assertEqual(turns[-1]["content"], "ok thanks")

    def test_only_message(self):
        self.assertEqual(ai.merge_turns([], " yo "), [{"role": "user", "content": "yo"}])

    def test_blank_message_rejected(self):
        with self.assertRaises(ValueError):
            ai.merge_turns([{"role": "user", "content": "a"}, {"role": "assistant", "content": "b"}], "   ")


class AnthropicTests(unittest.TestCase):
    ENV = {"ANTHROPIC_API_KEY": "k"}

    def test_plain_answer_no_tools(self):
        calls = []
        install_fake_anthropic([Resp([Block("text", "Hi there")])], calls)
        out = ai.generate_answer([], "hello", False, self.ENV)
        self.assertEqual(out, "Hi there")
        self.assertNotIn("tools", calls[0])
        self.assertEqual(calls[0]["model"], "claude-sonnet-5-5")
        self.assertIn("Ronghor AI", calls[0]["system"])
        self.assertEqual(calls[0]["messages"], [{"role": "user", "content": "hello"}])

    def test_web_search_joins_blocks_and_resumes_pause(self):
        calls = []
        r1 = Resp([Block("text", "Let me check. "), Block("server_tool_use")], stop="pause_turn")
        r2 = Resp([Block("web_search_tool_result"), Block("text", "It is "), Block("text", "sunny.")])
        install_fake_anthropic([r1, r2], calls)
        out = ai.generate_answer([], "weather?", True, self.ENV)
        self.assertEqual(out, "Let me check. It is sunny.")
        self.assertEqual(calls[0]["tools"][0]["type"], "web_search_20250305")
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[1]["messages"][-1]["role"], "assistant")

    def test_empty_reply_fallback(self):
        install_fake_anthropic([Resp([])], [])
        self.assertIn("couldn't produce", ai.generate_answer([], "x", False, self.ENV))

    def test_prompt_has_date_and_no_markdown_rule(self):
        p = ai.build_system_prompt("anthropic", "m", datetime(2026, 10, 14, tzinfo=timezone.utc), "Call me Sam.")
        self.assertIn("Wednesday, October 14, 2026", p)
        self.assertIn("do not use Markdown", p)
        self.assertTrue(p.endswith("Call me Sam."))


class OpenAITests(unittest.TestCase):
    def test_openai_path(self):
        seen = {}
        mod = types.ModuleType("openai")

        class Responses:
            def create(self, **kw):
                seen.update(kw)
                return types.SimpleNamespace(output_text="from openai")

        class OpenAI:
            def __init__(self, **kw):
                self.responses = Responses()

        mod.OpenAI = OpenAI
        sys.modules["openai"] = mod
        out = ai.generate_answer([], "hi", True, {"OPENAI_API_KEY": "k", "OPENAI_MODEL": "m1"})
        self.assertEqual(out, "from openai")
        self.assertEqual(seen["model"], "m1")
        self.assertEqual(seen["tools"], [{"type": "web_search"}])


class ErrorTests(unittest.TestCase):
    def test_mapping(self):
        def make(name, msg=""):
            e = type(name, (Exception,), {})(msg)
            e.message = msg
            return e

        self.assertEqual(ai.describe_error(ai.ConfigError("x"))[0], 503)
        self.assertEqual(ai.describe_error(ValueError("empty"))[0], 422)
        self.assertEqual(ai.describe_error(make("AuthenticationError"))[0], 502)
        self.assertEqual(ai.describe_error(make("RateLimitError"))[0], 429)
        status, text = ai.describe_error(make("BadRequestError", "Your credit balance is too low"))
        self.assertIn("credit balance", text)
        self.assertEqual(ai.describe_error(make("APITimeoutError"))[0], 504)
        self.assertIn("Weird", ai.describe_error(make("Weird"))[1])


if __name__ == "__main__":
    unittest.main()
