#!/usr/bin/env python3
# ============================================================
# parallel_ai.py — Pocket Lab Parallel AI Tool (v1.0)
#
# Fires a prompt simultaneously at multiple AI providers
# and streams results side-by-side as they arrive.
#
# Providers supported (via env vars):
#   ANTHROPIC_API_KEY  → Claude claude-opus-4-5 / claude-sonnet-4-5
#   OPENAI_API_KEY     → GPT-4o / GPT-4o-mini
#   PERPLEXITY_API_KEY → Sonar (pplx-70b-online)
#   OLLAMA_BASE_URL    → Dolphin3 / any local model (default: http://localhost:11434)
#                        (also honors OLLAMA_HOST and legacy OLLAMA_URL)
#
# Custom provider endpoints (for proxies, local mirrors, etc.):
#   ANTHROPIC_BASE_URL, OPENAI_BASE_URL, PERPLEXITY_BASE_URL, OPENROUTER_BASE_URL
#   SUPERMEMORY_API_KEY → Semantic memory backend (context injection + run archival)
#
# Usage:
#   python3 parallel_ai.py "your prompt here"
#   python3 parallel_ai.py --models claude,gpt4o "your prompt"
#   python3 parallel_ai.py --list-models
#   python3 parallel_ai.py --timeout 30 "fast answer needed"
#   python3 parallel_ai.py --json "your prompt"   # machine-readable output
#
# Integrates with Pocket Lab:
#   - Reads MEM0_API_KEY from /root/.mem0_env (saves run event)
#   - Can be called from pocket_lab.sh: pocket_lab.sh ai "prompt"
#   - Gate-agnostic: runs standalone, no vault unlock required
# ============================================================

import os
import sys
import json
import time
import argparse
import threading
import textwrap
from datetime import datetime, timezone
from typing import Optional

# ── Auto-load .mem0_env ───────────────────────────────────────
# Sources /root/.mem0_env (or ~/.mem0_env) at startup so
# SUPERMEMORY_API_KEY and MEM0_API_KEY are always available
# without needing to manually `source` the file.
def _load_mem0_env():
    for env_file in ["/root/.mem0_env", os.path.expanduser("~/.mem0_env")]:
        if os.path.exists(env_file):
            try:
                with open(env_file) as f:
                    for line in f:
                        line = line.strip()
                        if not line or line.startswith("#") or "=" not in line:
                            continue
                        key, _, val = line.partition("=")
                        key = key.strip()
                        val = val.strip()
                        # Only set if not already in environment
                        if key and val and key not in os.environ:
                            os.environ[key] = val
            except Exception:
                pass
            break

_load_mem0_env()

# ── ANSI colors ──────────────────────────────────────────────
RESET  = "\033[0m"
BOLD   = "\033[1m"
DIM    = "\033[2m"
RED    = "\033[91m"
GREEN  = "\033[92m"
YELLOW = "\033[93m"
CYAN   = "\033[96m"
MAGENTA= "\033[95m"
BLUE   = "\033[94m"

MODEL_COLORS = {
    "claude":   CYAN,
    "gpt4o":    GREEN,
    "sonar":    MAGENTA,
    "dolphin":  YELLOW,
    "gemini":   BLUE,
}

# ── Supermemory constants (used by _run_supermemory + helpers) ─
# Defined here near the top so order-of-import never matters.
SM_API   = "https://api.supermemory.ai/v3"
SM_USER  = "pocket-lab-user"

