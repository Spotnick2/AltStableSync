# Damage meter part — implementation plan

Owner request: Part of #10. Explicit Save/Save As records a UI setup which, on confirmed
Apply, configures window 1 and opens/configures window 2. The default second window is
Healing Done; both use Current Segment. No login/event/sync receipt applies anything.

## Evidence and scope

Read Gethe/wow-ui-source, live at b9be9379719047977fca4dba1bb1d9988e8840b3
(Mainline 12.1.5 build 70448), Blizzard_DamageMeter/DamageMeter.lua,
DamageMeterSessionWindow.lua and .xml. These methods and their addon-call safety and
persistence are NOT measured on Forever. Runtime capability checks fail closed with
"not supported on this build". Never load Blizzard UI just to capture or plan.

- The manager GetSessionWindow(index) and GetWindowDataList() expose runtime state.
  Never access or assign DamageMeterPerCharacterSettings.
- Manager setters own persistence: SetSessionWindowDamageMeterType(window, type),
  SetSessionWindowSessionID(window, sessionType, id), SetSessionWindowLocked(window, bool).
  Window getters provide independent read-back; sessionID is ephemeral and is never
  put into a portable catalog entry. This version conservatively skips applying the meter
  part when either existing window selects a specific encounter (non-nil sessionID or
  nil sessionType). Ask the player to select Current/Overall first. Thus every touched
  selection has a durable enum-based exact backup; ID-based snapshots are unavailable.
- ShowNewSecondarySessionWindow() first reuses a hidden window-data slot, then allocates
  an unused one. Predict with its GetAvailableSecondarySessionWindowIndex() and
  GetAvailableSecondaryWindowDataIndex(), require index 2 before every open; never touch 3.
- HideSessionWindow is permitted only to undo a secondary window this operation actually
  opened. Never hide primary or a secondary already shown before Apply.
- Primary geometry belongs to Edit Mode; do not change its anchors or dimensions. Explain
  that its position/size travel through the existing layout selection. Secondary geometry
  is optional: only ordinary finite numbers, one anchor to UIParent, no minimized/resizing
  state, matching effective scale, and available frame geometry methods. Otherwise capture/configuration still works
  without geometry, with a visible note. Opening an existing hidden frame needs readable
  geometry because Blizzard SetupSessionWindow resets its placement.

## Data and lifecycle

1. Add an optional modules.damageMeter = { windows = { [1] = { meterType, sessionType = 1,
   locked }, [2] = { meterType, sessionType = 1, locked, geometry? } } }.
   Capture actual types/locks for shown windows; if second is absent/hidden, record a
   clearly previewed Healing Done/Current/unlocked second window, without inventing its
   position. First normally captures Damage Done. Both catalog sessions are Current,
   as explicitly requested. Leave third window untouched. Existing setups gain this part
   via Save As; Save updates only parts already present, preserving skipped data.
2. Catalog validates required windows 1/2 and every known field, finite numeric domains,
   booleans, and optional geometry. Reject malformed known data on create/replace/receipt.
   Keep unknown named keys in this part and window records through Save. A future meter
   type remains stored but is skipped when absent from runtime Enum.DamageMeterType.
3. Put the small client adapter in DamageMeter.lua, loaded before UISetup.lua. Integrate
   Capture/Plan/Describe/Contents/Snapshot/Execute/PlanRestore/Save into UISetup's existing
   transaction. No new generic transaction framework. An unavailable part is a visible
   skip and does not prevent other parts working. Failed or skipped meter capture must
   never erase saved intent. Geometry unavailable on a particular target stays in the entry.
4. Plans carry copied from/to state and allocator dependencies, all in the fingerprint.
   Re-plan at confirmation and refuse stale state. Snapshot only touched windows and
   fields before any write; make a backup failure abort all writes. Recheck meter state
   immediately before executing (earlier layout/CVar writes can cause side effects).
5. Execute after existing parts. Guard combat/Edit Mode before EACH public mutation.
   Use manager methods for types, session, lock, opening and hiding. Verify actual frame
   values plus manager state, never treat a failed read as a default. Stop and keep the pin
   on failure; record loaded.ui incomplete before the first write as existing code does.
   Successfully read nil IsLocked/IsMinimized/IsResizing means false, as in Mainline.
   Missing methods, exceptions, secret values and other types are failures, never false.
   Current/Overall must have a successfully read nil sessionID; an encounter's nil
   sessionType is legitimate but unsupported for mutation in this first version.
