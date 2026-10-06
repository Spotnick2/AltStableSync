# Forever API notes — AltStableSync

Facts **measured on the client** that this addon depends on. Declared shapes come from the dump
(`C:\Projects\References\forever-api-<version>.<build>.md`); addon-agnostic findings belong in the
canonical `C:\Projects\References\PORTING-TBC-TO-FOREVER.md`, not here.

`MEASURED_ON_BUILD` in `Core.lua` names the build this file describes: **70235**.

## Declared on 70235 (from the dump, not yet measured)

- Action bars: globals `GetActionInfo`, `PickupAction`, `PlaceAction`, `GetCursorInfo`,
  `ClearCursor`, `HasAction`; `C_ActionBar.*` (no `C_ActionBar.GetActionInfo`).
- Spells: `C_Spell.PickupSpell`, `GetSpellName`, `GetBaseSpell`, `GetOverrideSpell`;
  `C_SpellBook.FindSpellBookSlotForSpell`, `IsSpellKnown`, `IsSpellBookItemLowRank`; global
  `FindBaseSpellByID`. **No** `PickupSpell` / `GetSpellInfo` globals.
- Items: `C_Item.PickupItem`. **No** `PickupItem` global.
- Macros: `GetMacroInfo`, `GetMacroBody`, `CreateMacro`, `EditMacro`, `DeleteMacro`, `GetNumMacros`,
  `PickupMacro`. `MAX_ACCOUNT_MACROS` / `MAX_CHARACTER_MACROS` are nil; character macros start at
  121 (porting guide).
- Bindings: `GetBinding`, `SetBinding`, `SaveBindings`, `LoadBindings`, `GetCurrentBindingSet`,
  `Enum.BindingSet {Default, Account, Character, Current}`, `C_KeyBindings.GetBindingContextForAction`.
- `C_EditMode.GetLayouts` / `SaveLayouts` / `ConvertLayoutInfoToString` / `ConvertStringToLayoutInfo`
  / `OnLayoutAdded`.
- `C_EncodingUtil.SerializeCBOR` / `CompressString` / `EncodeBase64` (and inverses).
- `C_SpecializationInfo.*`, `C_ClassTalents.*` exist — whether they return Vanilla data is unknown.

## To measure (#2)

Spec/talent APIs, `GetActionInfo` shapes, rank → family mapping, macro persistence across a full
restart, binding-set behaviour and persistence, login readiness event order, Edit Mode round-trip,
CVar persistence, `WOW_PROJECT_ID` / region for the flavour fingerprint. Results land below as
`## Measured on <build>` sections.
