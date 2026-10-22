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
    check("saveas: Voice tab captured as a tab", names.Voice ~= nil)
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
    UI.cvars.enableMouseoverCast = "1"
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
    newCharacterWith(e, { cvarInfo = { enableMouseoverCast = { secure = true },
                                       damageMeterEnabled = { account = true } } })
    local cv = UI.cvars
    cv.someOtherCVar = "0"
    A.Commands.ui("apply Base")
    local text = lines()
    check("cvar: protected skipped", text:find("Mouseover casting: protected by the client", 1, true) ~= nil)
    check("cvar: not allowlisted skipped", text:find("someOtherCVar: not supported on this build", 1, true) ~= nil)
    check("cvar: bad value skipped", text:find("the saved value isn't valid", 1, true) ~= nil)
    check("cvar: account scope said", text:find("Damage meter: off -> on (affects this WoW account)", 1, true) ~= nil)
    A._shown.onConfirm()
    eq("cvar: protected never written", UI.count("SetCVar:enableMouseoverCast"), 0)
    eq("cvar: not allowlisted never written", UI.count("SetCVar:someOtherCVar"), 0)
    eq("cvar: bad value never written", UI.count("SetCVar:raidFramesHealthBarColorBG"), 0)
    eq("cvar: others written", UI.cvars.raidFramesDisplayPowerBars, "1")
    check("cvar: skipped keys recorded", AltStableSyncChar.loaded.ui.skipped.cvars.enableMouseoverCast ~= nil)
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

finish("test_uisetup")