6. Snapshot records prior shown/configuration/geometry plus an opened-window journal.
   Journal only after observing a formerly hidden/absent window become shown through our
   open attempt (even if the method threw after doing so). If the post-open read fails,
   leave ownership uncertain and keep restore partial rather than guessing it can hide.
   A hidden data slot without a readable frame is unsupported for opening, because its
   previous geometry/configuration cannot be backed up faithfully.
   The journal is shared with the corresponding firstSeen copy at insertion time, so
   subsequent journal writes reach both backups; unrelated backups remain independent.
   Serialized backups retain each journal's contents. Execute receives the actual stored
   snapshot reference, never a ring index that can shift.
7. Restore restores snapshot fields exactly (prior Current/Overall and nil sessionID), hides
   window 2 only when the source snapshot's journal proves this operation opened it, and
   leaves window 3 alone. Record a new pre-restore snapshot first using the existing ring
   mechanism. Restoring that snapshot can reopen a window the restore hid; it uses the same
   checked allocator and guards. If an exact target cannot be reached, report unavailable
   and keep the original operation pinned. Unknown/newer schema remains refused.
8. Geometry uses a UIParent-coordinate rectangle and userPlaced flag. Prefer updating the
   window's existing single anchor with equivalent offsets (no ClearAllPoints gap), then
   size/userPlaced with guards/read-back. Check fit and finite screen bounds, never move
   a frame off-screen to copy another resolution. Snapshot restore restores physical
   position/size and userPlaced, not the spelling of equivalent anchor points. Source XML
   secondary limits are 200–600 wide, 120–400 high; check runtime bounds if available.
9. Bump schema 10/11 to 12: an older build would ignore a damage-meter field in a UI backup,
   call it fully restored and release the operation. The migration is a stamp only; old
   entries/backups are unchanged. Add explicit schema upgrade/refusal tests.

## Validation and delivery

- Lua 5.1 syntax check changed Lua files; full pwsh tests/run.ps1 before commit.
- Tests use source-shaped meter stubs in tests/wow_ui.lua and dedicated meter cases:
  no writes during capture/plan/events; intended second window; Current both windows;
  getters and exact undo; stale preview/state; missing APIs; failed reads; failed writes;
  combat between each class of write; pin ownership including failure after open; undo
  restore; allocator chooses 3 refusal; geometry/secret/nil rejection; Save preservation;
  malformed catalog payloads; old-schema compatibility; no Blizzard global/SV writes.
- Deliberately mutate each added safety rule and require failing tests; record results.
- PR includes this plan and the CONSENSUS verdict from codex exec -m gpt-6-astra
  -c model_reasoning_effort=high. Review plan in rounds, address accepted findings without
  asking again; keep it small for one maintainer. Owner handles PR code review and merge.
- In-game check on Forever: capability detection, no taint, Damage Done + Healing Done,
  Current on both, lock and safe secondary placement/size, existing third window unchanged,
  stop in combat, exact restore (only our opened second hides), full exit and restart,
  and undo of restore. Mainline source/stub success does not prove any of these on Forever.

## Plan review and implementation checks (2026-10-22)

Requested reviewer: `codex exec -m gpt-6-astra -c model_reasoning_effort=high`,
ephemeral/read-only, bounded to 420 seconds per round.

- Round 1: **REVISE**. Accepted all three findings: nullable flags versus failed reads;
  propagate the opened journal to firstSeen; bound ephemeral encounter restoration.
- Round 2: **CONSENSUS** on the revised plan, including conservative encounter skipping.
  The reviewer explicitly left implementation testing and Forever validation outstanding.
- Publishing discovered two earlier Claude WIP commits on the remote branch, using schema
  11 and a different `meter` field. Preserve that branch ancestry; this implementation uses
  schema 12 so the draft refuses its files. Upgrade 11 by stamp, retain draft catalog data
  as an unknown part, and mark draft `meter` backups unavailable/partial without releasing
  their pin. No automatic migration of the incompatible draft representation.