# ── Model registry ────────────────────────────────────────────
MODELS = {
    "claude": {
        "label":    "Claude (Anthropic)",
        "env":      "ANTHROPIC_API_KEY",
        "color":    CYAN,
        "fn":       "_run_anthropic",
        "model_id": "claude-opus-4-5",
    },
    "claude-sonnet": {
        "label":    "Claude Sonnet (Anthropic)",
        "env":      "ANTHROPIC_API_KEY",
        "color":    CYAN,
        "fn":       "_run_anthropic",
        "model_id": "claude-sonnet-4-5",
    },
    "gpt4o": {
        "label":    "GPT-4o (OpenAI)",
        "env":      "OPENAI_API_KEY",
        "color":    GREEN,
        "fn":       "_run_openai",
        "model_id": "gpt-4o",
    },
    "gpt4o-mini": {
        "label":    "GPT-4o-mini (OpenAI)",
        "env":      "OPENAI_API_KEY",
        "color":    GREEN,
        "fn":       "_run_openai",
        "model_id": "gpt-4o-mini",
    },
    "sonar": {
        "label":    "Sonar (Perplexity)",
        "env":      "PERPLEXITY_API_KEY",
        "color":    MAGENTA,
        "fn":       "_run_perplexity",
        "model_id": "llama-3.1-sonar-large-128k-online",
    },
    "dolphin": {
        "label":    "Dolphin3-3b — compressor (Ollama/local)",
        "env":      None,
        "color":    YELLOW,
        "fn":       "_run_ollama",
        "model_id": "nchapman/dolphin3.0-qwen2.5:latest",
    },
    "mistral": {
        "label":    "Mistral-7b — primary local (Ollama/local)",
        "env":      None,
        "color":    YELLOW,
        "fn":       "_run_ollama",
        "model_id": "mistral:latest",
    },
    "gemma": {
        "label":    "Gemma3-4b (Ollama/local)",
        "env":      None,
        "color":    BLUE,
        "fn":       "_run_ollama",
        "model_id": "gemma3:4b",
    },
    "openrouter-mistral": {
        "label":    "Mistral (OpenRouter free)",
        "env":      "OPENROUTER_API_KEY",
        "color":    BLUE,
        "fn":       "_run_openrouter",
        "model_id": "mistralai/mistral-7b-instruct:free",
    },
    "openrouter-llama": {
        "label":    "Llama3 (OpenRouter free)",
        "env":      "OPENROUTER_API_KEY",
        "color":    BLUE,
        "fn":       "_run_openrouter",
        "model_id": "meta-llama/llama-3.2-3b-instruct:free",
    },
    "supermemory-mistral": {
        "label":    "Mistral via Supermemory→OpenRouter",
        "env":      "SUPERMEMORY_API_KEY",
        "color":    BLUE,
        "fn":       "_run_supermemory",
        "model_id": "mistralai/mistral-7b-instruct:free",
    },
    "supermemory-llama": {
        "label":    "Llama3 via Supermemory→OpenRouter",
        "env":      "SUPERMEMORY_API_KEY",
        "color":    BLUE,
        "fn":       "_run_supermemory",
        "model_id": "meta-llama/llama-3.2-3b-instruct:free",
    },
}


# ── Provider base URL resolution ─────────────────────────────
# Each provider honors a standard env var for the base URL, with a
# sensible default. URL joining is tolerant of trailing slashes and
# of users supplying either the bare host or a full endpoint path.

_DEFAULT_BASE_URLS = {
    "anthropic":  "https://api.anthropic.com",
    "openai":     "https://api.openai.com",
    "perplexity": "https://api.perplexity.ai",
    "openrouter": "https://openrouter.ai/api/v1",
    "ollama":     "http://localhost:11434",
}

# Env var names checked in order; first non-empty wins.
_BASE_URL_ENVS = {
    "anthropic":  ["ANTHROPIC_BASE_URL"],
    "openai":     ["OPENAI_BASE_URL", "OPENAI_API_BASE"],
    "perplexity": ["PERPLEXITY_BASE_URL"],
    "openrouter": ["OPENROUTER_BASE_URL"],
    # OLLAMA_URL kept for backwards compatibility; OLLAMA_BASE_URL /
    # OLLAMA_HOST are the standard vars used by the Ollama ecosystem.
    "ollama":     ["OLLAMA_BASE_URL", "OLLAMA_HOST", "OLLAMA_URL"],
}


