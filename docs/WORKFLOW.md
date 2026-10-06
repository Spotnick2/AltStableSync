# Working on AltStableSync

Single maintainer, so this is light. Two steps are non-negotiable: the Codex review, and the
owner's approval before any merge.

## The loop

```
issue  ->  branch  ->  PR  ->  Codex review  ->  address  ->  OWNER APPROVAL  ->  merge
```

1. **Pick an issue.** Milestones: M0 Foundation, M1 Nov 4 MVP, M2 UI and modules, M3 Reach,
   M4 Addon settings. `docs/forever-api-notes.md` is measured — treat it as fact.
2. **Branch off `main`**, named for the milestone and issue: `m1/vertical-slice`, `m1/macros`.
   Never commit directly to `main`.
3. **Before pushing:** `luac -p` clean on every changed Lua file
   (`C:\Program Files (x86)\Lua\5.1\luac.exe`), `pwsh tests/run.ps1` green.
4. **Open a PR** with `Closes #N`.
5. **Run the Codex review** (below) and post the verdict as a PR comment.
6. **Address or rebut** each finding in the thread.
7. **Stop.** Report the PR link and the review link. The owner merges, or says to.

Anything that writes game state (bars, macros, bindings, Edit Mode, CVars) or changes the
SavedVariables shape also needs an **in-game check** listed in the PR description, with a full
client exit where persistence is claimed.

## Codex review on a PR

Codex is a different model family — the value is decorrelated blind spots. It is a local CLI; the
review is generated locally and posted to the PR for the record. Details and gotchas are in
`.claude/skills/codex-consult/SKILL.md`.

```bash
git fetch origin main
git diff origin/main...HEAD > "$SCRATCH/pr.diff"
# write $SCRATCH/codex-prompt.txt (shape below)
timeout 420 codex exec \
  -c model_reasoning_effort=medium \
  --ephemeral --skip-git-repo-check -s read-only \
  -o "$SCRATCH/codex-verdict.md" \
  < "$SCRATCH/codex-prompt.txt" > "$SCRATCH/codex-progress.log" 2>&1
gh pr comment <N> --body-file "$SCRATCH/codex-verdict.md"
```

- Prompt **on stdin** (`< file`); a bare argument hangs forever in a non-TTY.
- Answer from `-o`, not stdout. `--ephemeral` always.
- Never tell it both "review the code" and "do not run commands" — it reads files by running them.

### Prompt shape

- **Established facts** it must not re-litigate: interface 16001, Vanilla on the Mainline client,
  the measured API notes, the safety rules in `AGENTS.md`.
- The **files to read**, by path, and the diff.
- **Numbered questions**, silent data destruction first, style last. For this addon the first
  question is always: *what in this change can destroy or silently alter the player's setup, and
  would the backup restore it exactly?*
- A closing note: single-maintainer personal addon, right-size — except the safety rules.

### Reconciling

Take bug-catching seriously; be skeptical of added abstraction. It comes in cold: feed it the
snapshot-vs-profile split, the macro ownership rules, binding-set selection, and what is
deliberately deferred.

## Fallback

If `codex` is unavailable, use Fable for the adversarial pass and say so on the PR.
