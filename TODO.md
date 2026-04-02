# TODO

Known issues, dead code, and improvement opportunities found during codebase review (April 2026).

## Dead Code & Unused Files

- [ ] **`AuthService.swift` is dead code.** References an old OpenAI OAuth/ChatGPT authentication flow that was never connected. The app uses `GitHubService` for all auth. Safe to delete entirely.

- [ ] **`LocalPaperGenerationService.swift` is a stub.** Always returns `false` for support and `nil` for generation. Never called anywhere. Was a placeholder for on-device paper generation. Delete or implement.

- [ ] **`ResearchStageFallbackService.swift` is rarely triggered.** Only handles 3 specific datasets (GBM cBioPortal, MAST observations, Cellxgene). Uses hardcoded compressed CSV payloads. Consider whether this fallback complexity is justified or if the main pipeline handles these cases now.

- [ ] **`design.md` is stale.** References OpenAI OAuth PKCE flow, "ChatGPT subscription" cost model, and "no backend" architecture — all of which have been replaced. Either update to match reality or mark as historical.

- [ ] **`OVERNIGHT_APP_REWIRE_AGENT_MEMORY.md`** and **`overnight-notes.md`** are working notes that should be archived or deleted before handoff. They contain useful context about recent pipeline work but aren't structured documentation.

- [ ] **`docs/PIPELINE_REWRITE_SPEC.md`** and **`docs/OVERNIGHT_DATA_ACCESS_PLAN.md`** — Check if these specs have been fully implemented. If so, mark as historical. If not, extract remaining TODOs into this file.

## Backend Issues

- [ ] **`openai_reasoning_effort` is always empty string** in `config.py` defaults. This feature flag appears unused. Either implement or remove.

- [ ] **Hardcoded golden dataset path** in `paper_quality.py`. References `/Users/vineetreddy/Documents/GitHub/test_sidekickdata` which won't exist on other machines. Make this configurable via env var or CLI argument.

- [ ] **Duplicate artifact normalization.** `_normalize_artifact()` exists in both `server.py` and `pipeline_engine.py`. Consolidate into one shared function.

- [ ] **No OpenAI container cleanup.** After a job completes, the OpenAI containers (compute boxes) used during code interpretation are not explicitly cleaned up. May accumulate over time.

- [ ] **No background job heartbeat** for long-running container operations. If the OpenAI code interpreter hangs, the only protection is the 3600s job timeout.

- [ ] **Cost estimation uses fixed token prices** ($0.25/M input, $2.0/M output). These should be configurable or updated as model pricing changes.

- [ ] **Single GitHub connection per install session.** No support for multiple GitHub accounts. This may be fine for MVP but limits future flexibility.

- [ ] **`__pycache__` directories** are tracked in some places. Add `__pycache__/` to `.gitignore` more aggressively or run a cleanup.

## iOS App Issues

- [ ] **PDF rendering is slow.** `PaperDocumentService` waits up to 6 seconds for `document.readyState === "complete"`. No timeout or failure recovery for individual image loads. If images fail to load, the PDF may have blank spaces.

- [ ] **Figure recovery is fragile.** If PNG normalization fails during precompute, the figure is silently dropped. The user sees a paper with missing figures and no explanation.

- [ ] **Heartbeat force flag bypasses cooldown** with no rate limiting. A user rapidly tapping the sync button could trigger many rapid backend calls. Consider debouncing.

- [ ] **Deletion cascades are incomplete.** Deleting a note removes it from associated papers/runs, but doesn't re-generate papers that depended on that note. User must manually understand the dependency.

- [ ] **Export metadata cached only by taskID.** No versioning or invalidation beyond file modification date. If a taskID were ever reused (shouldn't happen, but), stale metadata would be returned.

- [ ] **Light theme only.** App forces `.preferredColorScheme(.light)`. No dark mode support.

- [ ] **No voice input yet.** `design.md` lists voice-to-text as MVP scope, but it hasn't been implemented. iOS speech-to-text APIs are readily available.

- [ ] **No offline support.** If the backend is unreachable, the heartbeat silently fails. No user-visible indicator of connectivity issues beyond the settings "last sync error" field.

## Pipeline Quality

- [ ] **Metadata-only papers are still possible.** The pipeline sometimes produces papers that describe datasets rather than running real analysis on them. The `OVERNIGHT_DATA_ACCESS_PLAN.md` documents ongoing work to fix this. The validation step checks for banned phrases but doesn't verify that real computation occurred.

- [ ] **Manuscript bundle structure not validated against a schema.** A malformed bundle from the LLM can cause downstream failures without clear error messages.

- [ ] **No explicit retry logic for failed LLM stages.** If Stage 2 (research workspace) fails, the entire job fails. Consider stage-level retries with backoff.

- [ ] **Bibliography mode inconsistency.** `manuscript.py` supports both `thebibliography` and BibTeX, but the pipeline doesn't consistently choose. Papers may have mismatched reference formats.

## Testing

- [ ] **No iOS unit tests.** The Swift code has no XCTest targets. The services layer (HeartbeatManager, TrustedDatasetRegistry, OpenAIService) would benefit from unit tests with mocked backends.

- [ ] **No integration test for the full pipeline.** Individual backend modules are well-tested (3700 lines of pytest), but there's no end-to-end test that submits a note and verifies a paper comes out.

- [ ] **Test golden data path is hardcoded.** See hardcoded path issue above.

## Infrastructure

- [ ] **Backend runs on Render Starter plan.** This is a single instance with no redundancy. If the service goes down during a paper job, the job is lost. Consider health monitoring/alerting.

- [ ] **SQLite as production database.** Fine for current scale but doesn't support concurrent writes well. The multi-threaded server uses `check_same_thread=False` which works but isn't ideal.

- [ ] **No database migrations.** Schema changes require manual intervention or database recreation. Consider adding a migration system as the schema evolves.

- [ ] **No log aggregation.** Backend logs go to stdout (captured by Render). No structured logging or log shipping for debugging production issues.

- [ ] **`.env` secrets management.** Production secrets are set via Render's UI. No documentation of which secrets exist or how to rotate them.

## Code Quality

- [ ] **Inconsistent error handling across services.** Some Swift services use `throws`, others swallow errors with `print()` statements. Standardize on a logging/error strategy.

- [ ] **Mixed concurrency models.** `HeartbeatManager` is an actor, `GitHubService` and `OpenAIService` are `ObservableObject`s, and `PaperDocumentService` uses static methods. Consider standardizing.

- [ ] **Large files.** `HeartbeatManager.swift`, `OpenAIService.swift`, `pipeline_engine.py`, and `server.py` are each 500+ lines. Consider breaking these into smaller, focused modules.

- [ ] **QA/debug flags in production code.** Several views check for `QA_*` environment variables. These should be behind a compile-time flag (e.g., `#if DEBUG`) to ensure they can't be triggered in release builds.
