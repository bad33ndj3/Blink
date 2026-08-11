# Issue tracker: Local Markdown

Issues and specs for this repo live as markdown files under the global scratch root: `~/.scratch/blink/<branch>/` (no git repo yet — use `main` until a real branch exists).

## Conventions

- One feature per directory: `~/.scratch/blink/<branch>/<feature-slug>/`
- The spec is `~/.scratch/blink/<branch>/<feature-slug>/spec.md`
- Implementation issues are one file per ticket at `~/.scratch/blink/<branch>/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01` — never a single combined tickets file
- Triage state is recorded as a `Status:` line near the top of each issue file (see `triage-labels.md` for the role strings, if present)
- Comments and conversation history append to the bottom of the file under a `## Comments` heading

## When a skill says "publish to the issue tracker"

Create a new file under `~/.scratch/blink/<branch>/<feature-slug>/` (creating the directory if needed).

## When a skill says "fetch the relevant ticket"

Read the file at the referenced path. The user will normally pass the path or the issue number directly.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a file with one **child** file per ticket.

- **Map**: `~/.scratch/blink/<branch>/<effort>/map.md` — the Notes / Decisions-so-far / Fog body.
- **Child ticket**: `~/.scratch/blink/<branch>/<effort>/issues/NN-<slug>.md`, numbered from `01`, with the question in the body. A `Type:` line records the ticket type (`research`/`prototype`/`grilling`/`task`); a `Status:` line records `claimed`/`resolved`.
- **Blocking**: a `Blocked by: NN, NN` line near the top. A ticket is unblocked when every file it lists is `resolved`.
- **Frontier**: scan `~/.scratch/blink/<branch>/<effort>/issues/` for files that are open, unblocked, and unclaimed; first by number wins.
- **Claim**: set `Status: claimed` and save before any work.
- **Resolve**: append the answer under an `## Answer` heading, set `Status: resolved`, then append a context pointer (gist + link) to the map's Decisions-so-far in `map.md`.