def _provider_base_url(provider: str) -> str:
    """Return the configured base URL for `provider`, trimmed of trailing slashes."""
    for env in _BASE_URL_ENVS.get(provider, []):
        val = os.environ.get(env, "").strip()
        if val:
            # OLLAMA_HOST can be host:port without scheme — normalize.
            if provider == "ollama" and "://" not in val:
                val = "http://" + val
            return val.rstrip("/")
    return _DEFAULT_BASE_URLS[provider].rstrip("/")


def _join_endpoint(base: str, path: str) -> str:
    """Join `base` and `path` ensuring exactly one slash and tolerating
    users who already included `path` (or a prefix of it) in the base."""
    base = base.rstrip("/")
    path = "/" + path.lstrip("/")
    if base.endswith(path):
        return base
    return base + path


# ── Result container ─────────────────────────────────────────
class ModelResult:
    def __init__(self, key: str):
        self.key      = key
        self.label    = MODELS[key]["label"]
        self.color    = MODELS[key]["color"]
        self.text     = ""
        self.error    = None
        self.elapsed  = 0.0
        self.done     = False
        self.tokens   = {}


# ── HTTP helper ──────────────────────────────────────────────
# All five chat-completion-style providers share the same shape:
#   POST <base>/<path>  Content-Type: application/json
#   payload = {"model": ..., "messages": [...], "max_tokens": ...}
#   response = {"choices": [{"message": {"content": ...}}], "usage": ...}
#
# Anthropic is the one outlier: top-level "system", body["content"][0]["text"],
# different auth header. We pass shape-specific knobs as parameters.

def _post_chat(
    *,
    url: str,
    headers: dict,
    payload: dict,
    timeout: int,
    extract_text,
    extract_tokens=lambda d: d.get("usage", {}),
):
    """
    POST a JSON payload and return (text, tokens, error).

    On HTTPError the response body (truncated) is included in the error
    string so 401/429/500 surface meaningful provider context instead of
    the bare "HTTP Error 401: Unauthorized".
    """
    import urllib.request
    import urllib.error
    try:
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode(),
            headers=headers,
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.load(resp)
        return extract_text(data), extract_tokens(data), None
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode("utf-8", errors="replace")[:200]
        except Exception:
            pass
        msg = f"HTTP {e.code}"
        if body:
            msg += f": {body}"
        return "", {}, msg
    except Exception as e:
        return "", {}, str(e)


def _build_messages(prompt: str, system: str) -> list:
    """Standard OpenAI-style messages list with optional system turn."""
    msgs = []
    if system:
        msgs.append({"role": "system", "content": system})
    msgs.append({"role": "user", "content": prompt})
    return msgs


def _require_env(name: str, result: ModelResult) -> str:
    """Get an env var or short-circuit the runner with an error."""
    val = os.environ.get(name, "")
    if not val:
        result.error = f"{name} not set"
    return val


# ── Provider runners ─────────────────────────────────────────

