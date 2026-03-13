# Sidekick — Design Document

## Vision

A dead-simple, beautiful iOS notes app for researchers. You jot down ideas. An AI silently reads them, finds connections, pulls real open datasets, runs real analysis, and produces actual research papers. No chatbot. No prompt engineering. Just a clean notes app with intelligence woven into the fabric.

---

## Core Principles

1. **Notes-first, AI-invisible.** The UX is writing notes. The AI works silently.
2. **Dead simple.** Write notes. Read papers. That's it.
3. **Beautiful.** Liquid glass. iOS-native. Lightweight and fast.
4. **Real papers.** Actual data analysis, figures, citations — not proposals or hand-waving.
5. **No unnecessary scaffolding.** Models get better. Keep infra minimal. Don't over-build.

---

## User Flow

```
1. Open app → note list
2. Tap + → jot an idea (text or voice)
3. Notes accumulate
4. AI clusters ideas, decides when a thread is paper-ready
5. Codex task kicks off: downloads data, runs analysis, writes paper
6. Paper appears in Papers tab
7. Read, edit, export (PDF / LaTeX)
```

---

## Architecture

### The Stack

```
┌─────────────┐    OAuth PKCE    ┌───────────────────┐
│   iOS App    │ ──────────────→ │   OpenAI Auth      │
│  (SwiftUI)   │ ←── tokens ──── │                    │
│              │                  └───────────────────┘
│  Notes in    │
│  Papers out  │    Codex tasks   ┌───────────────────┐
│              │ ───────────────→ │   Codex Cloud      │
│              │ ←── results ──── │   Sandbox          │
└─────────────┘                   │  - Python env      │
                                  │  - Internet access  │
                                  │  - Full disk        │
                                  └───────────────────┘
```

**Phone** = thin client. Captures notes, displays papers.
**OpenAI Codex** = all compute. Runs on OpenAI's cloud VMs, paid by user's ChatGPT subscription.
**No backend.** The phone talks directly to OpenAI.

### Auth — ChatGPT OAuth (OpenClaw Pattern)

User taps "Sign in with ChatGPT" → OAuth PKCE flow → tokens stored in Keychain → auto-refreshed. Their ChatGPT subscription covers all usage. Zero cost to us.

### Codex Cloud Sandbox

When the AI decides to write a paper, it submits a Codex cloud task. The task runs in an isolated container on OpenAI's infra with:

- Full Python environment (pandas, scipy, statsmodels, matplotlib, etc.)
- Internet access (enabled per-environment for dataset downloads)
- Disk access for data processing
- Can run for hours

The sandbox is the same whether triggered from chatgpt.com, the CLI, or programmatically. We get the full environment.

The app calls OpenAI's REST APIs directly from Swift. No SDK wrapper, no relay server, no backend.

### The Heartbeat

The AI doesn't fire on every note. A periodic process ("heartbeat") runs on a schedule:

1. Collect recent notes
2. Send to AI for clustering and paper-readiness assessment
3. If a cluster is ready → submit Codex task
4. When task completes → push notification to phone

**Triggers:** On app open + iOS Background App Refresh (iOS wakes the app periodically in the background, ~every few hours). No server needed. The user gets a surprise notification when a paper is ready.

**The AI decides when to write.** No hand-tuned heuristics. The LLM judges whether a cluster of notes has enough coherence, specificity, and available data to produce a real paper. Threshold should be eager — better to draft than sit on ideas.

---

## Open Datasets — Real Analysis

Codex downloads and processes real data inside its sandbox. The AI should know about these sources:

| Source | What | Access |
|--------|------|--------|
| PubMed / PMC | Biomedical literature | NCBI E-utilities API |
| arXiv | Preprints | arXiv API |
| Semantic Scholar | Citations, metadata, abstracts | API (100 req/sec) |
| OpenAlex | Scholarly works, authors, concepts | API (no key needed) |
| Zenodo | Research datasets | REST API |
| HuggingFace Datasets | ML/NLP datasets | `datasets` library |
| data.gov | US government data | API |
| WHO / World Bank | Health + economic indicators | APIs |
| UniProt | Protein data | REST API |
| NCBI GEO | Gene expression | API |

All free. No keys needed for most.

### Large Dataset Strategy

Codex sandboxes have finite disk and memory. We can't download a 50GB genomics database. The strategy is simple:

1. **API-first.** Query dataset APIs for exactly what's needed. Most sources above support filtered queries — pull the relevant subset, not the whole thing.
2. **Sample when necessary.** If a dataset is too large, sample it. A well-chosen sample with proper statistical methods is valid science.
3. **Use summary endpoints.** Many APIs provide pre-aggregated statistics. Use those instead of recomputing from raw data.
4. **Fail gracefully.** If a dataset is genuinely too large, the paper should acknowledge the limitation and describe the methodology for full-scale analysis. A paper with partial analysis + clear methodology is still valuable.

This is a prompt engineering problem, not an infrastructure problem. The system prompt instructs Codex to prefer API access and intelligent subsetting over bulk downloads. As models improve, they'll get better at this naturally — no scaffolding needed.

---

## Paper Output

Each Codex task produces:
- **Paper** — full text in Markdown (title, abstract, intro, methods, results, discussion, references)
- **Figures** — PNG charts/plots from real data analysis
- **Tables** — statistical results, dataset summaries
- **Code** — the Python used for analysis (optional appendix, for reproducibility)
- **Bibliography** — real citations from Semantic Scholar / OpenAlex

Export formats: PDF, LaTeX.

**Quality expectation:** Strong first drafts with real data. Not Nature-ready, but a massive head start. The researcher reviews, refines, and validates.

---

## Cost

| Component | Cost |
|-----------|------|
| iOS app (Apple Dev Program) | $99/yr |
| Note storage (on-device SwiftData) | Free |
| AI + compute (user's ChatGPT subscription) | Free to us |
| Dataset APIs | Free |
| **Total cost to us** | **$99/yr** |
| **Cost to user** | **$20/mo ChatGPT Plus** (they likely already have it) |

---

## Open Questions

1. **Note format?**
   Plain text with optional tags. Don't over-structure.

3. **Voice input?**
   Yes, MVP. iOS speech-to-text is free and built-in.

5. **Codex task failures?**
   Produce whatever is possible. Partial paper > no paper. Flag gaps clearly.

---

## MVP Scope

### In
- SwiftUI notes app (write, list, delete, search)
- Voice-to-text input
- ChatGPT OAuth sign-in (PKCE)
- Heartbeat: AI note clustering + paper-readiness assessment
- Codex paper generation with real dataset analysis
- Papers tab with figures
- PDF + LaTeX export
- Push notifications when papers complete

### Out
- Android
- Multi-user / collaboration
- In-app paper editing
- On-device inference
- Proprietary dataset integration

---

## Tech Stack

| Layer | Tech |
|-------|------|
| App | SwiftUI, SwiftData |
| Auth | OAuth 2.0 PKCE (OpenAI) |
| Secrets | iOS Keychain |
| AI | OpenAI REST APIs (direct from Swift) |
| Paper rendering | Markdown + WKWebView |
| Export | PDF generation + LaTeX templating |
| Notifications | APNs |

---

## Build Order

1. Finalize this design
2. SwiftUI app shell (notes CRUD + tabs)
3. ChatGPT OAuth flow
4. Heartbeat (clustering + paper-readiness + background app refresh)
5. Paper generation pipeline
7. Paper display + export
8. Push notifications
9. Polish (liquid glass, animations, haptics)
10. TestFlight → App Store
