"""Provider-agnostic chat logic for Ronghor AI.

No web-framework imports live here, so this file can be unit-tested on its own
(see test_ai.py). SDKs are imported lazily so only the provider you use is needed.
"""
import os
from datetime import datetime, timezone

DEFAULT_ANTHROPIC_MODEL = "claude-sonnet-5-5"
PROVIDER_LABELS = {
    "anthropic": "Claude, a model made by Anthropic",
    "openai": "a model made by OpenAI",
}


class ConfigError(Exception):
    """The server is missing a setting the administrator must provide."""


def choose_provider(env=None) -> str:
    env = os.environ if env is None else env
    explicit = (env.get("AI_PROVIDER") or "").strip().lower()
    if explicit:
        if explicit not in PROVIDER_LABELS:
            raise ConfigError("AI_PROVIDER must be 'anthropic' or 'openai'.")
        if not env.get(f"{explicit.upper()}_API_KEY"):
            raise ConfigError(f"{explicit.upper()}_API_KEY is not set on the server.")
        return explicit
    if env.get("ANTHROPIC_API_KEY"):
        return "anthropic"
    if env.get("OPENAI_API_KEY"):
        return "openai"
    raise ConfigError(
        "No AI key is configured on the server. Set ANTHROPIC_API_KEY "
        "(or OPENAI_API_KEY) in the server's environment settings."
    )


def resolve_model(provider: str, env=None) -> str:
    env = os.environ if env is None else env
    if provider == "anthropic":
        return (env.get("ANTHROPIC_MODEL") or "").strip() or DEFAULT_ANTHROPIC_MODEL
    model = (env.get("OPENAI_MODEL") or "").strip()
    if not model:
        raise ConfigError("OPENAI_MODEL is not set. Set it to a model your OpenAI account can use.")
    return model


def describe_config(env=None) -> dict:
    """Safe-to-share summary of the server's AI setup (never includes keys)."""
    try:
        provider = choose_provider(env)
        return {"ai_configured": True, "provider": provider, "model": resolve_model(provider, env)}
    except ConfigError as exc:
        return {"ai_configured": False, "provider": None, "model": None, "problem": str(exc)}


def build_system_prompt(provider: str, model: str, now=None, extra: str = "") -> str:
    now = now or datetime.now(timezone.utc)
    prompt = (
        "You are Ronghor AI, a helpful, careful, friendly AI assistant inside a mobile chat app. "
        f"Today's date is {now.strftime('%A, %B %d, %Y')} (UTC). "
        "Answer clearly and concisely, and go deeper when asked. Reply in the language the user writes in. "
        "Be honest about uncertainty, and never claim to have done something you did not do. "
        "The app shows plain text only, so do not use Markdown: no asterisks for bold, no # headings, "
        "no tables. Use short paragraphs and simple lists with hyphens or numbers. "
        "When you use web search, make clear which facts come from sources. "
        f"If asked what powers you, say you are Ronghor AI, running on {PROVIDER_LABELS[provider]} ({model})."
    )
    if extra.strip():
        prompt += "\n\n" + extra.strip()
    return prompt


def merge_turns(history, message: str) -> list:
    """Return alternating user/assistant turns that start and end with a user turn.

    The app's greeting is an assistant message at the very start of the chat, and a failed
    request can leave two user messages in a row. Anthropic's API wants a clean alternation,
    so leading assistant turns are dropped and same-role neighbours are merged.
    """
    turns = []
    items = [{"role": h["role"], "content": h["content"]} for h in history]
    items.append({"role": "user", "content": message})
    for item in items:
        role = item["role"]
        content = (item["content"] or "").strip()
        if not content:
            continue
        if not turns and role != "user":
            continue
        if turns and turns[-1]["role"] == role:
            turns[-1]["content"] += "\n\n" + content
        else:
            turns.append({"role": role, "content": content})
    if not turns or turns[-1]["role"] != "user":
        raise ValueError("The message is empty.")
    return turns


def _text_of(blocks) -> str:
    return "".join(
        getattr(b, "text", "") or "" for b in blocks if getattr(b, "type", None) == "text"
    )


def ask_anthropic(turns, system: str, web_search: bool, model: str, env=None) -> str:
    env = os.environ if env is None else env
    import anthropic  # lazy import

    client = anthropic.Anthropic(api_key=env["ANTHROPIC_API_KEY"], timeout=90.0, max_retries=1)
    kwargs = {
        "model": model,
        "max_tokens": int(env.get("MAX_OUTPUT_TOKENS") or 2048),
        "system": system,
    }
    if web_search:
        kwargs["tools"] = [{"type": "web_search_20250305", "name": "web_search", "max_uses": 5}]

    messages = list(turns)
    parts = []
    for _ in range(4):  # a long web-search turn can be paused by the API and must be resumed
        response = client.messages.create(messages=messages, **kwargs)
        parts.append(_text_of(response.content))
        if getattr(response, "stop_reason", None) != "pause_turn":
            break
        messages = messages + [{"role": "assistant", "content": response.content}]
    return "".join(parts).strip()


def ask_openai(turns, system: str, web_search: bool, model: str, env=None) -> str:
    env = os.environ if env is None else env
    from openai import OpenAI  # lazy import

    client = OpenAI(api_key=env["OPENAI_API_KEY"], timeout=90.0, max_retries=1)
    kwargs = {"model": model, "instructions": system, "input": list(turns)}
    if web_search:
        kwargs["tools"] = [{"type": "web_search"}]
    response = client.responses.create(**kwargs)
    return (response.output_text or "").strip()


def generate_answer(history, message: str, web_search: bool = False, env=None, now=None) -> str:
    env = os.environ if env is None else env
    provider = choose_provider(env)
    model = resolve_model(provider, env)
    turns = merge_turns(history, message)
    system = build_system_prompt(provider, model, now, env.get("SYSTEM_PROMPT_EXTRA") or "")
    ask = ask_anthropic if provider == "anthropic" else ask_openai
    answer = ask(turns, system, web_search, model, env)
    return answer or "I couldn't produce a text response. Please try again."


def describe_error(exc: Exception):
    """Map an exception to (http_status, message safe to show in the app)."""
    if isinstance(exc, ConfigError):
        return 503, str(exc)
    if isinstance(exc, ValueError):
        return 422, str(exc)
    name = type(exc).__name__
    detail = str(getattr(exc, "message", "") or "")[:300].strip()
    if name == "AuthenticationError":
        return 502, "The AI provider rejected the server's API key. Check the key in the server settings."
    if name == "PermissionDeniedError":
        return 502, f"The AI provider denied this request. {detail}".strip()
    if name == "RateLimitError":
        return 429, "The AI provider is rate-limiting requests. Wait a minute and try again."
    if name == "NotFoundError":
        return 502, f"Model not found. Check the model name in the server settings. {detail}".strip()
    if name == "BadRequestError":
        return 502, f"The AI provider refused the request: {detail}".strip()
    if name in ("APIConnectionError", "APITimeoutError"):
        return 504, "The server could not reach the AI provider in time. Please try again."
    return 502, f"AI provider request failed ({name}). Check the server logs."