- Round 3: **CONSENSUS** on this narrow handoff/schema adjustment. Explicit abandonment
  still follows the existing rule; a partial restore cannot automatically release the pin.
- Implemented in the existing transaction. Primary hidden means a visible skip (never
  mistake it for permission to allocate another secondary). A configuration-only backup
  excludes untouched geometry. Hiding also requires readable geometry for undo-of-restore.
- Lua 5.1 focused tests exercise source-shaped separate manager/frame values, actual
  Mainline enums (HealingDone = 2), unset lock/minimized/resizing fields, stale confirmation,
  failed backups/reads/writes, post-open exceptions, serialized first/ring ownership,
  unknown ownership, hidden-slot allocator priority, Current/Overall exact restore,
  geometry, Save preservation, malformed create/replace/receipt, and no Blizzard writes.
- Mutation checks: deliberately broke and observed failing behavioral assertions for
  confirmation fingerprint, backup before apply, backup before restore, combat guards,
  independent frame read-back, firstSeen ownership, hide ownership, uncertain opening,
  allocator isolation, fresh snapshot, execution recheck, nullable lock fidelity,
  strict visibility, catalog validation, future-intent preservation, Blizzard global
  assignment prohibition, Blizzard settings write prohibition, schema boundary, no writes
  during capture, missing-API skipping, exact snapshot contents, geometry bounds, pin
  retention on stop, and the ephemeral-encounter boundary.
  All 24 mutations were removed; the final suite runs against the restored implementation.

The constants source is also pinned:
[DamageMeterConstantsDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/b9be9379719047977fca4dba1bb1d9988e8840b3/Interface/AddOns/Blizzard_APIDocumentationGenerated/DamageMeterConstantsDocumentation.lua).

### Forever placement follow-up (2026-10-22)

The owner measured readable rectangles, matching scales and a single UIParent anchor,
but missing IsMinimized/IsResizing/IsUserPlaced getters. Rectangle setters and
IsMouseButtonDown exist. The narrow adjustment received **CONSENSUS** from the same
requested Astra high plan reviewer:

- Check optional minimized/resizing getters when present; failed getters still reject.
  Without IsResizing require a successful false left-mouse-button read before geometry
  capture and each placement mutation. Retain full-size bounds, anchor, scale and readback.
- Make geometry.userPlaced optional; never invent a false value or write an absent flag.
  Capture/apply/restore rectangles while leaving an unreadable flag untouched.
- An explicit saved flag remains intent and cannot be applied where unreadable. Save
  preserves it. On a client with the getter, rectangle-only writes still leave it alone.
- Skip reopening a hidden existing frame when its flag cannot be backed up, because
  Blizzard opening resets it. Likewise refuse hiding without a flag snapshot for undo.
  New allocation has no prior flag to restore. Partial restores retain their pin.
- Source probe transcripts are in docs/forever-api-notes.md. Full-exit persistence and
  taint safety of rectangle writes remain in-game checks, not stub-backed claims.
- Validation: 156 focused assertions and the full Lua 5.1 suite pass. Nine follow-up
  mutations were caught: requiring missing getters, accepting unsafe mouse reads,
  inventing a flag, opening/hiding with an unreadable flag, dropping explicit flag intent,
  omitting the immediate mouse guard, releasing a partial restore's pin, and allowing
  collapsed geometry. Every mutation was removed before the final suite run.

### Screen-relative placement follow-up

The capture diagnostic exposed the anchor restriction as the next rejection. Accept
a single screen-relative anchor (nil relative frame) as well as UIParent. Continue to
require matching effective scales, a finite in-bounds rectangle and all existing guards.
Apply updates the same anchor point through UIParent; restore recovers the snapshotted
physical rectangle, as already specified, without promising the original anchor spelling.
Anchors to other frames remain unsupported. Regression coverage exercises adding the
missing rectangle through Save, retaining locked=true, applying it and restoring its
backup, plus rejection of different scales and out-of-bounds screen-relative rectangles.
Owner then confirmed `BOTTOMRIGHT, nil, BOTTOMRIGHT` on the source character; the
regression uses that exact anchor pair. All 177 meter assertions and the full suite pass;
reinstating the UIParent-only restriction makes the regression fail.
