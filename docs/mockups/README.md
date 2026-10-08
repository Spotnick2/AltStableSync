# Interactive concept

Open `interactive.html` in a modern browser. No installation, server or account is required. The exported concept has no external script dependencies; decorative icons were omitted for portability.

The outer Main window / New character controls switch demo scenes. Inside, try UI setup, specialization pickers, Load, Save, Save As, Cancel, Backups and Restore. Changes last only for the current page session.

`source.html` is the editable fragment behind the export. Use the written UX and safety documents when implementing actual Lua behavior.

## Deliberate limits

- This is a visual simulation, not game state or addon code. Save messages and backups simulate outcomes; no real spell, macro, binding, provider or persistence logic runs.
- The interactive sample uses a priest. The PDF/PNGs add empty-library, druid and annotated safety stories.
- Listed UI/addon preferences illustrate the desired product. They are not a claim that those providers are implemented or verified.
- Binding destination is shown, but inactive-set blocking, combat, readiness, macro capacity, stale revisions, partial failure and exact restore verification are specified in the docs rather than fully simulated.
- Production prompts belong to AltStableSync's own frame. No StaticPopup.
- Category selection does not change talents. Lists are manual categories on Forever.

## Differences from the design (`docs/DESIGN.md` wins)

- **Save** is always enabled in the mockup and is shown keeping unlearned content. In the design,
  Save is disabled until #28. After that, it is allowed only over the entry this character loaded,
  at its loaded version. Before #28, Save As is a fresh capture that warns about dropped entries.
- The duplicate-name error says "use Save"; in the design that is only possible for the loaded entry.
- Conflicts, sync status, the "operation" backup, and Restore's "remove macros that load created"
  are not shown.
