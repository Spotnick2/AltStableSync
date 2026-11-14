------------------------------------------------------------
-- test_icons.lua - #105: a macro's chosen icon, never the one it shows
--
-- GetMacroInfo gives the icon a macro SHOWS: for a "?" macro, the icon of
-- the spell it uses. Blizzard's macro editor reads the CHOSEN icon with
-- C_Macro.GetSelectedMacroIcon, and so does AltStableSync now. Definitions
-- this build saves carry `sel = true`; an older build's definition (no
-- `sel`) holds a shown icon, which is never written back. Backups carry
-- `selIcons = true`; an older one's macro reverts are left as they are. The
-- mock (tests/wow_game.lua): spell N's icon is 900000 + N.
------------------------------------------------------------

dofile("tests/harness.lua")
dofile("tests/wow_stubs.lua")
dofile("tests/wow_game.lua")

local G = WoW.game
local A, L

local function boot()
    WoW.reset()
    for _, f in ipairs({ "Core.lua", "Categories.lua", "Catalog.lua", "Game.lua", "Pet.lua", "Share.lua", "Backups.lua",
                         "Ready.lua", "Loadout.lua", "Commands.lua" }) do
        assert(loadfile(f))("AltStableSync", {})
    end
    WoW.fire("ADDON_LOADED", "AltStableSync")
    A = AltStableSync
    L = A.Loadout
    A.Preview = { Show = function(o) A._shown = o end, Hide = function() A._shown = nil end,
                  Shown = function() return A._shown end }
    WoW.fire("PLAYER_ENTERING_WORLD", true, false)
    WoW.clock = WoW.clock + 10
end

local OLD, NEW = "/cast Flash Heal", "/cast Flash Heal\n/say healing"
local Q, CHOSEN = 134400, 135000
local SHOWN = 900000 + 2061             -- what a "?" macro using Flash Heal shows
local SPELLS = { { id = 2061, name = "Flash Heal" }, { id = 2050, name = "Lesser Heal" } }

local function heal(body) return { kind = "macro", name = "Heal", scope = "char", body = body or NEW } end

-- This character: Heal, a "?" macro that shows Flash Heal, on slot 2.
local function char(opts)
    opts = opts or {}
    G.setup{
        class = "PRIEST", guid = "Player-70-ALT", spells = SPELLS,
        macros = opts.macros or { { name = "Heal", body = OLD, char = true, icon = Q, shows = 2061 } },
        actions = opts.actions or { [2] = { macro = "Heal" } },
        keys = opts.keys or {},
    }
end

local function loadout(macros, actions, bindings)
    return assert(A.Catalog.Create("loadout", { class = "PRIEST", category = "general",
        name = "L" .. tostring(math.random(1, 1e9)) },
        { actions = actions or { [2] = heal() }, macros = macros, bindings = bindings, cover = { { 1, 12 } } }))
end

local function macro(name)
    local m = A.Game.MacrosNamed(name)
    return m and #m == 1 and m[1] or nil
end
local function text(lines) return table.concat(lines, "\n") end
local function has(s, sub) return s:find(sub, 1, true) ~= nil end

