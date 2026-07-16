# Promptfoo, hands-on — a mentored tutorial for the anime recommender

Goal: learn Promptfoo deeply enough to **demo it to your manager** and package it
as a repeatable **LLMSecOps methodology**. We build it in lessons — you write the
tests, run them, and extend them. Each lesson adds exactly one new concept.

Backing model throughout: your **Groq fallback** (`llama-3.1-8b-instant`), the same
model your app uses.

---

## The one distinction that makes the pitch land

Promptfoo has two modes. Keep them separate in your head — and in your pitch:

```
promptfoo eval      → QUALITY   (did my change make recommendations worse?)   ← the GAP in this repo
promptfoo redteam   → SECURITY  (can an attacker break it?)                    ← already in llmsecops-stage.yml
```

You already run `promptfoo redteam` in `.github/workflows/llmsecops-stage.yml` (stage
`prompt-security`). What's missing — and what turns "a scanner" into "a methodology" —
is the **eval** (quality/regression) side.

Frame it to your manager as a **test pyramid for LLM apps**:

| Layer | Assertion type | Cost | Catches |
|---|---|---|---|
| Deterministic | `icontains`, `regex`, `is-json`, `latency` | free, instant | format breaks, missing titles, slow responses |
| Model-graded | `llm-rubric` (LLM-as-judge) | 1 extra LLM call | relevance, groundedness, hallucination |
| Adversarial | `redteam` plugins/strategies | many calls | injection, jailbreak, leakage |

That table *is* the methodology slide. Every lesson fills in a row.

---

## The second distinction: model vs application

Promptfoo can point at **the model** or at **your application** — different tests:

- **Model test** — hits Groq directly. Tests `llama-3.1-8b-instant` in isolation.
  No RAG, no your prompt.
- **App test** — hits your `AnimeRecommendationPipeline` (retriever +
  `src/prompt_template.py` + Groq). Tests what users actually get.

We start with the **model test** (Lesson 1) to learn the four moving parts with zero
RAG complexity. Lesson 2 swaps the *provider* to your real pipeline and nothing else
changes — "same tests, deeper target." That swap is a great thing to demo.

---

## The mental model

Every Promptfoo test is one pipeline:

```
vars  →  prompt (rendered)  →  provider (generates)  →  assertions (grade)  →  pass/fail
```

Four keys in `promptfooconfig.yaml` map exactly to that:

| Key | Role |
|---|---|
| `prompts` | template with `{{var}}` placeholders |
| `providers` | the model (or your app) that generates the answer |
| `tests` | list of inputs (`vars`) — one row each |
| `assert` | the graders that decide pass/fail |

---

## Lesson 1 — the anatomy (raw model)

Everything lives in a **`promptfoo/`** directory (not one file — it has to scale to
100+ tests, a Python provider, and a red-team suite). Layout:

```
promptfoo/
├── promptfooconfig.yaml   # entry: prompt + provider + which test files to run
├── tests/quality.yaml     # recommendation-quality suite (this lesson)
├── providers/             # (Lesson 2) Python provider → real RAG app
└── redteam/               # (Lesson 5) security suite
```

`promptfoo/promptfooconfig.yaml` stays tiny — it points at test files:

```yaml
description: "Anime recommender — quality eval (Lesson 1: raw model)"

# 1) PROMPT — {{query}} is a variable filled from each test's vars.
#    (Simplified on purpose — Lesson 2 uses your real prompt_template.py.)
prompts:
  - |
    You are an anime recommendation assistant. Recommend exactly three anime
    for the user's request. For each: the title and a one-line reason.

    User request: {{query}}

# 2) PROVIDER — your Groq fallback, same model your app uses.
providers:
  - id: openai:chat:llama-3.1-8b-instant
    config:
      apiBaseUrl: https://api.groq.com/openai/v1
      apiKey: ${GROQ_API_KEY}

# 3) TESTS — split into files under tests/ (so suites scale + review cleanly).
tests:
  - file://tests/quality.yaml
```

And `promptfoo/tests/quality.yaml` holds the actual cases (`assert:` = the 4th part):

```yaml
- description: "dark psychological request returns a fitting title"
  vars:
    query: Recommend dark psychological anime
  assert:
    - type: icontains-any
      value: ["Monster", "Death Note", "Psycho-Pass", "Parasyte", "Steins;Gate"]
    - type: latency
      threshold: 8000   # fail if slower than 8s

- description: "sports request returns a real sports anime"
  vars:
    query: Recommend a sports anime
  assert:
    - type: icontains-any
      value: ["Haikyuu", "Blue Lock", "Slam Dunk", "Kuroko", "Ping Pong"]
```

Run it (using `npx` so there's no global install to manage):

```bash
set -a; . ./.env; set +a          # load GROQ_API_KEY into the shell
npx promptfoo@latest eval -c promptfoo/promptfooconfig.yaml
npx promptfoo@latest view          # opens the browser matrix
```

**What to watch for:**
- the terminal prints a pass/fail row per test — your first green/red
- `promptfoo view` gives the dashboard matrix (the visual for the demo)
- break it on purpose: change an `icontains-any` list to `["K-On!"]` and rerun —
  watch it go red. That "I changed something and a test caught it" loop *is* the pitch.

**Your turn (before Lesson 2):**
1. Get the two tests passing.
2. Add a **third** test — your own query (e.g. `cozy slice-of-life`) with an
   `icontains-any` of titles you'd accept.
3. Open `promptfoo view` and find where a failing cell shows the actual model output.

---

## Lesson 2 — point the same tests at your real RAG app  *(next)*

A small Python provider (`file://promptfoo_provider.py`) that calls
`AnimeRecommendationPipeline.recommend(query)`, so the tests exercise the retriever +
your `prompt_template.py` + Groq. Same `tests:` block, deeper target. Requires the
Chroma store to exist locally. *(To be written together.)*

## Lesson 3 — LLM-as-a-judge (`llm-rubric`)  *(next)*

Add model-graded assertions for relevance and groundedness. One Groq-specific gotcha:
the grader defaults to OpenAI, so we point it at Groq via `defaultTest.options.provider`.
*(To be written together.)*

## Lesson 4 — a real benchmark dataset  *(later)*

Grow to 100–200 representative queries in a `tests:` file, organized by the pyramid
categories (recommendation quality, RAG faithfulness, hallucination, format).

## Lesson 5 — fold in red teaming  *(later)*

Reuse the existing `redteam` config from `LLMSECOPS_LOCAL.md` as a second suite so
quality + security share one workflow.

## Lesson 6 — CI merge gate  *(later)*

Wire `promptfoo eval` into a GitHub Action that blocks a PR when quality regresses —
the same shape as the existing `llmsecops.yml`.

---

## Learning log

Tick these off as you go:

- [ ] Lesson 1 — two tests green, matrix viewed, one deliberate red
- [ ] Lesson 2 — provider swapped to the real pipeline
- [ ] Lesson 3 — first `llm-rubric` judge passing on Groq
- [ ] Lesson 4 — 100+ query benchmark
- [ ] Lesson 5 — redteam suite folded in
- [ ] Lesson 6 — CI gate blocking a regression
