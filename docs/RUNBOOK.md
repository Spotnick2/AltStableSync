# Runbook

Operational notes for working on AltStableSync against a WoW: Forever client. The *why* lives in
`docs/DESIGN.md`; this is the *how*.

## Install and paths

The beta is `C:\Program Files (x86)\World of Warcraft\_classic_beta_` (executable `WowB.exe`). The
**live Forever flavour folder is not known yet** — every script takes an explicit path for it.

Measured on the beta, account `50284074#1`:

```
_classic_beta_\Interface\AddOns\AltStableSync\                         the deployed addon
_classic_beta_\WTF\Account\<id>\SavedVariables\AltStableSync.lua         account-wide (DB + LAS)
_classic_beta_\WTF\Account\<id>\<realmID>\<Name>-<Surname>\SavedVariables\AltStableSync.lua
                                                                         per character (AltStableSyncChar)
_classic_beta_\WTF\Account\<id>\bindings-cache.wtf, macros-cache.txt,
    edit-mode-cache-account.txt                                          server-side caches, per flavour
```

The realm folder is a numeric id (`70`); character folders carry the surname. Blizzard's own
server-side caches are per flavour: they will **not** follow the player from beta to live, which is
the whole point of this addon on day one.

## The in-game loop

1. `pwsh Tools/deploy.ps1` (`-AddOnsPath` for another flavour).
2. In game: `/console scriptErrors 1` once (errors are off by default), BugSack recommended.
3. `/reload`, then `/altsync` — it prints version, schema and counts.

## Verifying persistence

`/reload` proves nothing about persistence — the process and its Lua state survive it. To prove a
write: **Exit Game**, wait for `WowB.exe` to go, relaunch, and check the value in game or in the
file. SavedVariables are written only on a clean logout/exit or `/reload`. **Close the client
before editing or copying any SavedVariables file**, or the client overwrites it on exit.

## When the client updates

See `.claude/skills/client-update/SKILL.md`. The API dump itself is taken from the AltStable repo.

## Nov 4 launch — day-one checklist (draft; finalised by #13)

1. **Before launch, on beta:** profiles saved for every class/role; the destructive rehearsal (#13)
   passed; a manual copy of the beta `WTF\Account` folder kept outside the game directory.
2. **Live installed, both clients closed.**
3. `pwsh Tools/Transfer-Profiles.ps1 -From "<beta>\WTF\Account\<id>" -To "<live>\WTF\Account\<id>"`
   (#12). It refuses if a live file already exists.
4. `pwsh Tools/deploy.ps1 -AddOnsPath "<live>\Interface\AddOns"`.
5. Log in one character. The addon detects the new flavour (#11): beta backups archived, the
   LibAccountSync store wiped, profiles kept.
6. **Launch gate:** on that one character — capture-only, preview, manual apply, **full exit and
   restart**, verify bars/macros/bindings. Only then use `ask`/`auto` on the others.
