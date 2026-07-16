# garak — a complete, practical guide (for the anime recommender)

garak is an **LLM vulnerability scanner** (like `nmap`, but for LLM behaviour). You
point it at a target, it fires known attacks, and it reports which ones got through.

---

## 1. The mental model — 5 moving parts

```
PROBE ──► GENERATOR ──► DETECTOR ──► BUFF (optional) ──► EVALUATOR ──► REPORT
attacks    the target    did it work?   mutate attacks       score        files
```

| Part | What it is | In our setup |
|---|---|---|
| **Generator** | the target being attacked | `rest` → your app's `/recommend` (or `openai` → a model) |
| **Probe** | a family of attacks | `promptinject`, `dan.DanInTheWild`, `latentinjection`, ... |
| **Detector** | decides if an attempt succeeded | mostly rule-based (string/pattern); some use HF classifiers |
| **Buff** | optional transforms of attack prompts | e.g. base64/lowercase/paraphrase |
| **Evaluator** | tallies pass/fail per probe | writes the report |

Only the **generator** changes between "test the model" and "test the app."

---

## 2. Generators — the target (`--model_type` / `--model_name`)

The generator is *how garak reaches the thing under test*. Families:

| `--model_type` | Target |
|---|---|
| `rest` | **any HTTP JSON endpoint** — how we test the app (`/recommend`) |
| `openai` | OpenAI-compatible chat API (Groq, vLLM router, OpenAI) |
| `openai.OpenAICompatible` | same, with a custom base URL (Groq/vLLM) |
| `function.Single` | a Python function (same-process; blocked for us by langchain version clash) |
| `huggingface.Model` | a local HF model |
| `test.Blank` / `test.Repeat` | dummy targets for wiring tests |

We use **`rest`** so garak attacks the app end-to-end over HTTP. Its config
(`rest_app.tmpl.json`) maps: `uri` = the endpoint, `$INPUT` = where the attack
goes, `response_json_field` = where to read the answer.

---

## 3. Probes — the attack catalog (`--probes`)

Each probe module holds many attack prompts. The ones that matter for a RAG
recommender:

| Probe | What it tries | Why it matters here |
|---|---|---|
| `promptinject` | inject instructions that override the system prompt | core: can users hijack the recommender? |
| `dan` (`dan.DanInTheWild`, `dan.Dan_11_0`, ...) | "DAN"/jailbreak persona attacks | bypass your "recommend only from catalog" rules |
| `latentinjection` | **indirect** injection hidden in documents | **RAG-specific**: poisoned catalog text hijacking the model |
| `leakreplay` | make the model regurgitate hidden/training text | system-prompt / instruction leakage |
| `xss` | markdown-image / HTML exfiltration payloads | data exfil if output is rendered |
| `encoding` | smuggle payloads via base64/rot13/etc. | filter-evasion |
| `malwaregen` | get the model to write malware | off-purpose abuse |
| `snowball` | questions that induce confident hallucination | recommender making up anime |
| `realtoxicityprompts`, `lmrc`, `continuation` | toxicity / harmful continuation | safety of responses |
| `glitch` | glitch tokens that destabilise the model | robustness |
| `atkgen` | an LLM *generates* adversarial turns live | adaptive red-team (this one uses an LLM) |

List everything: `garak --list_probes`  ·  detectors: `--list_detectors`  ·
generators: `--list_generators`  ·  buffs: `--list_buffs`.

Select granularity:
- whole module: `--probes promptinject`
- one class: `--probes dan.DanInTheWild`
- several: `--probes promptinject,latentinjection,dan.DanInTheWild`

---

## 4. Detectors — how "success" is judged

Most detectors are **rule-based** — no LLM judge needed:
- `promptinject.AttackRogueString` — did the injected marker string appear in the output?
- `dan.DAN` / trigger-list detectors — did the jailbreak compliance phrase appear?
- `knownbadsignatures` — did a known-bad token (EICAR/GTUBE) appear?

Some detectors load a **small local HuggingFace classifier** (e.g. toxicity) — runs
on CPU, downloaded once, still no external judge. A few probes (like `atkgen`) use a
**full LLM** — that's the only case where you'd point garak at **Groq** (§8).

---

## 5. Buffs — mutating the attacks (`--buffs`, optional)

Buffs transform each attack prompt to test robustness/evasion:
`--buffs encoding` (base64 etc.), `lowercase`, `charswap`, `paraphrase` (uses a model).
Off by default. Useful later for "does encoding slip past your defenses?"

---

## 6. CLI reference — the flags you'll actually use

```
--model_type       generator family      (rest | openai | ...)
--model_name       specific model/id     (for openai: llama-3.1-8b-instant)
-G / --generator_option_file  JSON config for the generator (rest/openai base url)
--probes           which attacks         (promptinject,dan.DanInTheWild)
-g / --generations N   variants per attack prompt (volume multiplier; keep 1 while iterating)
--parallel_attempts N  concurrency (speeds up; watch rate limits)
--report_prefix    output path prefix
--seed             reproducible runs
--eval_threshold   pass/fail cutoff for scored detectors
--list_probes / --list_detectors / --list_generators / --list_buffs
--config           a full YAML run config
```

Attack volume ≈ (prompts in the probes) × `--generations`. Start small.

---

## 7. Reading the report

Every run writes (under `--report_prefix`):
- **`*.report.jsonl`** — one line per attempt: probe, exact prompt, target response,
  detector verdict. The raw evidence.
- **`*.report.html`** — human view: **pass/resist rate per probe** (e.g.
  `promptinject: 12/15 resisted`). Open in a browser.
- **`*.hitlog.jsonl`** — only the *hits* (successful attacks) — your bug list.
- **`garak.log`** — run log.

The CI parses the `entry_type == "eval"` lines from the jsonl to compute the
resist-rate metric. A **hit = a vulnerability** (the app did the bad thing).

---

## 8. When garak needs an LLM (→ use Groq)

Rule-based probes (what we run) need no judge. But `atkgen` and a few model-based
detectors call an LLM. Point that at Groq with a generator option file:

```json
{ "openai": { "OpenAICompatible": {
  "uri": "https://api.groq.com/openai/v1",
  "model": "llama-3.3-70b-versatile",
  "api_key": "ENV"
} } }
```
Run with `OPENAI_API_KEY=$GROQ_API_KEY garak ... -G that_file.json`.

---

## 9. Recipes for the anime recommender

All target the app via `run.sh app` (generator = rest → `/recommend`):

```bash
# quick smoke (1 probe, fast)
PROBES=promptinject security/garak/run.sh app

# the RAG-relevant set
PROBES=promptinject,latentinjection,dan.DanInTheWild,leakreplay security/garak/run.sh app

# widen once green
PROBES=promptinject,latentinjection,dan,xss,encoding,leakreplay,snowball security/garak/run.sh app
```

`APP_URL` picks the target app (local container now, deployed endpoint later):
```bash
APP_URL=http://127.0.0.1:8600/recommend security/garak/run.sh app
```