def _run_anthropic(prompt: str, model_id: str, system: str,
                   result: ModelResult, timeout: int):
    key = _require_env("ANTHROPIC_API_KEY", result)
    if not key:
        return
    payload = {
        "model": model_id,
        "max_tokens": 1024,
        "messages": [{"role": "user", "content": prompt}],
    }
    if system:
        payload["system"] = system
    text, tokens, err = _post_chat(
        url=_join_endpoint(_provider_base_url("anthropic"), "/v1/messages"),
        headers={
            "x-api-key": key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
        payload=payload,
        timeout=timeout,
        extract_text=lambda d: d["content"][0]["text"],
    )
    result.text, result.tokens, result.error = text, tokens, err


def _run_openai(prompt: str, model_id: str, system: str,
                result: ModelResult, timeout: int):
    key = _require_env("OPENAI_API_KEY", result)
    if not key:
        return
    text, tokens, err = _post_chat(
        url=_join_endpoint(_provider_base_url("openai"), "/v1/chat/completions"),
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
        payload={"model": model_id, "messages": _build_messages(prompt, system),
                 "max_tokens": 1024},
        timeout=timeout,
        extract_text=lambda d: d["choices"][0]["message"]["content"],
    )
    result.text, result.tokens, result.error = text, tokens, err


def _run_perplexity(prompt: str, model_id: str, system: str,
                    result: ModelResult, timeout: int):
    key = _require_env("PERPLEXITY_API_KEY", result)
    if not key:
        return
    text, tokens, err = _post_chat(
        url=_join_endpoint(_provider_base_url("perplexity"), "/chat/completions"),
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
        payload={"model": model_id, "messages": _build_messages(prompt, system),
                 "max_tokens": 1024},
        timeout=timeout,
        extract_text=lambda d: d["choices"][0]["message"]["content"],
    )
    result.text, result.tokens, result.error = text, tokens, err


def _run_supermemory(prompt: str, model_id: str, system: str,
                     result: ModelResult, timeout: int):
    """Route through Supermemory Memory Router → OpenRouter free models."""
    sm_key = _require_env("SUPERMEMORY_API_KEY", result)
    if not sm_key:
        return
    # Supermemory Memory Router proxies to OpenRouter; the OpenRouter
    # bearer can be overridden via SM_OPENROUTER_KEY for paid models.
    or_bearer = os.environ.get("SM_OPENROUTER_KEY", "free")
    text, tokens, err = _post_chat(
        url="https://api.supermemory.ai/v3/https://openrouter.ai/api/v1/chat/completions",
        headers={
            "Authorization": f"Bearer {or_bearer}",
            "Content-Type": "application/json",
            "x-supermemory-api-key": sm_key,
            "x-sm-user-id": SM_USER,
            "x-sm-conversation-id": "pocket-lab",
            "HTTP-Referer": "https://github.com/Tsukieomie/pocket-lab-v2-6",
            "X-Title": "Pocket Lab Parallel AI",
        },
        payload={"model": model_id, "messages": _build_messages(prompt, system),
                 "max_tokens": 1024},
        timeout=timeout,
        extract_text=lambda d: d["choices"][0]["message"]["content"],
    )
    result.text, result.tokens, result.error = text, tokens, err


def _run_openrouter(prompt: str, model_id: str, system: str,
                    result: ModelResult, timeout: int):
    """Call OpenRouter free-tier models — requires OPENROUTER_API_KEY."""
    key = _require_env("OPENROUTER_API_KEY", result)
    if not key:
        return
    text, tokens, err = _post_chat(
        url=_join_endpoint(_provider_base_url("openrouter"), "/chat/completions"),
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://github.com/Tsukieomie/pocket-lab-v2-6",
            "X-Title": "Pocket Lab Parallel AI",
        },
        payload={"model": model_id, "messages": _build_messages(prompt, system),
                 "max_tokens": 1024},
        timeout=timeout,
        extract_text=lambda d: d["choices"][0]["message"]["content"],
    )
    result.text, result.tokens, result.error = text, tokens, err


def _run_ollama(prompt: str, model_id: str, system: str,
                result: ModelResult, timeout: int):
    payload = {
        "model":  model_id,
        "prompt": prompt,
        "stream": False,
    }
    if system:
        payload["system"] = system
    text, tokens, err = _post_chat(
        url=_join_endpoint(_provider_base_url("ollama"), "/api/generate"),
        headers={"Content-Type": "application/json"},
        payload=payload,
        timeout=timeout,
        extract_text=lambda d: d.get("response", ""),
        extract_tokens=lambda d: {},  # Ollama has no usage block
    )
    result.text, result.tokens, result.error = text, tokens, err


_RUNNERS = {
    "_run_anthropic":   _run_anthropic,
    "_run_openai":      _run_openai,
    "_run_perplexity":  _run_perplexity,
    "_run_ollama":      _run_ollama,
    "_run_supermemory": _run_supermemory,
    "_run_openrouter":  _run_openrouter,
}


# ── Dolphin pre-compressor ───────────────────────────────────

