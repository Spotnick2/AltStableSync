------------------------------------------------------------
-- test_uisetup.lua - UI setups (#10): capture, apply, restore, save. Chat
-- on apply is additive, a created tab gets exactly the saved groups, restore
-- is exact per window and keeps created tabs; layouts by type and name;
-- CVars only from the allowlist, in their domain, never protected ones.
------------------------------------------------------------

dofile("tests/harness.lua")
dofile("tests/wow_stubs.lua")
dofile("tests/wow_game.lua")
dofile("tests/wow_ui.lua")

local G, UI = WoW.game, WoW.ui
local A, S, B

local TEMPLATE = {
    active = 4,                                              -- "My UI": the first saved layout
    bars = { true, true, true, true, false, false, false },  -- bars 2-5 shown
    cvars = { damageMeterEnabled = "1", damageMeterResetOnNewInstance = "1", raidFramesDisplayClassColor = "1",
              raidFramesDisplayPowerBars = "1", raidFramesHealthBarColorBG = "ff141414", enableMouseoverCast = "1" },
}

local function boot(ui)
    WoW.reset()
    for _, f in ipairs({ "Core.lua", "Categories.lua", "Catalog.lua", "Game.lua", "Pet.lua", "Backups.lua",
                         "Ready.lua", "Loadout.lua", "UISetup.lua", "Commands.lua" }) do
        assert(loadfile(f))("AltStableSync", {})
    end
    WoW.fire("ADDON_LOADED", "AltStableSync")
    A, S, B = AltStableSync, AltStableSync.UISetup, AltStableSync.Backups
    A.Preview = { Show = function(o) A._shown = o end, Hide = function() A._shown = nil end,
                  Shown = function() return A._shown end }
    G.setup{ class = "MAGE", guid = "Player-70-NEW", spells = { { id = 133, name = "Fireball" } } }
    UI.setup(ui)
    WoW.fire("PLAYER_ENTERING_WORLD", true, false)
    WoW.clock = WoW.clock + 10
end

local function said(s) return table.concat(WoW.chat(), "\n"):find(s, 1, true) ~= nil end
local function lines() return table.concat(A._shown and A._shown.lines or {}, "\n") end
local function has(t, v) for _, x in ipairs(t) do if x == v then return true end end return false end

-- The owner's template character: Whispers tab, XP in General.
local function templateUI()
    local t = {}
    for k, v in pairs(TEMPLATE) do t[k] = v end
    t.windows = {
        [1] = { name = "General", shown = true, docked = true, groups = { "SAY", "EMOTE", "YELL", "GUILD", "PARTY",
                "WHISPER", "BN_WHISPER", "SYSTEM", "CHANNEL", "COMBAT_XP_GAIN" } },
        [4] = { name = "Whispers", shown = false, docked = true, groups = { "WHISPER", "BN_WHISPER" } },
    }
    return t
end

-- Save As on the template character, then a new character with that entry.
local function templateEntry()
    boot(templateUI())
    A.Commands.ui("saveas Base")
    A._shown.onConfirm()
    local e = A.Catalog.ListAll("ui")[1]
    return A.Catalog.Copy(e)
end

local function newCharacterWith(entry, ui)
    boot(ui)
    AltStableSyncDB.presets[entry.id] = A.Catalog.Copy(entry)
    return AltStableSyncDB.presets[entry.id]
end

-- Save As captures the four parts, nothing written to the game.
local base
do
    base = templateEntry()
    eq("saveas: no game writes", #UI.calls, 0)
    eq("saveas: layout by name", base.modules.layout.name, "My UI")
    eq("saveas: layout type Account", base.modules.layout.type, 1)
    check("saveas: bars 2-5 shown, 6-8 hidden", base.modules.bars[2] and base.modules.bars[5] and not base.modules.bars[6])
    eq("saveas: colour CVar", base.modules.cvars.raidFramesHealthBarColorBG, "ff141414")
    check("saveas: XP in the primary groups", has(base.modules.chat.primary, "COMBAT_XP_GAIN"))
    local names = {}
    for _, t in ipairs(base.modules.chat.tabs) do names[t.name] = t.groups end
    check("saveas: Whispers tab", names.Whispers and #names.Whispers == 2)
    check("saveas: an empty tab (Voice) left out", names.Voice == nil)
    check("saveas: and said so", lines():find('Chat: tab "Voice" receives no message types; not saved.', 1, true) ~= nil)
    check("saveas: Combat Log never captured", names["Combat Log"] == nil)
    eq("saveas: the template is this character's save target", AltStableSyncChar.loaded.ui.id, base.id)
    check("saveas: valid at the catalog", A.Catalog.GoodUIModules(base.modules))
end

-- A new character: preview, apply, read back, backup into the ring.
do
    local e = newCharacterWith(base)
    A.Commands.ui("apply Base")
    local text = lines()
    check("apply: preview names the layout", text:find('Layout: "Modern" (a preset) -> "My UI"', 1, true) ~= nil
        or text:find('-> "My UI"', 1, true) ~= nil)
    check("apply: preview shows a bar", text:find("Action Bar 2: show", 1, true) ~= nil)
    check("apply: preview names the new tab", text:find('New chat tab "Whispers": WHISPER, BN_WHISPER', 1, true) ~= nil)
    check("apply: preview adds XP to the main window", text:find("Main chat window: add COMBAT_XP_GAIN", 1, true) ~= nil)
    eq("apply: preview writes nothing", #UI.calls, 0)
    A._shown.onConfirm()
    eq("apply: layout active", UI.active, 4)
    check("apply: bars", UI.bars[1] and UI.bars[4] and not UI.bars[5])
    eq("apply: damage meter on", UI.cvars.damageMeterEnabled, "1")
    eq("apply: colour", UI.cvars.raidFramesHealthBarColorBG, "ff141414")
    check("apply: XP added to General", has(UI.windows[1].groups, "COMBAT_XP_GAIN"))
    check("apply: General kept its own groups", has(UI.windows[1].groups, "GUILD"))
    eq("apply: Whispers made in slot 4", UI.windows[4].name, "Whispers")
    eq("apply: Whispers has exactly the saved groups", table.concat(UI.windows[4].groups, ","), "WHISPER,BN_WHISPER")
    eq("apply: never a remove on an existing window", UI.count("RemoveMessageGroup:GUILD"), 0)
    check("apply: reported", said("Applied Base"))
    local ring, op = B.List()
    check("apply: no pinned operation left", op == nil)
    eq("apply: backup is a UI one", ring[1].kind, "ui")
    eq("apply: backup holds the old layout", ring[1].layout.name, "Modern")
    eq("apply: backup lists the planned tab", ring[1].chat.creating[1], "Whispers")
    check("apply: complete record", AltStableSyncChar.loaded.ui.complete == true and AltStableSyncChar.loaded.ui.id == e.id)

    -- Applying again: nothing to do.
    UI.calls = {}
    A.Commands.ui("apply Base")
    check("apply again: already matches", lines():find("Already matches the selected settings.", 1, true) ~= nil)
    eq("apply again: confirm is Done", A._shown.confirm, "Done")

    -- Restore the backup: exact, the created tab kept and listed.
    UI.calls = {}
    A.Commands.restore("1")
    check("restore: preview lists the kept tab", lines():find('Chat tab "Whispers" is kept', 1, true) ~= nil)
    check("restore: preview removes XP", lines():find("Main chat window: remove COMBAT_XP_GAIN", 1, true) ~= nil)
    A._shown.onConfirm()
    eq("restore: layout back", UI.active, 1)
    check("restore: bars back", not UI.bars[1])
    eq("restore: CVar back", UI.cvars.damageMeterEnabled, "0")
    check("restore: XP gone", not has(UI.windows[1].groups, "COMBAT_XP_GAIN"))
    eq("restore: Whispers kept", UI.windows[4].name, "Whispers")
    check("restore: reported with the kept tab", said("Kept 1 chat tab"))
    check("restore: the record says restored", AltStableSyncChar.loaded.ui.restored == true)
    A.Commands.ui("save")
    check("save after restore: refused", lines():find("A backup was restored since the apply", 1, true) ~= nil)
    eq("save after restore: no confirm", A._shown.confirm, false)
end

-- A stale preview: something changed between preview and confirm.
do
    newCharacterWith(base)
    A.Commands.ui("apply Base")
    UI.cvars.raidFramesDisplayPowerBars = "1"
    A._shown.onConfirm()
    check("stale: refused", said("Something changed since the preview"), table.concat(WoW.chat(), " | "))
    eq("stale: nothing written", #UI.calls, 0)
    eq("stale: no backup", #(B.List()), 0)
end

-- Combat mid-apply: the pin stays, the record has no comparison, restore op works.
do
    newCharacterWith(base)
    UI.after["SetActionBarToggles"] = function() G.combat = true end
    A.Commands.ui("apply Base")
    A._shown.onConfirm()
    check("combat: stopped", said("Stopped (combat"))
    local _, op = B.List()
    check("combat: pinned", op ~= nil and op.snapshot.kind == "ui")
    check("combat: interrupted", AltStableSyncChar.interrupted ~= nil)
    eq("combat: no CVar written", UI.cvars.damageMeterEnabled, "0")
    check("combat: incomplete record", AltStableSyncChar.loaded.ui.complete == false)
    G.combat = false
    UI.after = {}
    A.Commands.ui("save")
    check("combat: save refused", lines():find("The last apply didn't finish", 1, true) ~= nil)
    A.Commands.restore("op")
    A._shown.onConfirm()
    eq("combat: restore op puts the layout back", UI.active, 1)
    check("combat: restore op puts the bars back", not UI.bars[1])
    local _, op2 = B.List()
    check("combat: pin released", op2 == nil and AltStableSyncChar.interrupted == nil)
end

-- Another pinned operation: refused unless the preview's abandon was shown.
do
    local e = newCharacterWith(base)
    B.Pin({ reason = "load X", actions = {}, keys = {} }, { kind = "load", id = "x", version = "x:1", name = "X" })
    local plan = S.Plan(e)
    local r, err = S.Apply(e, plan, false)
    eq("pinned: refused", err, "incomplete")
    A.Commands.ui("apply Base")
    check("pinned: preview asks to abandon", lines():find("Abandon the incomplete load of X", 1, true) ~= nil)
    A._shown.onConfirm()
    local ring, op = B.List()
    check("pinned: abandoned into the ring, then applied", op == nil and #ring == 2)
end

-- Layouts: missing, ambiguous, Character layout capture, Edit Mode open.
do
    newCharacterWith(base, { layouts = { { layoutName = "Other", layoutType = 1 } } })
    local plan = S.Plan(A.Catalog.Get(base.id))
    check("layout missing: skipped", plan.layout == nil and plan.skips[1].reason:find("no layout named", 1, true))
    newCharacterWith(base, { layouts = { { layoutName = "My UI", layoutType = 1 }, { layoutName = "My UI", layoutType = 1 } } })
    plan = S.Plan(A.Catalog.Get(base.id))
    check("layout twice: skipped", plan.layout == nil and plan.skips[1].reason:find("two layouts", 1, true))
    newCharacterWith(base, { layouts = { { layoutName = "My UI", layoutType = 2 } } })
    plan = S.Plan(A.Catalog.Get(base.id))
    check("layout of another type: skipped", plan.layout == nil)
    boot({ layouts = { { layoutName = "Mine", layoutType = 2 } }, active = 4 })
    local m, notes = S.Capture()
    check("capture of a Character layout: left out", m.layout == nil and table.concat(notes, " "):find("Character layout", 1, true))
    newCharacterWith(base)
    UI.editMode = true
    plan = S.Plan(A.Catalog.Get(base.id))
    eq("edit mode open: blocked", plan.blocked, "Close Edit Mode first.")
end

-- CVars: protected, outside the allowlist, outside the domain, account-wide.
do
    local e = A.Catalog.Copy(base)
    e.modules.cvars.raidFramesHealthBarColorBG = "red"
    e.modules.cvars.someOtherCVar = "1"
    newCharacterWith(e, { cvarInfo = { raidFramesDisplayPowerBars = { secure = true },
                                       damageMeterEnabled = { account = true } } })
    local cv = UI.cvars
    cv.someOtherCVar = "0"
    A.Commands.ui("apply Base")
    local text = lines()
    check("cvar: protected skipped", text:find("Raid frames: power bars: protected by the client", 1, true) ~= nil)
    check("cvar: not allowlisted skipped", text:find("someOtherCVar: not supported on this build", 1, true) ~= nil)
    check("cvar: bad value skipped", text:find("the saved value isn't valid", 1, true) ~= nil)
    check("cvar: account scope said", text:find("Damage meter: off -> on (affects this WoW account)", 1, true) ~= nil)
    A._shown.onConfirm()
    eq("cvar: protected never written", UI.count("SetCVar:raidFramesDisplayPowerBars"), 0)
    eq("cvar: not allowlisted never written", UI.count("SetCVar:someOtherCVar"), 0)
    eq("cvar: bad value never written", UI.count("SetCVar:raidFramesHealthBarColorBG"), 0)
    eq("cvar: others written", UI.cvars.raidFramesDisplayClassColor, "1")
    check("cvar: skipped keys recorded", AltStableSyncChar.loaded.ui.skipped.cvars.raidFramesDisplayPowerBars ~= nil)
end

-- Chat: click-through dock, unknown group, no free window, two tabs of a name.
do
    newCharacterWith(base, { windows = { [1] = { name = "General", shown = true, docked = true, uninteractable = true,
                                                 groups = { "SAY" } } } })
    local plan = S.Plan(A.Catalog.Get(base.id))
    check("click-through: tab not created", #plan.chat.create == 0)
    local found = false
    for _, s in ipairs(plan.skips) do if s.reason:find("click-through", 1, true) then found = true end end
    check("click-through: said why", found)

    local e = A.Catalog.Copy(base)
    e.modules.chat.tabs = { { name = "Whispers", groups = { "WHISPER", "NEWTYPE" } } }
    newCharacterWith(e)
    plan = S.Plan(A.Catalog.Get(e.id))
    eq("unknown group: tab still made with the known ones", table.concat(plan.chat.create[1].groups, ","), "WHISPER")

    local full = {}
    for i = 4, 10 do full[i] = { name = "T" .. i, shown = false, docked = true, groups = {} } end
    newCharacterWith(base, { windows = full })
    plan = S.Plan(A.Catalog.Get(base.id))
    check("no free window: skipped", #plan.chat.create == 0)

    newCharacterWith(base, { windows = { [4] = { name = "Whispers", docked = true, groups = {} },
                                         [5] = { name = "Whispers", docked = true, groups = {} } } })
    plan = S.Plan(A.Catalog.Get(base.id))
    check("two tabs of a name: neither touched", #plan.chat.create == 0 and #plan.chat.add == 1)

    -- An existing Whispers tab with other groups only gains the saved ones.
    newCharacterWith(base, { windows = { [4] = { name = "Whispers", docked = true, groups = { "GUILD" } } } })
    A.Commands.ui("apply Base")
    A._shown.onConfirm()
    eq("existing tab: groups added, none removed", table.concat(UI.windows[4].groups, ","), "GUILD,WHISPER,BN_WHISPER")
    eq("existing tab: not created again", UI.count("FCF_OpenNewWindow"), 0)
end

-- Restore preflight: a window now holding a group the client doesn't know
-- is left completely alone (Codex round 3).
do
    newCharacterWith(base)
    A.Commands.ui("apply Base")
    A._shown.onConfirm()
    UI.windows[1].groups[#UI.windows[1].groups + 1] = "STALE_TYPE"
    UI.calls = {}
    A.Commands.restore("1")
    check("preflight: said", lines():find("it holds STALE_TYPE", 1, true) ~= nil)
    A._shown.onConfirm()
    local mutated = 0
    for _, c in ipairs(UI.calls) do if c:find("MessageGroup") then mutated = mutated + 1 end end
    eq("preflight: zero group mutations", mutated, 0)
    check("preflight: XP still there", has(UI.windows[1].groups, "COMBAT_XP_GAIN"))
    check("preflight: restore partial", said("Not everything was restored"))
end

-- Measured on the beta (2026-10-22): General holds types outside
-- ChatTypeGroup (SYSTEM_NOMENU, BN_WHISPER_INFORM, ...). One that stays as
-- it is never blocks the restore; only one to add or remove does.
do
    newCharacterWith(base, { windows = { [1] = { name = "General", shown = true, docked = true,
        groups = { "SAY", "SYSTEM", "SYSTEM_NOMENU", "BN_WHISPER_INFORM" } } } })
    A.Commands.ui("apply Base")
    A._shown.onConfirm()
    check("unknown kept: XP added", has(UI.windows[1].groups, "COMBAT_XP_GAIN"))
    UI.calls = {}
    WoW.chatLines = {}
    A.Commands.restore("1")
    A._shown.onConfirm()
    check("unknown kept: XP removed", not has(UI.windows[1].groups, "COMBAT_XP_GAIN"))
    check("unknown kept: the unknown types untouched", has(UI.windows[1].groups, "SYSTEM_NOMENU")
        and has(UI.windows[1].groups, "BN_WHISPER_INFORM"))
    eq("unknown kept: one group written", UI.count("RemoveMessageGroup:COMBAT_XP_GAIN"), 1)
    check("unknown kept: restore complete", said("Restored:") and not said("Not everything was restored"))
end

-- Beta, 2026-10-22: a setup saved before Save As left empty tabs out still
-- held one (GABProbe). Apply never creates an empty tab, Save drops it, and
-- the contents mark a setting this build doesn't write.
do
    local e = A.Catalog.Copy(base)
    e.modules.chat.tabs[#e.modules.chat.tabs + 1] = { name = "GABProbe", groups = {} }
    e.modules.cvars.enableMouseoverCast = "0"
    newCharacterWith(e)
    A.Commands.ui("apply Base")
    check("empty tab: skipped", lines():find('Tab "GABProbe": receives no message types; not created', 1, true) ~= nil)
    A._shown.onConfirm()
    eq("empty tab: one tab created (Whispers)", UI.count("FCF_OpenNewWindow"), 1)
    check("contents: unsupported marked", table.concat(S.Contents(e.modules), "\n")
        :find("enableMouseoverCast: 0 (not supported on this build)", 1, true) ~= nil)

    -- The template still has its empty tab: Save drops it from the entry.
    boot(templateUI())
    UI.windows[5] = { name = "GABProbe", shown = false, docked = true, groups = {} }
    AltStableSyncDB.presets[e.id] = A.Catalog.Copy(e)
    AltStableSyncChar.loaded = { ui = { id = e.id, version = e.version, baseline = A.Catalog.Copy(e.modules),
                                        complete = true, skipped = {} } }
    A.Commands.ui("save")
    check("save: says the empty tab goes", lines():find('Tab "GABProbe": removed (it receives no message types)', 1, true) ~= nil)
    A._shown.onConfirm()
    local saved = A.Catalog.Get(e.id).modules.chat.tabs
    local names = {}
    for _, t in ipairs(saved) do names[t.name] = true end
    check("save: empty tab dropped", not names.GABProbe and names.Whispers)

    -- Beta: the empty tab was already closed on the saving character; the
    -- entry still drops it, and Save has something to do.
    boot(templateUI())
    AltStableSyncDB.presets[e.id] = A.Catalog.Copy(e)
    AltStableSyncChar.loaded = { ui = { id = e.id, version = e.version, baseline = A.Catalog.Copy(e.modules),
                                        complete = true, skipped = {} } }
    A.Commands.ui("save")
    check("save, tab closed here: says it goes", lines():find('Tab "GABProbe": removed', 1, true) ~= nil)
    eq("save, tab closed here: Save offered", A._shown.confirm, "Save")
    A._shown.onConfirm()
    names = {}
    for _, t in ipairs(A.Catalog.Get(e.id).modules.chat.tabs) do names[t.name] = true end
    check("save, tab closed here: dropped", not names.GABProbe)
end

-- Mouseover casting is protected on Forever (measured 2026-10-22): an
-- entry holding it keeps it, and it is never written.
do
    local e = A.Catalog.Copy(base)
    e.modules.cvars.enableMouseoverCast = "1"
    newCharacterWith(e)
    UI.cvars.enableMouseoverCast = "0"
    A.Commands.ui("apply Base")
    check("mouseover: not supported", lines():find("enableMouseoverCast: not supported on this build", 1, true) ~= nil)
    A._shown.onConfirm()
    eq("mouseover: never written", UI.count("SetCVar:enableMouseoverCast"), 0)
end

-- PR #91 review P2: a chat read that fails at write time stops before any
-- chat write; nil is never taken as "absent".
do
    newCharacterWith(base)
    UI.after["SetCVar:raidFramesHealthBarColorBG"] = function() UI.readFail = true end
    A.Commands.ui("apply Base")
    A._shown.onConfirm()
    UI.readFail = false
    check("read fails: stopped", said("Stopped (chat window unreadable"))
    eq("read fails: no group added", UI.count("AddMessageGroup:COMBAT_XP_GAIN"), 0)
    eq("read fails: no tab created", UI.count("FCF_OpenNewWindow"), 0)
    local _, op = B.List()
    check("read fails: pin kept", op ~= nil)
end

-- PR #91 review P1: a window that changed after the preview stops the
-- write, and a restore is complete only when the whole window matches.
do
    newCharacterWith(base)
    UI.after["SetCVar:raidFramesHealthBarColorBG"] = function() table.insert(UI.windows[1].groups, "LOOT") end
    A.Commands.ui("apply Base")
    A._shown.onConfirm()
    check("drift on apply: stopped", said("chat window changed since the preview"))
    eq("drift on apply: nothing added", UI.count("AddMessageGroup:COMBAT_XP_GAIN"), 0)

    -- An apply stopped after XP was added; restoring it while something
    -- slips another group in must not count as complete.
    newCharacterWith(base)
    UI.after["AddMessageGroup:COMBAT_XP_GAIN"] = function() G.combat = true end
    A.Commands.ui("apply Base")
    A._shown.onConfirm()
    G.combat = false
    UI.after = { ["RemoveMessageGroup:COMBAT_XP_GAIN"] = function() table.insert(UI.windows[1].groups, "LOOT") end }
    WoW.chatLines = {}
    A.Commands.restore("op")
    A._shown.onConfirm()
    check("drift on restore: not complete", said("Stopped (chat window doesn't match after the write"))
    local _, op = B.List()
    check("drift on restore: pin kept", op ~= nil and AltStableSyncChar.interrupted ~= nil)
end

-- A backup whose groups the client no longer knows: that window is left
-- alone, nothing removed from it.
do
    newCharacterWith(base)
    A.Commands.ui("apply Base")
    A._shown.onConfirm()
    local ring = B.List()
    ring[1].chat.primary.groups[#ring[1].chat.primary.groups + 1] = "GONE_TYPE"
    UI.calls = {}
    A.Commands.restore("1")
    check("desired preflight: said", lines():find("GONE_TYPE is not a chat type on this client", 1, true) ~= nil)
    A._shown.onConfirm()
    local mutated = 0
    for _, c in ipairs(UI.calls) do if c:find("MessageGroup") then mutated = mutated + 1 end end
    eq("desired preflight: zero group mutations", mutated, 0)
end

-- A client that gives a new window its default groups anyway: the created
-- tab still ends with exactly the saved ones.
do
    newCharacterWith(base, { ignoreNoDefault = true })
    A.Commands.ui("apply Base")
    A._shown.onConfirm()
    eq("defaults ignored: created tab exact", table.concat(UI.windows[4].groups, ","), "WHISPER,BN_WHISPER")
    eq("defaults ignored: one removal, on the new tab", UI.count("RemoveMessageGroup:GUILD"), 1)
    check("defaults ignored: General keeps its groups", has(UI.windows[1].groups, "GUILD"))
end

-- Save: keeps what the apply skipped; saves real changes; previews them.
do
    newCharacterWith(base, { layouts = { { layoutName = "Elsewhere", layoutType = 1 } } })
    A.Commands.ui("apply Base")
    A._shown.onConfirm()
    UI.cvars.raidFramesDisplayPowerBars = "0"
    A.Commands.ui("save")
    local text = lines()
    check("save: lists the change", text:find("Raid frames: power bars: 1 -> 0", 1, true) ~= nil)
    A._shown.onConfirm()
    local e = A.Catalog.Get(base.id)
    eq("save: skipped layout kept", e.modules.layout.name, "My UI")
    eq("save: change saved", e.modules.cvars.raidFramesDisplayPowerBars, "0")
    eq("save: record advanced", AltStableSyncChar.loaded.ui.version, e.version)
end

-- Save without having applied anything: refused, Save As offered.
do
    newCharacterWith(base)
    A.Commands.ui("save")
    check("save without apply: refused", lines():find("Apply a UI setup first", 1, true) ~= nil)
end

-- The catalog boundary: malformed known parts rejected, unknown keys kept.
do
    boot()
    local C = A.Catalog
    local function bad(label, m) check("validate: " .. label, select(2, C.Create("ui", { name = label }, m)) == "bad-modules") end
    bad("bars missing a key", { bars = { [2] = true } })
    bad("bars not boolean", { bars = { [2] = 1, [3] = true, [4] = true, [5] = true, [6] = true, [7] = true, [8] = true } })
    bad("bars extra key", { bars = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true, [7] = true, [8] = true } })
    bad("layout bad type", { layout = { type = 2, name = "Mine" } })
    bad("layout preset bad index", { layout = { type = 0, index = 4 } })
    bad("cvar value not a string", { cvars = { damageMeterEnabled = 1 } })
    bad("chat group lowercase", { chat = { primary = { "say" } } })
    bad("chat duplicate group", { chat = { primary = { "SAY", "SAY" } } })
    bad("chat hole", { chat = { primary = { [1] = "SAY", [3] = "YELL" } } })
    bad("chat two tabs of a name", { chat = { tabs = { { name = "A", groups = {} }, { name = "A", groups = {} } } } })
    local ok = C.Create("ui", { name = "Future" }, { layout = { type = 1, name = "X" }, someNewPart = { x = 1 } })
    check("validate: unknown part kept", ok and ok.modules.someNewPart.x == 1)
    eq("validate: received malformed refused", select(2, C.Upsert({ id = "ui-peer-1", version = "peer:1", kind = "ui",
        name = "Bad", modules = { bars = { [2] = "yes" } } }, "Other")), "bad-entry")
    check("contents: unknown part shown", table.concat(S.Contents(ok.modules), "\n"):find("someNewPart: not supported", 1, true) ~= nil)
end

-- A UI backup is never read as a loadout one, and an unknown kind by neither.
do
    newCharacterWith(base)
    A.Commands.ui("apply Base")
    A._shown.onConfirm()
    local plan = A.Loadout.PlanRestore("1")
    eq("loadout restore refuses a UI backup", plan.blocked, "Not a loadout backup.")
    local ring = B.List()
    ring[1].kind = "future"
    A.Commands.restore("1")
    eq("unknown kind: refused", A._shown.confirm, false)
    check("unknown kind: said", lines():find("Not a loadout backup.", 1, true) ~= nil)
    eq("unknown kind: UI restore refuses too", S.PlanRestore("1").blocked, "Not a UI setup backup.")
end

------------------------------------------------------------
-- The damage meter, the fifth part. The stub copies Blizzard's Mainline
-- mixin (70448); nothing here is measured on Forever (the PR's in-game check).
------------------------------------------------------------

local DM, DS = Enum.DamageMeterType, Enum.DamageMeterSessionType
local RECT = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 812.37, y = -400.04, width = 260, height = 180 }

local function meterTemplateUI()
    local t = templateUI()
    t.meter = { windows = { [1] = { type = DM.DamageDone, sessionType = DS.Current },
                            [2] = { type = DM.HealingDone, sessionType = DS.Current, locked = true, rect = RECT } } }
    return t
end

local function meterEntry()
    boot(meterTemplateUI())
    A.Commands.ui("saveas Meter")
    A._shown.onConfirm()
    for _, e in ipairs(A.Catalog.ListAll("ui")) do if e.name == "Meter" then return A.Catalog.Copy(e) end end
end

local function meterCalls()
    local n = 0
    for _, c in ipairs(UI.calls) do
        if c:find("SessionWindow", 1, true) then n = n + 1 end
    end
    return n
end

local function win(i) return DamageMeter:GetSessionWindow(i) end

-- Nothing but plain values (no frame, no function) in a stored table.
local function plain(t, seen)
    seen = seen or {}
    if type(t) == "function" or type(t) == "userdata" then return false end
    if type(t) ~= "table" then return true end
    if seen[t] then return true end
    seen[t] = true
    if t == UIParent or t.GetSessionWindowIndex then return false end
    for k, v in pairs(t) do if not plain(k, seen) or not plain(v, seen) then return false end end
    return true
end

local meter
do
    meter = meterEntry()
    eq("meter saveas: no game writes", #UI.calls, 0)
    local w = meter.modules.meter.windows
    eq("meter saveas: two windows", #w, 2)
    eq("meter saveas: primary Damage Done", w[1].type, DM.DamageDone)
    eq("meter saveas: primary Current Segment", w[1].session, DS.Current)
    check("meter saveas: primary has no lock or rect", w[1].locked == nil and w[1].rect == nil)
    eq("meter saveas: window 2 Healing Done", w[2].type, DM.HealingDone)
    eq("meter saveas: window 2 Current Segment", w[2].session, DS.Current)
    eq("meter saveas: window 2 locked", w[2].locked, true)
    eq("meter saveas: rect recorded, rounded", w[2].rect.x, 812.4)
    eq("meter saveas: rect size", w[2].rect.width, 260)
    check("meter saveas: valid at the catalog", A.Catalog.GoodUIModules(meter.modules))
    local text = table.concat(S.Contents(meter.modules), "\n")
    check("meter contents: window 2", text:find("Damage meter window 2: Healing Done, Current Segment, locked", 1, true) ~= nil)
    check("meter contents: position recorded, not applied", text:find("not applied: place it yourself", 1, true) ~= nil)
end

-- A new character: window 1 on Overall, no second window. Apply opens one.
do
    local e = newCharacterWith(meter)
    A.Commands.ui("apply Meter")
    local text = lines()
    check("meter apply: preview sets window 1", text:find("Damage meter window 1: Overall -> Current Segment", 1, true) ~= nil, text)
    check("meter apply: preview opens window 2",
        text:find("New damage meter window 2: Healing Done, Current Segment, locked", 1, true) ~= nil, text)
    check("meter apply: preview says the position isn't applied", text:find("move it yourself", 1, true) ~= nil)
    eq("meter apply: preview writes nothing", #UI.calls, 0)
    check("meter apply: the plan holds plain values only", plain(S.Plan(e)))
    A._shown.onConfirm()
    eq("meter apply: window 1 Current", win(1):GetSessionType(), DS.Current)
    check("meter apply: window 2 shown", win(2) ~= nil and win(2):IsShown())
    eq("meter apply: window 2 Healing Done", win(2):GetDamageMeterType(), DM.HealingDone)
    eq("meter apply: window 2 Current", win(2):GetSessionType(), DS.Current)
    eq("meter apply: window 2 locked", win(2):IsLocked(), true)
    eq("meter apply: one Show new window", UI.count("ShowNewSecondarySessionWindow"), 1)
    eq("meter apply: never a hide", UI.count("HideSessionWindow:1") + UI.count("HideSessionWindow:2"), 0)
    check("meter apply: reported", said("New damage meter window: 2"))
    eq("meter apply: Blizzard saved its own window data", UI.dmSaved.windowDataList[2].damageMeterType, DM.HealingDone)
    local ring = B.List()
    eq("meter apply: backup lists the opened window", ring[1].meter.opened[1].index, 2)
    eq("meter apply: and what the apply left in it", ring[1].meter.opened[1].type, DM.HealingDone)
    check("meter apply: backup holds window 1 as it was", ring[1].meter.windows[1].session == DS.Overall)
    check("meter apply: backup holds window 2's earlier state", ring[1].meter.windows[2].data == false)
    check("meter apply: backup holds plain values only", plain(ring[1].meter))
    check("meter apply: complete", AltStableSyncChar.loaded.ui.complete == true)

    UI.calls = {}
    A.Commands.ui("apply Meter")
    check("meter apply again: already matches", lines():find("Already matches the selected settings.", 1, true) ~= nil, lines())

    -- Restore: window 1 back to Overall, window 2 put back to Blizzard's
    -- fresh values, then hidden.
    UI.calls = {}
    A.Commands.restore("1")
    text = lines()
    check("meter restore: preview hides window 2", text:find("Damage meter window 2: hide (opened by that apply)", 1, true) ~= nil, text)
    check("meter restore: preview sets window 1 back", text:find("Damage meter window 1: Current Segment -> Overall", 1, true) ~= nil, text)
    A._shown.onConfirm()
    eq("meter restore: window 1 Overall", win(1):GetSessionType(), DS.Overall)
    check("meter restore: window 2 hidden", not win(2):IsShown())
    local d = DamageMeter.windowDataList[2]
    check("meter restore: window 2 left as a fresh one", d.damageMeterType == DM.DamageDone
        and d.sessionType == DS.Overall and not d.locked)
    check("meter restore: complete", said("Restored:") and not said("Not everything was restored"))
end

-- A window hidden before is reopened with its old settings; Restore puts
-- those back before hiding it.
do
    newCharacterWith(meter, { meter = { windows = { [2] = { type = DM.Interrupts, sessionType = DS.Overall, shown = false } } } })
    check("reopen: no frame yet", win(2) == nil)
    A.Commands.ui("apply Meter")
    check("reopen: preview says it reopens", lines():find("reopens a window you hid before", 1, true) ~= nil, lines())
    A._shown.onConfirm()
    eq("reopen: window 2 Healing Done", win(2):GetDamageMeterType(), DM.HealingDone)
    eq("reopen: window 2 locked", win(2):IsLocked(), true)
    A.Commands.restore("1")
    A._shown.onConfirm()
    check("reopen restore: hidden", not win(2):IsShown())
    local d = DamageMeter.windowDataList[2]
    check("reopen restore: Blizzard remembers Interrupts again", d.damageMeterType == DM.Interrupts
        and d.sessionType == DS.Overall and not d.locked)
end

-- Blizzard opens the lowest free index, which can be below a shown window:
-- the setup's windows map to the final order, and a second apply is a no-op.
do
    local e = A.Catalog.Copy(meter)
    e.modules.meter.windows[3] = { type = DM.Dps, session = DS.Current, locked = false, rect = RECT }
    newCharacterWith(e, { meter = { windows = { [3] = { type = DM.Deaths, sessionType = DS.Overall } } } })
    A.Commands.ui("apply Meter")
    local text = lines()
    check("order: opens window 2", text:find("New damage meter window 2: Healing Done", 1, true) ~= nil, text)
    check("order: window 3 becomes DPS", text:find("Damage meter window 3: Deaths -> DPS", 1, true) ~= nil, text)
    A._shown.onConfirm()
    eq("order: window 2 Healing Done", win(2):GetDamageMeterType(), DM.HealingDone)
    eq("order: window 3 DPS", win(3):GetDamageMeterType(), DM.Dps)
    A.Commands.ui("apply Meter")
    check("order: apply again is a no-op", lines():find("Already matches the selected settings.", 1, true) ~= nil, lines())
    A.Commands.ui("save")
    eq("order: Save has nothing to save", A._shown.confirm, false)
    -- An entry window with no recorded position gets this one's.
    AltStableSyncDB.presets[e.id].modules.meter.windows[3].rect = nil
    A.Commands.ui("save")
    check("order: a missing position is filled in", lines():find("Damage meter window 3: position and size recorded", 1, true) ~= nil, lines())
end

-- Two opens on a character showing only window 1: predicted in Blizzard's
-- order (the remembered window first), each landing where predicted.
do
    local e = A.Catalog.Copy(meter)
    e.modules.meter.windows[3] = { type = DM.Dps, session = DS.Current, locked = false }
    newCharacterWith(e, { meter = { windows = { [3] = { type = DM.Deaths, sessionType = DS.Overall, shown = false } } } })
    local m = S._test.ReadMeter()
    local p = S._test.PredictOpens(m, 2)
    check("predict: the remembered window 3 first, then a new 2", #p == 2 and p[1].index == 3 and p[1].reopen
        and p[2].index == 2 and not p[2].reopen)
    A.Commands.ui("apply Meter")
    A._shown.onConfirm()
    eq("two opens: window 2 Healing Done", win(2):GetDamageMeterType(), DM.HealingDone)
    eq("two opens: window 3 DPS", win(3):GetDamageMeterType(), DM.Dps)
    local ring = B.List()
    eq("two opens: both recorded", #ring[1].meter.opened, 2)
end

-- Three shown, a setup of two: window 3 is never touched, by Apply or Restore.
do
    newCharacterWith(meter, { meter = { windows = { [2] = { type = DM.Dps }, [3] = { type = DM.Deaths } } } })
    A.Commands.ui("apply Meter")
    A._shown.onConfirm()
    eq("third window: no write to it", UI.count("SetSessionWindowDamageMeterType:3") + UI.count("SetSessionWindowSessionID:3")
        + UI.count("SetSessionWindowLocked:3"), 0)
    eq("third window: window 2 adjusted, not reopened", UI.count("ShowNewSecondarySessionWindow"), 0)
    eq("third window: window 2 Healing Done", win(2):GetDamageMeterType(), DM.HealingDone)
    check("third window: not in the backup", B.List()[1].meter.windows[3] == nil)
    DamageMeter:SetSessionWindowDamageMeterType(win(3), DM.Absorbs)   -- the player, later
    UI.calls = {}
    A.Commands.restore("1")
    A._shown.onConfirm()
    eq("third window: restore leaves the player's change", win(3):GetDamageMeterType(), DM.Absorbs)
    eq("third window: window 2 back to DPS", win(2):GetDamageMeterType(), DM.Dps)
    check("third window: window 2 kept shown (not opened by that apply)", win(2):IsShown())
end

-- No free window: the setup's extra window is a visible skip.
do
    local e = A.Catalog.Copy(meter)
    e.modules.meter.windows[3] = { type = DM.Dps, session = DS.Current, locked = false }
    newCharacterWith(e)
    DamageMeter.GetMaxSessionWindowCount = function() return 2 end
    A.Commands.ui("apply Meter")
    check("no free window: skipped", lines():find("the setup's window 3: no free damage meter window", 1, true) ~= nil, lines())
    A._shown.onConfirm()
    eq("no free window: one opened", UI.count("ShowNewSecondarySessionWindow"), 1)
    check("no free window: recorded as skipped", AltStableSyncChar.loaded.ui.skipped.meter[3].window ~= nil)
end

-- The API isn't there (or not this shape): a visible skip, nothing called.
do
    newCharacterWith(meter, { noMeter = true })
    A.Commands.ui("apply Meter")
    check("no API: skipped, said", lines():find("Damage meter: not supported on this build", 1, true) ~= nil, lines())
    A._shown.onConfirm()
    eq("no API: nothing called", meterCalls(), 0)
    eq("no API: skipped recorded", AltStableSyncChar.loaded.ui.skipped.meter.all, "not supported on this build")
    A.Commands.ui("save")
    check("no API: Save keeps the part", lines():find("Damage meter: skipped by the apply; kept as saved.", 1, true) ~= nil, lines())
    boot({ noMeter = true })
    local m, notes = S.Capture()
    check("no API: Save As leaves it out, said", m.meter == nil
        and table.concat(notes, " "):find("Damage meter: not supported on this build; not saved.", 1, true))
    -- A client with the frame but not every method is the same skip.
    boot()
    DamageMeter.ShowNewSecondarySessionWindow = nil
    m, notes = S.Capture()
    check("partial API: not supported", m.meter == nil)
end

-- A type this client doesn't know: skipped, kept in the entry; the rest written.
do
    local e = A.Catalog.Copy(meter)
    e.modules.meter.windows[2].type = 42
    newCharacterWith(e)
    A.Commands.ui("apply Meter")
    check("unknown type: skipped", lines():find("meter type 42: not a meter type on this client", 1, true) ~= nil, lines())
    A._shown.onConfirm()
    eq("unknown type: window opened with Blizzard's default", win(2):GetDamageMeterType(), DM.DamageDone)
    eq("unknown type: its segment still written", win(2):GetSessionType(), DS.Current)
    eq("unknown type: never written", UI.count("SetSessionWindowDamageMeterType:2"), 0)
end

-- Combat right after the open: stopped, pinned, the open recorded; restore op
-- hides it.
do
    newCharacterWith(meter)
    UI.after["ShowNewSecondarySessionWindow"] = function() G.combat = true end
    A.Commands.ui("apply Meter")
    A._shown.onConfirm()
    check("meter combat: stopped", said("Stopped (combat"))
    local _, op = B.List()
    check("meter combat: pinned with the open recorded", op ~= nil and op.snapshot.meter.opened[1].index == 2)
    eq("meter combat: no write after it", UI.count("SetSessionWindowDamageMeterType:2"), 0)
    G.combat = false
    UI.after = {}
    A.Commands.restore("op")
    A._shown.onConfirm()
    check("meter combat: restore op hides the window", not win(2):IsShown())
    local _, op2 = B.List()
    check("meter combat: pin released", op2 == nil)
end

-- A stale preview, a change after the preview, a write the client drops, an
-- open that lands elsewhere: each stops before or right at the write.
do
    newCharacterWith(meter)
    A.Commands.ui("apply Meter")
    DamageMeter:SetSessionWindowSessionID(win(1), DS.Current, nil)   -- the player, before confirming
    UI.calls = {}
    A._shown.onConfirm()
    check("meter stale: refused", said("Something changed since the preview"))
    eq("meter stale: nothing written", #UI.calls, 0)

    newCharacterWith(meter)
    UI.after["SetCVar:raidFramesHealthBarColorBG"] = function()
        DamageMeter:SetSessionWindowDamageMeterType(win(1), DM.Deaths)
    end
    A.Commands.ui("apply Meter")
    A._shown.onConfirm()
    check("meter drift: stopped", said("damage meter changed since the preview"))
    eq("meter drift: nothing opened", UI.count("ShowNewSecondarySessionWindow"), 0)

    newCharacterWith(meter)
    UI.dmIgnore = "type"
    A.Commands.ui("apply Meter")
    A._shown.onConfirm()
    check("meter read-back: stopped", said("damage meter window 2 read-back"))
    local _, op = B.List()
    check("meter read-back: pin kept", op ~= nil)

    newCharacterWith(meter, { meter = { windows = { [3] = { type = DM.Deaths, shown = false } } } })
    local real = DamageMeter.ShowNewSecondarySessionWindow
    -- A client whose rule differs from the source: it opens window 2, not 3.
    DamageMeter.ShowNewSecondarySessionWindow = function(self)
        self.windowDataList[3] = nil
        return real(self)
    end
    A.Commands.ui("apply Meter")
    A._shown.onConfirm()
    check("meter wrong index: stopped", said("isn't the one planned"))
    _, op = B.List()
    eq("meter wrong index: the window that did open is recorded", op.snapshot.meter.opened[1].index, 2)
end

-- Restore keeps an opened window the player changed since; never opens one.
do
    newCharacterWith(meter)
    A.Commands.ui("apply Meter")
    A._shown.onConfirm()
    DamageMeter:SetSessionWindowDamageMeterType(win(2), DM.Hps)    -- the player
    UI.calls = {}
    A.Commands.restore("1")
    check("changed since: kept, said", lines():find("changed since; kept", 1, true) ~= nil, lines())
    A._shown.onConfirm()
    check("changed since: still shown", win(2):IsShown())
    eq("changed since: never hidden", UI.count("HideSessionWindow:2"), 0)

    -- A window the backup shows that the player closed is left closed.
    newCharacterWith(meter, { meter = { windows = { [2] = { type = DM.Dps } } } })
    A.Commands.ui("apply Meter")
    A._shown.onConfirm()
    DamageMeter:HideSessionWindow(win(2))
    UI.calls = {}
    A.Commands.restore("1")
    check("closed since: can't be restored", lines():find("closed since the backup; left as is", 1, true) ~= nil, lines())
    A._shown.onConfirm()
    eq("closed since: never reopened", UI.count("ShowNewSecondarySessionWindow"), 0)
end

-- Save: live values into the mapped windows, one line for a moved window,
-- unknown keys kept.
do
    local e = A.Catalog.Copy(meter)
    e.modules.meter.windows[2].future = "x"
    e.modules.meter.future = 1
    newCharacterWith(e)
    A.Commands.ui("apply Meter")
    A._shown.onConfirm()
    DamageMeter:SetSessionWindowDamageMeterType(win(2), DM.Hps)
    win(2).rect = { point = "CENTER", relativeTo = UIParent, relativePoint = "CENTER", x = 10, y = 20, width = 300, height = 150 }
    A.Commands.ui("save")
    local text = lines()
    check("meter save: lists the type", text:find("Damage meter window 2: Healing Done -> HPS", 1, true) ~= nil, text)
    check("meter save: a recorded position isn't replaced", text:find("position and size", 1, true) == nil, text)
    A._shown.onConfirm()
    local w = A.Catalog.Get(e.id).modules.meter.windows[2]
    eq("meter save: type saved", w.type, DM.Hps)
    eq("meter save: recorded rect kept", w.rect.x, 812.4)
    eq("meter save: window's unknown key kept", w.future, "x")
    eq("meter save: part's unknown key kept", A.Catalog.Get(e.id).modules.meter.future, 1)
end

-- Capture: a single fight's segment and an odd position are left out, said.
do
    local t = meterTemplateUI()
    t.meter.windows[2] = { type = DM.HealingDone, sessionType = nil, sessionID = 7, locked = false,
                           rect = { point = "TOPLEFT", relativeTo = {}, relativePoint = "TOPLEFT", x = 1, y = 1, width = 10, height = 10 } }
    boot(t)
    local m, notes = S.Capture()
    local n = table.concat(notes, " ")
    check("capture: single fight not saved", m.meter.windows[2].session == nil and n:find("shows a single fight", 1, true))
    check("capture: rect anchored elsewhere not saved", m.meter.windows[2].rect == nil and n:find("position couldn't be read", 1, true))
    check("capture: still valid", A.Catalog.GoodUIModules(m))
end

-- The catalog boundary for the new part.
do
    boot()
    local C = A.Catalog
    local function bad(label, mt)
        check("meter validate: " .. label, select(2, C.Create("ui", { name = label }, { meter = mt })) == "bad-modules")
    end
    local W1 = { type = 0, session = 1 }
    bad("not a table", "x")
    bad("no windows", {})
    bad("empty windows", { windows = {} })
    bad("four windows", { windows = { W1, { type = 2 }, { type = 2 }, { type = 2 } } })
    bad("a hole", { windows = { [1] = W1, [3] = { type = 2 } } })
    bad("type negative", { windows = { { type = -1 } } })
    bad("type fraction", { windows = { { type = 1.5 } } })
    bad("type a string", { windows = { { type = "2" } } })
    bad("session out of range", { windows = { { type = 0, session = 99 } } })
    bad("primary locked", { windows = { { type = 0, locked = true } } })
    bad("primary rect", { windows = { { type = 0, rect = RECT } } })
    bad("locked not boolean", { windows = { W1, { type = 2, locked = 1 } } })
    bad("rect lowercase point", { windows = { W1, { type = 2, rect = { point = "topleft", relativePoint = "TOPLEFT", x = 0, y = 0, width = 1, height = 1 } } } })
    bad("rect zero width", { windows = { W1, { type = 2, rect = { point = "TOP", relativePoint = "TOP", x = 0, y = 0, width = 0, height = 1 } } } })
    bad("rect NaN", { windows = { W1, { type = 2, rect = { point = "TOP", relativePoint = "TOP", x = 0 / 0, y = 0, width = 1, height = 1 } } } })
    bad("rect infinite", { windows = { W1, { type = 2, rect = { point = "TOP", relativePoint = "TOP", x = math.huge, y = 0, width = 1, height = 1 } } } })
    local ok = C.Create("ui", { name = "Future meter" }, { meter = { windows = { { type = 99, session = 1, glow = true } }, extra = 1 } })
    check("meter validate: a newer type and unknown keys kept", ok and ok.modules.meter.windows[1].glow == true
        and ok.modules.meter.extra == 1)
    eq("meter validate: received malformed refused", select(2, C.Upsert({ id = "ui-peer-9", version = "peer:9", kind = "ui",
        name = "Bad meter", modules = { meter = { windows = { { type = 0, locked = true } } } } }, "Other")), "bad-entry")
end

finish("test_uisetup")
