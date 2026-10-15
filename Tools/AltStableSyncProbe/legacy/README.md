# The old /syncprobe (not loaded)

`Probe.lua` and its TOC are the probe from before ForeverProbe (#2, #25, #29, #47, #58): `/syncprobe`,
with its output in chat. They are kept here as a reference for porting a command into the
ForeverProbe module (`../AltStableSyncProbe.lua`, `/fp sync`) when an issue next needs one. What
they measured is in `docs/forever-api-notes.md`.

`Tools/deploy-probe.ps1` never deploys this folder. Its TOC uses the same folder and SavedVariables
names as the module, so never install both.