def dolphin_compress(prompt: str, timeout: int = 60) -> str:
    """
    Send prompt to local Dolphin3 first. Dolphin compresses it to
    the shortest possible intent-preserving version. Returns the
    compressed prompt (falls back to original on any error).
    """
    system = (
        "You are a prompt compressor. Rewrite the user message as the "
        "shortest possible prompt preserving 100% of intent and context. "
        "Remove all filler, pleasantries, redundancy. "
        "Output ONLY the compressed prompt. No explanation. No preamble."
    )
    try:
        import urllib.request
        url = _join_endpoint(_provider_base_url("ollama"), "/api/generate")
        payload = {
            "model": "nchapman/dolphin3.0-qwen2.5:latest",
            "system": system,
            "prompt": prompt,
            "stream": False,
        }
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.load(resp)
        compressed = data.get("response", "").strip()
        if compressed:
            saving = round((1 - len(compressed) / len(prompt)) * 100)
            label = f"{saving}% reduction" if saving > 0 else f"{-saving}% growth"
            print(f"{DIM}[dolphin-compress] {len(prompt)} → {len(compressed)} chars ({label}){RESET}")
            return compressed
    except Exception as e:
        print(f"{DIM}[dolphin-compress] skipped: {e}{RESET}")
    return prompt


# ── Core dispatcher ──────────────────────────────────────────

def run_parallel(prompt: str,
                 model_keys: list,
                 system: str = "",
                 timeout: int = 120,
                 as_json: bool = False) -> list:
    """
    Fire all model_keys simultaneously. Block until all finish or timeout.
    Returns list of ModelResult.
    """
    results = {k: ModelResult(k) for k in model_keys}
    threads = []

    def worker(key):
        cfg    = MODELS[key]
        result = results[key]
        fn     = _RUNNERS[cfg["fn"]]
        t0     = time.time()
        fn(prompt, cfg["model_id"], system, result, timeout)
        result.elapsed = round(time.time() - t0, 2)
        result.done    = True

    for key in model_keys:
        t = threading.Thread(target=worker, args=(key,), daemon=True)
        threads.append(t)
        t.start()

    if not as_json:
        _print_progress(results, model_keys, timeout)
    else:
        for t in threads:
            t.join(timeout=timeout + 2)

    # Mark any unfinished runners as TIMEOUT so JSON consumers and the
    # formatted printer don't silently render empty success rows.
    for k in model_keys:
        r = results[k]
        if not r.done:
            r.error = r.error or f"TIMEOUT after {timeout}s"
            r.done  = True

    return [results[k] for k in model_keys]


def _print_progress(results: dict, model_keys: list, timeout: int):
    """Animate a live wait indicator until all models finish."""
    import sys
    spinner = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
    i = 0
    t0 = time.time()
    while True:
        done   = [k for k in model_keys if results[k].done]
        active = [k for k in model_keys if not results[k].done]
        elapsed = round(time.time() - t0, 1)

        parts = []
        for k in model_keys:
            r   = results[k]
            col = r.color
            if r.done:
                if r.error:
                    parts.append(f"{col}✗ {k}{RESET}")
                else:
                    parts.append(f"{col}✓ {k} ({r.elapsed}s){RESET}")
            else:
                parts.append(f"{DIM}{spinner[i % len(spinner)]} {k}{RESET}")

        sys.stderr.write(f"\r  {' │ '.join(parts)}  [{elapsed}s]   ")
        sys.stderr.flush()

        if not active or elapsed > timeout + 2:
            break
        time.sleep(0.1)
        i += 1

    sys.stderr.write("\r" + " " * 80 + "\r")
    sys.stderr.flush()


# ── Output formatters ────────────────────────────────────────

