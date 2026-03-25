# Overnight Notes

## Priority Order

1. Keep the iOS app stable and reduce app-owned runtime noise so Xcode/simulator logs are only used when strictly necessary.
2. Make the paper path fail closed on real-data quality:
   - resolver output must be authoritative for empirical runs
   - no synthetic/proxy/literature-parameterized stand-ins for empirical papers
   - every requested note should be covered by at least one validated finding
3. Tighten the CLI loop so backend and paper-quality debugging can happen from terminal first.
4. Expand discovery breadth only if the stricter gate is in place and real-data resolution is still too narrow.

## App Changes Already Landed Locally

- Removed `Research Inputs` from the iOS app UI and app wiring.
- Deleted:
  - `Sidekick/Sidekick/Services/ResearchInputStore.swift`
  - `Sidekick/Sidekick/Views/ResearchInputsView.swift`
- Manual note prioritize now persists `priorityRequestedAt` on `Note` and the heartbeat consumes that intent directly.
- Auto-submission now uses submission-safe clusters instead of presentation clusters.
- Unknown readiness now fails closed as `needs_data`.
- Removed the explicit `UIImpactFeedbackGenerator` call from note prioritization to cut app-owned haptic log spam.

## Backend Quality Changes Already Landed Locally

- `PaperPipelineEngine` can now resolve request payloads through `SourceFamilyResolver`.
- Empirical runs block before workspace execution if no qualifying dataset is resolved.
- Explicit resolver `dataset_ids` are now preserved end-to-end instead of getting dropped after note assessment.
- Workspace prompt now requires `note_ids` on every result.
- Validation now checks:
  - artifact-backed results
  - reproducible source receipts
  - note coverage for requested notes
  - required primary dataset usage for empirical runs
  - broader banned language around synthetic/proxy/literature-parameterized work
- Server note assessment now uses the resolver instead of the trivial first-token bucket.
- Server `/api/papers` now attaches resolution metadata and rejects blocked empirical runs.

## CLI Changes Already Landed Locally

- `python -m paperlab.cli runs --limit 10`
  - Lists recent runs with manuscript kind, approved-result count, missing-note count, paper mode, resolution status, primary dataset, and last event.
- `python -m paperlab.cli resolve --notes '...' --title '...'`
  - Runs resolver-only dataset/source-family selection without touching Xcode or the simulator.
- `python -m paperlab.cli app-state summary|notes|papers|runs`
  - Reads the Sidekick simulator SwiftData store from the main CLI, including persisted note priority timestamps and queued paper runs.
- `paperlab inspect` now prints resolution metadata and missing-note counts when available.
- `paperlab validate` now reuses `input.json` so validation reruns include resolution + note coverage context.

## Useful Commands

### iOS

- `python -m pytest github_bootstrap_service/tests/test_pipeline_engine.py github_bootstrap_service/tests/test_publication_gate.py github_bootstrap_service/tests/test_resolver.py -q`
- XcodeBuildMCP simulator build for `Sidekick` on `iPhone 17`

### CLI

- `python -m paperlab.cli runs --limit 10`
- `python -m paperlab.cli latest`
- `python -m paperlab.cli inspect latest`
- `python -m paperlab.cli validate latest`
- `python -m paperlab.cli resolve --notes '...' --title '...'`

## Open Items

- Use the fleshed-out CLI as the primary overnight loop so simulator/Xcode usage stays minimal.
- Pressure-test `paperlab.cli resolve` on broad/niche empirical prompts to see whether discovery breadth, ranking, or timeouts still need work.
- Prefer `paperlab app-state` over manual simulator inspection when checking whether a note was persisted, prioritized, or turned into a queued run.
- If resolver breadth is still the bottleneck after the fail-closed gate, widen `source_families.json` coverage and/or improve resolver query variants.
- Add more CLI affordances once the core quality issues are stable:
  - richer run summaries
  - status/watch mode
  - explicit resolution diagnostics
  - clearer approval/memo reasons

## Verification Snapshot

- `pytest` subset currently passing:
  - `github_bootstrap_service/tests/test_pipeline_engine.py`
  - `github_bootstrap_service/tests/test_publication_gate.py`
  - `github_bootstrap_service/tests/test_resolver.py`
- iOS simulator build currently succeeds for `Sidekick`.
