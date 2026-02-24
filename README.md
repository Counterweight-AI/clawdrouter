# ClawdRouter

Smart model routing for [OpenClaw](https://openclaw.ai). Routes your OpenClaw's requests to cheap, mid-range, or expensive models based on what you're doing so you stop burning credits on simple requests.

## Why

Why drive a Lamborgini to the grocery store when the Prius will do? ClawRouter classifies each message with regex patterns and sends it to the right tier based on the table below:

| Tier | What goes here | Example models |
|------|---------------|----------------|
| **Low** | Greetings, simple chat, factual lookups | DeepSeek, Gemini Flash Lite |
| **Mid** | Coding, translation, summarization, creative writing | Claude Haiku, GLM |
| **Top** | Math proofs, multi-step reasoning, deep analysis | Claude Sonnet, GPT-4o |

## Install (OpenClaw Plugin)

```bash
# 1. Clone the repo
git clone https://github.com/Counterweight-AI/clawdrouter.git --depth 1
cd clawdrouter

# 2. Install the plugin (link mode — points at your local copy)
openclaw plugins install -l ./openclaw-plugin

# 3. Restart the gateway to start the service
openclaw gateway restart
```

That's it. On first start, the service will automatically:
1. Clone the repo into `~/.openclaw/litellm/`
2. Create a Python 3.10+ venv and install LiteLLM
3. Read your existing API keys from OpenClaw auth profiles
4. Pick the best tier models based on your available keys
5. Generate `proxy_config.yaml` and `routing_rules.yaml`
6. Start the proxy on port 4000
7. Add `clawrouter/auto` as a provider in your OpenClaw config

Verify it works:

```bash
curl http://localhost:4000/health/liveliness    # → "I'm alive!"
```

Test routing:

```bash
# Simple → LOW tier
curl http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-clawrouter" \
  -d '{"model":"auto","messages":[{"role":"user","content":"hi"}]}'

# Coding → MID tier
# ... "write a Python function" ...

# Reasoning → TOP tier
# ... "prove that sqrt(2) is irrational" ...

# Force a tier with [low], [med], or [high] prefix
# ... "[high] hello" ...
```

## Configuration

Edit `routing_rules.yaml` to customize tier models, category-to-tier mappings, or add domain-specific patterns:

```yaml
tiers:
  low:
    model: "deepseek/deepseek-chat"
  mid:
    model: "anthropic/claude-haiku-4-5-20251001"
  top:
    model: "anthropic/claude-sonnet-4-5-20250929"

routing:
  heartbeat: low
  simple-chat: low
  lookup: low
  translation: mid
  summarization: mid
  coding: mid
  creative: mid
  reasoning: top
  analysis: top
```

## Routing Keywords Reference

ClawRouter classifies messages using regex patterns. The first pattern that matches wins. Here's what triggers each category and its default tier:

### 🟢 LOW tier

**Heartbeat** — system pings and short greetings
- Single words: `hi`, `hey`, `hello`, `ping`, `test`, `yo`, `sup`, `hola`, `ok`, `okay`, `yes`, `no`, `thanks`, `thx`, `ty`
- Questions: `are you there?`, `you there?`, `alive?`, `awake?`
- System tokens: `read heartbeat.md`, `heartbeat_ok`, `reply heartbeat_ok`

**Simple Chat** — any message under 80 characters that didn't match a more specific category

**Lookup** — factual questions (message starts with these)
- `what is ...`, `what are ...`
- `who is / who was / who are / who were ...`
- `when did / when was / when is / when will ...`
- `where is / where was / where are / where were ...`
- `how many / how much / how old / how long / how far / how tall / how big ...`
- `define ...`, `definition of ...`, `what does ... mean`
- `is it true that ...`
- `capital of / population of / currency of ...`

---

### 🟡 MID tier

**Translation**
- `translate this / translate the / translate from ... to ...`
- `in Spanish / in French / in German / in Chinese / in Japanese / in Korean` (and 15+ other languages)
- `how do you say ... in [language]`

**Summarization** — message starts with or contains:
- `summarize`, `summary of`, `tldr`, `tl;dr`
- `give me a summary`, `can you summarize`
- `briefly summarize / briefly recap`
- `key points from / key takeaways of`

**Coding** — any of the following anywhere in the message:
- Code fences ` ``` ` or inline backtick code
- Programming keywords: `def`, `class`, `function`, `const`, `let`, `var`, `import`, `require(`
- File extensions: `.py`, `.js`, `.ts`, `.go`, `.rs`, `.java`, `.cpp`, `.rb`, `.sh`, `.yaml`, `.json`
- Action verbs + code nouns: `write/create/build/implement/fix/debug/refactor` + `function`, `class`, `api`, `endpoint`, `script`, `module`, `component`, `test`, `service`, etc.
- Error words: `bug`, `error`, `exception`, `traceback`, `stack trace`, `segfault`
- Package managers: `npm install`, `pip install`, `cargo`, `go get`, `apt`, `brew`, `yarn`, `pnpm install`
- Git commands: `git commit`, `git push`, `git pull`, `git merge`, `git rebase`, `git clone`, `git diff`, `git log`, `git stash`, etc.
- DevOps tools: `docker`, `kubectl`, `terraform`, `ansible`
- SQL: `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `CREATE TABLE`, `ALTER TABLE`, `DROP TABLE`
- Pattern matching: `regex`, `regexp`, `pattern match`
- URLs: `localhost:PORT`, `127.0.0.1:PORT`, `https://.../api/`

**Creative** — message starts with or contains:
- `write me a / write me an / write a / write an ...`
- `compose`, `draft`
- `create a story / poem / essay / article / blog / email / letter / speech / song`
- `write a story / tell me a story / write a poem / write a joke / write a haiku / write a limerick / write a sonnet`
- `creative writing`, `brainstorm ideas / names / titles / concepts`
- `rewrite this / rephrase this / paraphrase this`

---

### 🔴 TOP tier

**Reasoning** — math, proofs, and multi-step logic:
- `prove that`, `proof of`, `explain why`
- `what is the relationship between`
- `derive`, `theorem`, `lemma`, `corollary`, `axiom`, `mathematically`
- `integral of`, `derivative of`, `solve for`, `solve the equation`
- `calculate the probability / expected / variance`
- `if and only if`, `necessary and sufficient`
- `by contradiction`, `by induction`
- `what would happen if`, `consider the case / consider the scenario`
- `step-by-step reasoning / thinking / logic / analysis`
- `multi-step`, `chain-of-thought`

**Analysis** — comparison and evaluation (message starts with or contains):
- Starts with: `analyze`, `compare`, `evaluate`, `assess`, `review`, `critique`, `research`, `investigate`, `examine`
- `pros and cons`, `trade-offs`, `advantages and disadvantages`
- `in-depth analysis / in-depth review`
- `strengths and weaknesses`
- `comprehensive review / comprehensive analysis / comprehensive overview`

---

> **Note:** The routing table in `routing_rules.yaml` controls which tier each category maps to. The defaults above reflect the factory configuration but can be changed.

## User Controls

**Force a tier** by prefixing your message:
- `[low] what's 2+2` — force low tier model
- `[med] write a python script` — force medium tier model
- `[medium] write a python script` — same as `[med]`
- `[high] prove this theorem` — force top tier model

The tag is stripped before the model sees it.

## Standalone Usage (Without OpenClaw)

```bash
./setup.sh
```

This walks you through API key setup, tier model selection, and starts the proxy on port 4000.