------------------------------------------------------------
-- The reader: the chosen icon, and nothing else
------------------------------------------------------------
do
    boot(); char()
    local _, shown = GetMacroInfo(121)
    eq("mock: a \"?\" macro shows its spell's icon", shown, SHOWN)
    eq("reader: the chosen icon", macro("Heal").icon, Q)
    local cap = L.Capture()
    eq("capture: the chosen icon", cap.macros.Heal.icon, Q)
    eq("capture: marked chosen", cap.macros.Heal.sel, true)
    -- What it captured loads back as no change, whatever the macro shows.
    local e = loadout({ Heal = cap.macros.Heal }, { [2] = heal(OLD) })
    G.char[1].shows = 2050
    local plan = L.Plan(e)
    eq("same macro, another spell shown: no edit", #plan.edits, 0)

    for _, fault in ipairs({ "error", "nil" }) do
        G.selectedIconFault = fault
        eq("reader: a chosen icon read that " .. fault .. "s: unreadable", A.Game.MacroInventory(), nil)
        G.selectedIconFault = nil
    end
    local real = C_Macro.GetSelectedMacroIcon
    C_Macro.GetSelectedMacroIcon = function() return 0 end
    eq("reader: no fileID: unreadable", A.Game.MacroInventory(), nil)
    C_Macro.GetSelectedMacroIcon = nil
    eq("reader: no GetSelectedMacroIcon: unreadable, never the shown icon", A.Game.MacroInventory(), nil)
    C_Macro.GetSelectedMacroIcon = real
    check("reader: back", A.Game.MacroInventory() ~= nil)
end

------------------------------------------------------------
-- A chosen icon in the loadout is written, created and read back
------------------------------------------------------------
do
    boot(); char()
    local e = loadout({ Heal = { body = OLD, icon = CHOSEN, sel = true } }, { [2] = heal(OLD) })
    local plan = L.Plan(e)
    eq("chosen: one edit", #plan.edits, 1)
    check("chosen: preview says icon changes", has(text(A.Commands.Describe(plan)), "  Heal: icon changes"))
    local r = L.Load(e, plan)
    check("chosen: loaded", r and not r.failed, r and r.failed)
    eq("chosen: icon set", macro("Heal").icon, CHOSEN)

    -- Created with its chosen icon; one created with another is a failure.
    boot(); char({ macros = {}, actions = {} })
    e = loadout({ Heal = { body = NEW, icon = CHOSEN, sel = true } })
    plan = L.Plan(e)
    eq("create: one", #plan.creates, 1)
    check("create: no unknown-icon note", not has(text(A.Commands.Describe(plan)), "didn't record its icon"))
    r = L.Load(e, plan)
    check("create: loaded", r and not r.failed, r and r.failed)
    eq("create: the chosen icon", macro("Heal").icon, CHOSEN)

    boot(); char({ macros = {}, actions = {} })
    e = loadout({ Heal = { body = NEW, icon = CHOSEN, sel = true } })
    plan = L.Plan(e)
    G.createFault = "icon"
    r = L.Load(e, plan)
    eq("create, another icon: failed", r and r.failed, "macro created with another icon")
    eq("create, another icon: at", r and r.at, "macro Heal")
end

------------------------------------------------------------
-- An older build's definition: its icon is history
------------------------------------------------------------
do
    -- The macro exists: only its text changes; the icon kept is the live
    -- chosen one, as a value (EditMacro's argument, the read-back, the backup).
    boot(); char()
    local e = loadout({ Heal = { body = NEW, icon = SHOWN } })
    local plan = L.Plan(e)
    eq("legacy edit: one edit", #plan.edits, 1)
    eq("legacy edit: keeps the chosen icon", plan.edits[1] and plan.edits[1].to.icon, Q)
    local t = text(A.Commands.Describe(plan))
    check("legacy edit: text changes only", has(t, "  Heal: text changes") and not has(t, "icon changes"), t)
    local r = L.Load(e, plan)
    check("legacy edit: loaded", r and not r.failed, r and r.failed)
    eq("legacy edit: new text", macro("Heal").body, NEW)
    eq("legacy edit: never frozen on the shown icon", macro("Heal").icon, Q)
    local snap = A.Backups.Get("1")
    eq("legacy edit: backup marked", snap.selIcons, true)
    eq("legacy edit: backup's after icon is the real one", snap.editedMacros[1].after.icon, Q)
    local rp = L.PlanRestore("1")
    local rr = L.Restore("1", rp)
    check("legacy edit: restored", rr and not rr.failed and not rr.partial, rr and (rr.failed or "partial"))
    eq("legacy edit: restore puts the text back", A.Game.Normalize(macro("Heal").body), OLD)
    eq("legacy edit: and the icon", macro("Heal").icon, Q)

    -- A later phase fails: the load's backup still puts back text and icon.
    boot(); char({ keys = { ["1"] = "ACTIONBUTTON2" } })
    e = loadout({ Heal = { body = NEW, icon = SHOWN } }, nil, { ACTIONBUTTON1 = { "1" } })
    plan = L.Plan(e)
    local realSet = SetBinding
    SetBinding = function() return false end
    r = L.Load(e, plan)
    SetBinding = realSet
    check("later phase fails: the load failed", r and r.failed ~= nil, r and r.failed)
    eq("later phase fails: the macro was updated", macro("Heal").body, NEW)
    rp = L.PlanRestore("op")
    rr = L.Restore("op", rp)
    check("later phase fails: restored", rr and not rr.failed, rr and rr.failed)
    eq("later phase fails: text back", A.Game.Normalize(macro("Heal").body), OLD)
    eq("later phase fails: icon back", macro("Heal").icon, Q)

    -- The macro must be created: "?", and the preview says why.
    boot(); char({ macros = {}, actions = {} })
    e = loadout({ Heal = { body = NEW, icon = SHOWN } })
    plan = L.Plan(e)
    eq("legacy create: \"?\"", plan.creates[1] and plan.creates[1].icon, Q)
    t = text(A.Commands.Describe(plan))
    check("legacy create: the preview says the icon wasn't recorded",
        has(t, "Heal: created with the \"?\" icon (the version that saved it didn't record its icon)"), t)
    r = L.Load(e, plan)
    check("legacy create: loaded", r and not r.failed, r and r.failed)
    eq("legacy create: \"?\"", macro("Heal").icon, Q)

    -- An older definition that recorded "?" needs no note: "?" is "?".
    boot(); char({ macros = {}, actions = {} })
    plan = L.Plan(loadout({ Heal = { body = NEW, icon = Q } }))
    check("legacy \"?\": no note", not has(text(A.Commands.Describe(plan)), "didn't record its icon"))
end

------------------------------------------------------------
-- Save: an older definition and a fresh one of the same macro
------------------------------------------------------------
do
    -- Loaded from an older definition (Heal on slot 2); then the player puts
    -- Heal on slot 5 too. Slot 2 keeps the loadout's definition, slot 5 is a
    -- fresh capture: same text, so the chosen icon is kept, not a clash.
    boot(); char()
    local e = loadout({ Heal = { body = OLD, icon = SHOWN } }, { [2] = heal(OLD) })
    local plan = L.Plan(e)
    eq("save: the load changes nothing in the macro", #plan.edits, 0)
    local r = L.Load(e, plan)
    check("save: loaded", r and not r.failed, r and r.failed)
    G.actions[5] = { kind = "macro", ref = G.char[1] }
    local m, err = L.PlanSave()
    check("save: no clash", m ~= nil, err)
    eq("save: the chosen definition", m and m.modules.macros.Heal.sel, true)
    eq("save: its icon", m and m.modules.macros.Heal.icon, Q)
    local saved, serr = L.Save(m)
    check("save: saved", saved ~= nil, serr)

    -- Two older definitions that disagree still clash (nothing to prefer).
    boot(); char()
    -- Slot 2 unchanged since the load (B's definition), slot 5 new (C's).
    local merged, why = L.Merge({ baseline = { cover = { { 1, 12 } }, actions = { [2] = heal(OLD) },
                                              macros = { Heal = { body = OLD, icon = 1 } } },
                                  after = { cover = { { 1, 12 } }, actions = { [2] = heal(OLD) },
                                            macros = { Heal = { body = OLD, icon = 2 } } } },
        { cover = { { 1, 12 } }, actions = { [2] = heal(OLD), [5] = heal(OLD) }, macros = { Heal = { body = OLD, icon = 2 } } })
    check("save: two older icons that differ clash", merged == nil and has(tostring(why), "differs"), why)
end

------------------------------------------------------------
-- Backups: an older build's macro reverts; the duplicate check
------------------------------------------------------------
do
    boot(); char()
    local e = loadout({ Heal = { body = NEW, icon = CHOSEN, sel = true } })
    local r = L.Load(e, L.Plan(e))
    check("old backup: loaded", r and not r.failed, r and r.failed)
    local snap = A.Backups.Get("1")
    snap.selIcons = nil                          -- as an older build wrote it
    local rp = L.PlanRestore("1")
    eq("old backup: no revert planned", #rp.edits, 0)
    local why
    for _, u in ipairs(rp.unavailable) do if u.name == "Heal" then why = u.reason end end
    check("old backup: the macro is listed", why and has(why, "older version that didn't record its icon exactly"), why)
    local rr = L.Restore("1", rp)
    check("old backup: partial", rr and rr.partial, rr and rr.failed)
    eq("old backup: the macro left as is", macro("Heal").body, NEW)
    eq("old backup: its icon too", macro("Heal").icon, CHOSEN)
    check("old backup: still there to restore", A.Backups.Get("1") ~= nil)

    -- The newest backup is an older build's: a fresh one with the same
    -- content isn't "nothing new"; once stored, the next one is.
    boot(); char()
    local p = L.PlanBackup()
    check("backup: planned", p ~= nil)
    check("backup: stored", L.Backup(p) ~= nil)
    A.Backups.Get("1").selIcons = nil
    p = L.PlanBackup()
    eq("backup: an older newest backup is not the same", p.matches, false)
    check("backup: stored again", L.Backup(p) ~= nil)
    p = L.PlanBackup()
    eq("backup: now it is", p.matches, true)
end

------------------------------------------------------------
-- Validation: `sel` is only ever true, with a fileID
------------------------------------------------------------
do
    boot()
    local S = A.Share
    local function mods(def) return { cover = { { 1, 12 } }, actions = { [2] = heal() }, macros = { Heal = def } } end
    for _, mode in ipairs({ "strict", "lenient" }) do
        check(mode .. ": sel accepted", S.GoodModules(mods({ body = NEW, icon = Q, sel = true }), mode))
        check(mode .. ": no sel accepted", S.GoodModules(mods({ body = NEW, icon = SHOWN }), mode))
        check(mode .. ": sel false refused", not S.GoodModules(mods({ body = NEW, icon = Q, sel = false }), mode))
        check(mode .. ": sel a string refused", not S.GoodModules(mods({ body = NEW, icon = Q, sel = "yes" }), mode))
        check(mode .. ": sel without a fileID refused",
            not S.GoodModules(mods({ body = NEW, icon = "INV_Misc_QuestionMark", sel = true }), mode))
    end
end

------------------------------------------------------------
-- 12 -> 13: the loaded record's comparison
------------------------------------------------------------
local function core(db, ch)
    WoW.reset()
    assert(loadfile("Core.lua"))("AltStableSync", {})
    AltStableSyncDB, AltStableSyncChar = db, ch
    WoW.fire("ADDON_LOADED", "AltStableSync")
    return AltStableSync
end
local COVER = { { 1, 12 } }
local function record(after)
    return { id = "loadout-x-1", version = "x:1", baseline = { actions = {}, cover = COVER, macros = { Heal = { body = OLD, icon = SHOWN } } },
             after = after, unavailable = { [3] = "not learned" } }
end
do
    local withMacro = { actions = { [2] = heal(OLD) }, cover = COVER, macros = { Heal = { body = OLD, icon = SHOWN } } }
    local ch = { schema = 12, loaded = { loadout = record(withMacro) } }
    core({ schema = 12, presets = {} }, ch)
    eq("12->13: char stamped", AltStableSyncChar.schema, 13)
    eq("12->13: a comparison with a character macro is dropped", AltStableSyncChar.loaded.loadout.after, nil)
    eq("12->13: with its unavailable list", AltStableSyncChar.loaded.loadout.unavailable, nil)
    check("12->13: the baseline stays", AltStableSyncChar.loaded.loadout.baseline.macros.Heal.icon == SHOWN)

    -- Only a definition (no slot uses it): dropped too.
    ch = { schema = 12, loaded = { loadout = record({ actions = {}, cover = COVER, macros = { Heal = { body = OLD } } }) } }
    core({ schema = 12, presets = {} }, ch)
    eq("12->13: a definition alone: dropped", AltStableSyncChar.loaded.loadout.after, nil)

    -- No character macro: kept as it is.
    local plain = { actions = { [1] = { kind = "spell", id = 2061 } }, cover = COVER }
    ch = { schema = 12, loaded = { loadout = record(plain) } }
    core({ schema = 12, presets = {} }, ch)
    check("12->13: no character macro: kept", AltStableSyncChar.loaded.loadout.after == plain)

    -- Another character already upgraded the account: this one's own schema decides.
    ch = { schema = 12, loaded = { loadout = record(withMacro) } }
    core({ schema = 13, presets = {} }, ch)
    eq("DB 13, char 12: dropped", AltStableSyncChar.loaded.loadout.after, nil)
    -- An upgraded character keeps its (new) comparison.
    local fresh = { actions = { [2] = heal(OLD) }, cover = COVER, macros = { Heal = { body = OLD, icon = Q, sel = true } } }
    ch = { schema = 13, loaded = { loadout = record(fresh) } }
    core({ schema = 12, presets = {} }, ch)
    check("DB 12, char 13: kept", AltStableSyncChar.loaded.loadout.after == fresh)
    -- The catalog is never rewritten.
    local entry = { id = "loadout-y-1", kind = "loadout", class = "PRIEST", category = "general", name = "Y", version = "y:1",
                    modules = { actions = {}, cover = COVER, macros = { Heal = { body = OLD, icon = SHOWN } } } }
    core({ schema = 12, presets = { [entry.id] = entry } }, { schema = 12 })
    eq("12->13: catalog entries unchanged", AltStableSyncDB.presets[entry.id].modules.macros.Heal.icon, SHOWN)
    eq("12->13: and unmarked", AltStableSyncDB.presets[entry.id].modules.macros.Heal.sel, nil)
    eq("12->13: same version", AltStableSyncDB.presets[entry.id].version, "y:1")
end

finish("test_icons")
