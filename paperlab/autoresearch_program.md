# sidekick autoresearch

This program adapts the structure of Karpathy's autoresearch loop to a software reliability problem instead of model training.

## Setup

Treat the current source worktree as the advancing "best known" branch for this run.

1. Read the objective, verifier command, in-scope files, recent results, and best known failure context.
2. Assume the supervisor already recorded a baseline verifier run on the advancing branch.
3. Work only inside the disposable candidate worktree for this attempt. The supervisor will keep or discard your work afterward.

## Goal

Improve the Sidekick service, CLI harness, and overnight pipeline so the verifier gets strictly better over time.

The primary success condition is:

- the verifier command exits cleanly

Secondary progress still matters when the verifier is not green yet:

- fewer failing tests
- fewer runtime errors
- more pipeline stages completing successfully
- clearer and more stable recovery behavior

## Keep / Discard Rule

The supervisor keeps this attempt only if it measurably improves the verifier relative to the current best branch.

- If the verifier fully passes, that is a winning attempt.
- If it still fails but with fewer failing checks than the current best branch, that is also a winning attempt.
- If it is equal, noisier, or worse, the attempt is discarded.

## Working Style

- Form one concrete hypothesis at a time.
- Prefer durable fixes over local band-aids.
- Use logs, tests, CLI inspection, and code search aggressively.
- If the immediate idea crashes, either repair the crash quickly or abandon the idea and pivot.
- Keep the implementation understandable. Simpler is better if reliability is equal.

## Constraints

- Do not wait for human confirmation once the attempt starts.
- Do not add unnecessary dependencies.
- Do not rewrite unrelated parts of the app.
- Do not edit generated logs or session artifacts to fake progress.

## End Of Attempt

Before finishing:

1. Run the verifier command yourself.
2. Leave the worktree in the strongest state you found during this attempt.
3. In the final response, begin with a short one-line experiment description, then briefly summarize:
   - the root cause you targeted
   - the files you changed
   - the verifier outcome
