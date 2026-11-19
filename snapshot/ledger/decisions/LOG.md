# Decision Log

> Architecture and design decisions for AbletonSampler.
> Format: one entry per decision, newest first.

<!--
## TEMPLATE

### DEC-NNN: [Title]
**Date:** YYYY-MM-DD
**Status:** Accepted / Superseded by DEC-NNN / Revisiting
**Context:** What prompted this decision.
**Decision:** What was decided.
**Consequences:** What follows from this decision.
-->

### DEC-001: Stop tracking `build/` artifacts; purge 308 MB AudioKit pack from history
**Date:** 2026-07-10
**Status:** Accepted
**Context:** The repo could not be backed up — every automatic push was rejected by GitHub's 100 MB per-file limit. The cause was a 308 MB AudioKit Swift-Package pack file (`build/SourcePackages/repositories/AudioKit-*/objects/pack/*.pack`) committed inside the tracked `build/` directory, which also held a stray nested AudioKit git checkout that jammed merges. The branch had diverged (local ahead, unpushed) and could not publish.
**Decision:** Untracked the entire `build/` directory (`git rm -r --cached build/`) and added `build/` to `.gitignore`. Dropped the 308 MB pack out of the unpushed history by soft-resetting the diverged local commits onto `origin/main` and recommitting without the blob. The 27 Swift source files (~5,067 insertions) carried on the local commits were preserved through the reconciliation. Pushed `bad2fe2..dd20182` on `main`.
**Consequences:** The repo backs up cleanly again. Xcode build artifacts and SPM checkouts are no longer versioned (they regenerate on build); a fresh clone builds rather than pulling stale build products.