def print_results(results: list, prompt: str):
    try:
        width = min(os.get_terminal_size().columns, 100)
    except OSError:
        width = 80
    sep   = "─" * width

    title  = f"  PARALLEL AI — {len(results)} model(s)  │  {datetime.now().strftime('%H:%M:%S')}"
    inner  = title.ljust(width - 2)[:width - 2]
    print(f"\n{BOLD}╔{'═'*(width-2)}╗{RESET}")
    print(f"{BOLD}║{inner}║{RESET}")
    print(f"{BOLD}╚{'═'*(width-2)}╝{RESET}")
    print(f"{DIM}Prompt: {prompt[:120]}{'...' if len(prompt)>120 else ''}{RESET}\n")

    for r in results:
        col = r.color
        if r.error:
            status = f"{RED}✗ ERROR{RESET}"
            body   = f"{RED}{r.error}{RESET}"
        else:
            status = f"{GREEN}✓ {r.elapsed}s{RESET}"
            # Wrap body to terminal width
            wrapped = textwrap.fill(r.text.strip(), width=width - 4,
                                    subsequent_indent="    ")
            body = wrapped

        print(f"{col}{BOLD}┌─ {r.label} {status}{RESET}")
        print(f"{col}│{RESET}")
        for line in body.split("\n"):
            print(f"{col}│{RESET}  {line}")
        print(f"{col}└{sep[1:]}{RESET}\n")


def print_json(results: list, prompt: str):
    out = {
        "prompt":    prompt,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "results": [
            {
                "model":   r.key,
                "label":   r.label,
                "elapsed": r.elapsed,
                "text":    r.text,
                "error":   r.error,
                "tokens":  r.tokens,
            }
            for r in results
        ]
    }
    print(json.dumps(out, indent=2, ensure_ascii=False))


# ── Supermemory integration ──────────────────────────────────
# Constants SM_API and SM_USER are defined at the top of the module
# alongside other module-level constants.

def _sm_key() -> str:
    """Resolve SUPERMEMORY_API_KEY — _load_mem0_env() handles the file."""
    return os.environ.get("SUPERMEMORY_API_KEY", "")


