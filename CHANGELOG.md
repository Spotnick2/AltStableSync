# Changelog

## v1.0.0

- **Save your UI as a setup.** Capture an Edit Mode layout selection, shown action bars,
  supported game settings, chat tabs and damage-meter windows. Preview before applying it
  to another character; Save updates the setup applied here, Save As creates another, and
  Delete asks before removing a saved setup.
- **Keep two damage meters.** A setup can open a Healing Done window alongside Damage Done,
  select Current Segment for both, and carry their meter types and lock states. It also
  carries the second window's position and size when the client exposes them safely.
- **Set up a new character deliberately.** The first-login welcome offers a saved UI setup.
  The character changes only after you review and confirm it.
- **Restore a UI change.** Applying a UI setup takes a backup first. The Backups view lets
  you preview and restore the previous state.
- **Previews say more** (audit #95). A load or restore that saves your keybindings says so, and
  that every key change in memory is saved with them. A spell replaced by another rank of itself
  shows the ranks. A restore names the macros it keeps. A slot the loadout has empty that holds
  something the backup can't put back (a mount, a flyout) is listed as left unchanged. Applying a
  setup that opens a second damage meter says when a restore can't close it again.
- **Safer sync and saves** (audit #98). A saved setup that arrives from your other account is
  checked whole before it's kept: a damaged one, or one claiming to move a loadout to another
  class or category, is ignored and reported. A damaged record of what this character loaded
  asks you to load it again instead of failing. Saving a UI setup while the second damage meter
  window is closed keeps the window as saved, and says so. The Save preview counts every key it
  adds and shows the first changed line of each macro it saves.
- **Safer restores** (audit #95). A restore that can't store its own backup writes nothing. A
  keybinding save the client refuses is rolled back and reported. Chat changes stop before the next
  write when combat starts between two of them.

## v0.3.0

- **Share a loadout as text.** **Manage… > Share…** shows a loadout as a string to copy, and
  **Import…** (or `/altsync import`) pastes one on another character, on the beta or live, or a
  friend's. Review shows what it holds, with the full text of every macro, before it's saved as a
  new loadout. Nothing on the character changes until you load it.
- **Names show as typed.** A loadout name, a character name or a macro that arrives from an
  imported string or your other account can no longer draw colours, links or icons in the window,
  previews, chat or the minimap tooltip.

## v0.2.0

- **A minimap button.** Left-click opens or closes the window, right-click opens your backups, and
  dragging moves it around the minimap. Its tooltip names your save target. `/altsync minimap`
  hides or shows it.
- **In the minimap's addon list** too, even with the button hidden.
- **A key binding:** Key Bindings > AltStableSync opens or closes the window. No key is set by
  default.
- **Back up now.** Save your setup into a backup whenever you like, from the Backups view or with
  `/altsync backup`: every bar, the keys on your main action bar and pet bar (on character
  keybindings) and your pet's bar. It never touches your bars, and lists any slot it leaves out. With
  10 backups already, it shows which one it would drop first.

## v0.1.1

- **A smaller download.** The package no longer includes the sharing library's tests, tools and
  notes. Nothing changes in game.

## v0.1.0

The first release, for World of Warcraft: Forever (Interface 16001).

- **Loadouts.** Save a character's action bars, keybindings, character macros and pet bars, and
  load them on any character of the same class. Every bar is included, with the stance and form
  pages. Spells on their top rank load as the highest rank the character knows. A pet bar is kept
  per pet family.
- **A preview before every change.** Load, Save, Restore, Rename and Delete each show exactly what
  will happen first, and nothing changes until you confirm. Nothing touches a character on its own:
  not at login, not on a zone change, not when a sync arrives.
- **Backups.** A backup is taken before every load and restore. Each character keeps its last 10
  and its very first. Restore puts the bars and keys back as they were, and the character macros a
  load changed; macros a load created stay, and anything that can't be put back is listed first.
- **Safe on lower-level alts.** Spells an alt can't use yet leave their slots free on a load, and
  are kept in the loadout when that alt saves.
- **Character macros** are created or updated to match the loadout. Account macros are never
  changed.
- **Keybindings** go to the character's own keybindings. A character on account keybindings is
  offered its own copy first, as a separate step.
- **Your other WoW account.** The included AltStableSync Link addon shares saved loadouts with your
  other account on the same Battle.net account, while both are online. A newer version saved on
  one account updates the other's copy (never its characters); changes made on both sides are kept
  as two versions, for you to pick from.
- **The window.** `/altsync` opens it: pick a category and a loadout, see what it holds, Load. A
  separate section saves this character to its save target, or Save As a new loadout. Backups are
  one click away.