def supermemory_fetch_context(prompt: str) -> str:
    """Search Supermemory for relevant past context to inject into prompt."""
    try:
        import urllib.request
        key = _sm_key()
        if not key:
            return ""
        payload = json.dumps({"q": prompt[:200], "limit": 5}).encode()
        req = urllib.request.Request(
            f"{SM_API}/search",
            data=payload,
            headers={
                "Authorization": f"Bearer {key}",
                "Content-Type": "application/json",
                "x-sm-user-id": SM_USER,
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.load(resp)
        results = data.get("results", [])
        if not results:
            return ""
        ctx_parts = []
        for r in results:
            content = r.get("memory") or r.get("chunk") or ""
            if content:
                ctx_parts.append(content.strip())
        if not ctx_parts:
            return ""
        ctx = "\n---\n".join(ctx_parts)
        print(f"{DIM}[supermemory] injecting {len(ctx_parts)} memory chunk(s) as context{RESET}")
        return f"[Relevant context from memory:]\n{ctx}\n\n[Your query:]"
    except Exception as e:
        print(f"{DIM}[supermemory] context fetch skipped: {e}{RESET}")
        return ""


def supermemory_save_run(prompt: str, results: list):
    """Save prompt + all model responses to Supermemory for future context."""
    try:
        import urllib.request
        key = _sm_key()
        if not key:
            return
        # Build a rich memory document
        responses = []
        for r in results:
            if r.text and not r.error:
                responses.append(f"[{r.label} — {r.elapsed:.1f}s]\n{r.text}")
        if not responses:
            return
        content = (
            f"Pocket Lab Parallel AI Run — {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}\n"
            f"Prompt: {prompt}\n\n"
            + "\n\n".join(responses)
        )
        payload = {
            "content": content,
            "containerTags": [SM_USER, "pocket-lab"],
            "metadata": {
                "source": "parallel_ai",
                "models": [r.key for r in results if not r.error],
                "ts": datetime.now(timezone.utc).isoformat(),
            }
        }
        req = urllib.request.Request(
            f"{SM_API}/documents",
            data=json.dumps(payload).encode(),
            headers={
                "Authorization": f"Bearer {key}",
                "Content-Type": "application/json",
                "x-sm-user-id": SM_USER,
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=8) as resp:
            resp_data = json.load(resp)
        print(f"{DIM}[supermemory] run saved — id: {resp_data.get('id','?')}{RESET}")
    except Exception as e:
        print(f"{DIM}[supermemory] save skipped: {e}{RESET}")


# ── mem0 integration ─────────────────────────────────────────

def mem0_save_run(prompt: str, results: list):
    """Best-effort save of run summary to mem0 (agent_id=pocket-lab)."""
    try:
        mem0_env = "/root/.mem0_env"
        key = os.environ.get("MEM0_API_KEY", "")
        if not key and os.path.exists(mem0_env):
            for line in open(mem0_env).read().splitlines():
                if line.startswith("MEM0_API_KEY="):
                    key = line.split("=", 1)[1].strip()
                    break
        if not key:
            return

        import urllib.request
        summary = {
            "event":   "PARALLEL_AI_RUN",
            "ts":      datetime.now(timezone.utc).isoformat(),
            "version": "v1.0",
            "data": {
                "prompt_snippet": prompt[:80],
                "models": [
                    {"model": r.key, "elapsed": r.elapsed,
                     "ok": r.error is None, "chars": len(r.text)}
                    for r in results
                ]
            }
        }
        payload = {
            "messages": [{"role": "assistant",
                           "content": json.dumps(summary, separators=(",", ":"))}],
            "agent_id": "pocket-lab",
            "metadata": {"event": "PARALLEL_AI_RUN",
                         "ts": summary["ts"], "version": "v1.0"}
        }
        req = urllib.request.Request(
            "https://api.mem0.ai/v1/memories/",
            data=json.dumps(payload).encode(),
            headers={"Authorization": f"Token {key}",
                     "Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            pass
        print(f"{DIM}[mem0] PARALLEL_AI_RUN saved{RESET}")
    except Exception:
        pass  # Non-blocking — never fail the main run


# ── CLI ──────────────────────────────────────────────────────

def detect_available_models() -> list:
    """Return model keys where the required API key is present."""
    available = []
    # Fetch pulled Ollama model names once
    ollama_models = set()
    try:
        import urllib.request
        url = _join_endpoint(_provider_base_url("ollama"), "/api/tags")
        with urllib.request.urlopen(url, timeout=2) as resp:
            data = json.load(resp)
        ollama_models = {m["name"] for m in data.get("models", [])}
    except Exception:
        pass

    for key, cfg in MODELS.items():
        env = cfg.get("env")
        fn  = cfg.get("fn", "")
        if env is None:
            # Local-only providers (Ollama) — verify the model is actually pulled
            if fn == "_run_ollama" and cfg["model_id"] in ollama_models:
                available.append(key)
        elif os.environ.get(env):
            available.append(key)
    return available


def main():
    parser = argparse.ArgumentParser(
        description="Pocket Lab Parallel AI — fire a prompt at multiple models simultaneously",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent("""
        Examples:
          python3 parallel_ai.py "What is secp256k1?"
          python3 parallel_ai.py --models claude,gpt4o "Explain ECDSA"
          python3 parallel_ai.py --list-models
          python3 parallel_ai.py --json "Summarize the Akwei case"
          python3 parallel_ai.py --timeout 20 --models sonar "latest RF news"

        PRIVACY NOTE:
          Unless --no-mem0 and --no-supermemory are passed, every run sends
          the full prompt and every model's full response to mem0.ai and
          api.supermemory.ai for memory storage. Use --no-mem0
          --no-supermemory for sensitive prompts.
        """)
    )
    parser.add_argument("prompt",           nargs="?",  default=None,
                        help="Prompt to send to all models")
    parser.add_argument("--models", "-m",   default=None,
                        help="Comma-separated model keys (default: all available)")
    parser.add_argument("--system", "-s",   default="",
                        help="System prompt (optional)")
    parser.add_argument("--timeout", "-t",  type=int, default=120,
                        help="Per-model timeout in seconds (default: 120)")
    parser.add_argument("--json", "-j",     action="store_true",
                        help="Output raw JSON instead of formatted display")
    parser.add_argument("--list-models",    action="store_true",
                        help="List all models and their availability")
    parser.add_argument("--no-mem0",        action="store_true",
                        help="Skip saving run to mem0 (PRIVACY: by default the prompt + every model response is POSTed to mem0.ai)")
    parser.add_argument("--no-supermemory",  action="store_true",
                        help="Skip Supermemory context injection and save (PRIVACY: by default the prompt + every model response is POSTed to api.supermemory.ai)")
    parser.add_argument("--compress", "-c",  action="store_true",
                        help="Pre-compress prompt via local Dolphin3 to minimize cloud token usage")

    args = parser.parse_args()

    # ── --list-models ──────────────────────────────────────────
    if args.list_models:
        available = set(detect_available_models())
        print(f"\n{BOLD}Pocket Lab — Available Models{RESET}\n")
        for key, cfg in MODELS.items():
            env   = cfg.get("env")
            local = env is None
            if key in available:
                status = f"{GREEN}✓ ready{RESET}"
            elif local:
                status = f"{RED}✗ Ollama not running{RESET}"
            else:
                missing_env = env or ""
                status = f"{RED}✗ {missing_env} not set{RESET}"
            print(f"  {cfg['color']}{key:<16}{RESET} {cfg['label']:<30} {status}")
        print()
        sys.exit(0)

    # ── Prompt required ────────────────────────────────────────
    if not args.prompt:
        # Read from stdin if piped
        if not sys.stdin.isatty():
            args.prompt = sys.stdin.read().strip()
        else:
            parser.print_help()
            sys.exit(1)

    # ── Resolve model list ─────────────────────────────────────
    if args.models:
        requested = [m.strip() for m in args.models.split(",")]
        bad = [m for m in requested if m not in MODELS]
        if bad:
            print(f"{RED}Unknown models: {', '.join(bad)}{RESET}", file=sys.stderr)
            print(f"Run with --list-models to see available options.", file=sys.stderr)
            sys.exit(1)
        model_keys = requested
    else:
        model_keys = detect_available_models()
        if not model_keys:
            print(f"{RED}No models available. Set at least one API key or start Ollama.{RESET}",
                  file=sys.stderr)
            print(f"  ANTHROPIC_API_KEY, OPENAI_API_KEY, PERPLEXITY_API_KEY, or run Ollama locally.",
                  file=sys.stderr)
            sys.exit(1)

    # ── Dolphin pre-compression ───────────────────────────────
    if args.compress:
        if not args.json:
            print(f"{DIM}[dolphin-compress] compressing prompt via local Dolphin3...{RESET}")
        args.prompt = dolphin_compress(args.prompt, timeout=args.timeout)
        if not args.json:
            print(f"{DIM}Compressed prompt: {args.prompt[:120]}{'...' if len(args.prompt)>120 else ''}{RESET}\n")

    # ── Supermemory context injection ─────────────────────────
    sm_context = ""
    if not args.no_supermemory:
        sm_context = supermemory_fetch_context(args.prompt)
    if sm_context:
        args.prompt = sm_context + args.prompt

    # ── Banner ─────────────────────────────────────────────────
    if not args.json:
        print(f"\n{BOLD}Pocket Lab — Parallel AI{RESET}  "
              f"{DIM}firing {len(model_keys)} model(s): "
              f"{', '.join(model_keys)}{RESET}")

    # ── Run ────────────────────────────────────────────────────
    results = run_parallel(
        prompt     = args.prompt,
        model_keys = model_keys,
        system     = args.system,
        timeout    = args.timeout,
        as_json    = args.json,
    )

    # ── Output ─────────────────────────────────────────────────
    if args.json:
        print_json(results, args.prompt)
    else:
        print_results(results, args.prompt)

    # ── mem0 + Supermemory save ──────────────────────────────
    if not args.no_mem0:
        threading.Thread(
            target=mem0_save_run,
            args=(args.prompt, results),
            daemon=True
        ).start()
    if not args.no_supermemory:
        threading.Thread(
            target=supermemory_save_run,
            args=(args.prompt, results),
            daemon=True
        ).start()
    if not args.no_mem0 or not args.no_supermemory:
        time.sleep(0.5)  # brief window for async saves


if __name__ == "__main__":
    main()
