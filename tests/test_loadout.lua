------------------------------------------------------------
-- test_loadout.lua - the #4 vertical slice: capture, plan, load, restore
--
-- Against the Forever-shaped game model in tests/wow_game.lua. Covers
-- docs/ACCEPTANCE.md A02, A07, A10, A11, A13, A15, A17, A18, A20, A21, A22,
-- A23, A24, A25, A26, A27, A38 as far as stubs can, and every case the #4 plan
-- review named: a conflicting macro name, an unsupported occupied
-- destination, a two-command key swap, displacing an unrelated command's key
-- and restoring it, interruption after a macro creation and after a binding
-- write, a restore from the pinned operation. Client behaviour and
-- persistence still need the in-game rehearsal (#13).
------------------------------------------------------------

dofile("tests/harness.lua")
dofile("tests/wow_stubs.lua")
dofile("tests/wow_game.lua")

local G = WoW.game
local FULL = { { 1, 120 }, { 145, 180 } }   -- every measured slot (#5)
local A, L

-- Spells: Flash Heal r1/r2, Lesser Heal r1/r2, Greater Heal (top), a future spell.
local MAIN_SPELLS = {
    { id = 2061, name = "Flash Heal", low = true }, { id = 9472, name = "Flash Heal" },
    { id = 2050, name = "Lesser Heal", low = true }, { id = 2052, name = "Lesser Heal" },
    { id = 2060, name = "Greater Heal" },
}
local MAIN_MACROS = {
    { name = "Shield", body = "/cast Power Word: Shield", char = true, shows = 17 },
    { name = "Acct", body = "/say hi", char = false },
    { name = "Dup", body = "/one", char = true }, { name = "Dup", body = "/two", char = false },
}

local function boot()
    WoW.reset()
    for _, f in ipairs({ "Core.lua", "Categories.lua", "Catalog.lua", "Game.lua", "Backups.lua",
                         "Ready.lua", "Loadout.lua", "Commands.lua" }) do
        assert(loadfile(f))("AltStableSync", {})
    end
    WoW.fire("ADDON_LOADED", "AltStableSync")
    A = AltStableSync
    L = A.Loadout
    A.Preview = { Show = function(o) A._shown = o end, Hide = function() A._shown = nil end,
                  Shown = function() return A._shown end }
end

local function ready()
    WoW.fire("PLAYER_ENTERING_WORLD", true, false)
    WoW.clock = WoW.clock + 10
end

local function main()
    G.setup{
        class = "PRIEST", guid = "Player-70-MAIN",
        spells = MAIN_SPELLS, items = { [5512] = 3 }, macros = MAIN_MACROS,
        actions = {
            [1] = { spell = 9472 },                 -- Flash Heal, top rank -> highest
            [2] = { spell = 2050 },                 -- Lesser Heal r1 below slot 12's r2 -> exact (#42 ladder)
            [3] = { item = 5512 },                  -- Healthstone
            [4] = { macro = "Shield" },             -- character macro
            [5] = { macro = "Acct" },               -- account macro
            [6] = { flyout = 1 },                   -- unsupported
            [7] = { macro = "Dup" },                -- ambiguous name -> unsupported
            [8] = { spell = 2060 },                 -- Greater Heal (an alt won't know it)
            [12] = { spell = 2052 },                -- Lesser Heal r2: with slot 2, a rank ladder
        },
        keys = { ["1"] = "ACTIONBUTTON1", ["2"] = "ACTIONBUTTON2", ["SHIFT-2"] = "ACTIONBUTTON2" },
    }
end

-- Every supported slot (#5) plus two excluded sentinels, so "restored
-- exactly" and "never touched" cover the whole surface.
local function state()
    local parts = {}
    local slots = {}
    for _, slot in ipairs(A.Game.SLOT_LIST) do slots[#slots + 1] = slot end
    slots[#slots + 1], slots[#slots + 2] = 130, 185
    for _, slot in ipairs(slots) do
        local a = G.actions[slot]
        if a then
            parts[#parts + 1] = slot .. "=" .. a.kind .. ":" .. tostring(a.kind == "macro" and a.ref.name or a.id)
        end
    end
    local keys = {}
    for k, c in pairs(G.keys) do keys[#keys + 1] = k .. ">" .. c end
    table.sort(keys)
    return table.concat(parts, " ") .. " | " .. table.concat(keys, " ")
end

------------------------------------------------------------
-- Readiness
------------------------------------------------------------
do
    boot(); main()
    check("ready: not before entering the world", L.Blocked() ~= nil)
    WoW.fire("PLAYER_ENTERING_WORLD", true, false)
    WoW.fire("UPDATE_MACROS")
    check("ready: not while macros still arrive", (L.Blocked() or ""):find("still loading") ~= nil, L.Blocked())
    WoW.clock = WoW.clock + 3
    eq("ready: after 2 s of quiet", L.Blocked(), nil)
    G.cursor = { kind = "item", id = 5512 }
    check("A23: cursor busy blocks", (L.Blocked() or ""):find("cursor") ~= nil)
    G.cursor = nil
    G.combat = true
    check("combat blocks", (L.Blocked() or ""):find("combat") ~= nil)
    G.combat = false
end

------------------------------------------------------------
-- Capture
------------------------------------------------------------
local captured
do
    boot(); main(); ready()
    local m = L.Capture()
    captured = m
    eq("capture: top rank -> highest", m.actions[1].policy, "highest")
    eq("capture: name kept for the family", m.actions[1].name, "Flash Heal")
    eq("A11: deliberate downrank -> exact", m.actions[2].policy, "exact")
    eq("#42: the ladder's highest rank -> highest", m.actions[12].policy, "highest")
    eq("capture: item", m.actions[3].kind .. ":" .. m.actions[3].id, "item:5512")
    eq("A15: macro by name, not the shown spell id", m.actions[4].name, "Shield")
    eq("capture: char macro scope", m.actions[4].scope, "char")
    eq("capture: char macro definition kept", m.macros.Shield.body, "/cast Power Word: Shield")
    eq("capture: account macro scope", m.actions[5].scope, "account")
    eq("capture: account macro not in definitions", m.macros.Acct, nil)
    eq("capture: flyout unsupported", m.actions[6].kind, "unsupported")
    eq("capture: duplicate name unsupported", m.actions[7].what, "duplicate macro name")
    eq("capture: bindings both keys", table.concat(m.bindings.ACTIONBUTTON2, ","), "2,SHIFT-2")
    eq("capture: wrote nothing", #G.calls, 0)
end

------------------------------------------------------------
-- Load on a lower-level alt (A02, A07, A10, A13, A20/21 via keys)
------------------------------------------------------------
local function alt(opts)
    opts = opts or {}
    G.setup{
        class = opts.class or "PRIEST", guid = "Player-70-ALT",
        bindingSet = opts.bindingSet,
        charStore = opts.charStore,
        extra = opts.extra,
        spells = opts.spells or {
            { id = 2061, name = "Flash Heal" },             -- only rank 1: it is this alt's top
            { id = 2050, name = "Lesser Heal", low = true }, { id = 2052, name = "Lesser Heal" },
        },
        items = opts.items or { [5512] = 1, [4540] = 5 },
        macros = opts.macros or { { name = "Acct", body = "/say hi" }, { name = "Zed", body = "/z", char = true } },
        actions = opts.actions or { [8] = { item = 4540 }, [6] = { spell = 2050 } },   -- food where Greater Heal goes
        keys = opts.keys or { ["1"] = "ACTIONBUTTON2", ["2"] = "ACTIONBUTTON1", ["SHIFT-2"] = "MOVEFORWARD" },
    }
end

local entry
local function save()
    entry = A.Catalog.Create("loadout", { class = "PRIEST", category = "general", name = "Everyday" }, captured)
    assert(entry, "save failed")
end

do
    boot(); ready(); save()
    alt()
    local before = state()
    local plan = L.Plan(entry)
    eq("plan: not blocked", plan.blocked, nil)
    eq("plan: wrote nothing", #G.calls, 0)
    local why, emptied = {}, {}
    for _, s in ipairs(plan.skips) do why[s.slot] = s.reason end
    for _, op in ipairs(plan.actions) do if op.target == nil then emptied[op.slot] = op.why or "empty" end end
    eq("A07: food emptied where the future spell goes (#46)", emptied[8], "not learned")
    eq("A07: not listed as left unchanged", why[8], nil)
    eq("plan: flyout skipped", why[6], "not supported yet")
    eq("plan: ambiguous macro skipped", why[7], "not supported yet")
    eq("plan: one macro to create", #plan.creates, 1)
    local lines = A.Commands.Describe(plan)
    check("preview: mentions the destination", table.concat(lines, "\n"):find("Destination: Character") ~= nil)

    local r = L.Load(entry, plan)
    check("A02: loaded", r and not r.failed, r and r.failed)
    eq("A10: highest known rank on the alt", G.actions[1].id, 2061)
    eq("A11: exact downrank kept exact", G.actions[2].id, 2050)
    eq("load: item placed", G.actions[3].id, 5512)
    eq("load: char macro created and placed", G.actions[4].kind == "macro" and G.actions[4].ref.name, "Shield")
    eq("load: account macro reused", G.actions[5].ref.name, "Acct")
    eq("A07: food emptied where the future spell goes (#46)", G.actions[8], nil)
    eq("load: slot 6 kept (unsupported in entry)", G.actions[6].id, 2050)
    eq("A21: key swap", G.keys["1"] .. "," .. G.keys["2"], "ACTIONBUTTON1,ACTIONBUTTON2")
    eq("load: displaced unrelated key", G.keys["SHIFT-2"], "ACTIONBUTTON2")
    eq("load: saved to the character set", G.savedKeys["SHIFT-2"], "ACTIONBUTTON2")
    eq("load: macro still unique by name", #A.Game.MacrosNamed("Shield"), 1)
    for _, c in ipairs(G.calls) do
        check("load: never " .. c, c ~= "EditMacro" and c ~= "DeleteMacro" and c ~= "LoadBindings")
    end
    eq("load: cursor empty after", G.cursor, nil)
    local ring, op = A.Backups.List()
    eq("load: backup released into the ring", #ring, 1)
    eq("load: nothing pinned", op, nil)
    eq("load: loaded recorded", A.char.loaded.loadout.id, entry.id)

    -- A26: exact restore of what the load replaced (bindings incl. the
    -- unrelated command's key), macros it created kept and reported.
    local rp = L.PlanRestore(1)
    eq("restore: created macro reported as kept", #rp.kept, 1)
    local rr = L.Restore(1, rp)
    check("A26: restored", rr and not rr.failed, rr and rr.failed)
    eq("A26: back exactly", state(), before)
    eq("A26: SHIFT-2 back to MOVEFORWARD", G.keys["SHIFT-2"], "MOVEFORWARD")
    check("restore: the created macro was not deleted", #A.Game.MacrosNamed("Shield") == 1)
    eq("restore: its own backup in the ring", #(select(1, A.Backups.List())), 2)
    eq("restore: cursor empty", G.cursor, nil)
end

------------------------------------------------------------
-- No-op, trailing newline after a full exit (A17)
------------------------------------------------------------
do
    boot(); ready(); save()
    alt()
    L.Load(entry, L.Plan(entry))
    WoW.relaunch()
    ready()
    G.calls = {}
    local plan = L.Plan(entry)
    check("A17: after the server newline, nothing to do", plan.noop, plan.signature)
    local conflicts = 0
    for _, sk in ipairs(plan.skips) do if sk.reason == "macro name conflict" then conflicts = conflicts + 1 end end
    eq("A17: the newline is not a conflict", conflicts, 0)
    local r = L.Load(entry, plan)
    check("no-op: reported", r and r.noop)
    eq("no-op: wrote nothing", #G.calls, 0)
    eq("no-op: no new backup", #(select(1, A.Backups.List())), 1)
    eq("no-op: still recorded as loaded", A.char.loaded.loadout.id, entry.id)
end

------------------------------------------------------------
-- Refusals that must write nothing
------------------------------------------------------------
local function noWrites(label, setupFn, wantErr)
    boot(); ready(); save()
    setupFn()
    G.calls = {}
    local plan = L.Plan(entry)
    local r, err = L.Load(entry, plan)
    check(label .. ": refused", r == nil, tostring(r))
    if wantErr then check(label .. ": why", tostring(err):find(wantErr, 1, true) ~= nil, tostring(err)) end
    eq(label .. ": wrote nothing", #G.calls, 0)
end

noWrites("other class", function() alt({ class = "MAGE" }) end, "another class")
noWrites("A23 cursor busy", function() alt(); G.cursor = { kind = "item", id = 4540 } end, "cursor")
noWrites("combat", function() alt(); G.combat = true end, "combat")
noWrites("A24 backup can't be stored", function() alt(); G.guid = nil end, "no-guid")

-- A38: the slot changed after the preview -> refused, nothing written.
do
    boot(); ready(); save(); alt()
    local plan = L.Plan(entry)
    G.actions[1] = { kind = "item", id = 4540 }
    G.calls = {}
    local r, err = L.Load(entry, plan)
    check("A38: stale preview refused", r == nil and tostring(err):find("changed") ~= nil, tostring(err))
    eq("A38: wrote nothing", #G.calls, 0)
end

------------------------------------------------------------
-- Skips that must not write their slot
------------------------------------------------------------
do
    -- A conflicting macro name on the alt: never create a second "Shield".
    boot(); ready(); save()
    alt({ macros = { { name = "Shield", body = "/different", char = true }, { name = "Acct", body = "/say hi" } } })
    local plan = L.Plan(entry)
    local why = {}
    for _, s in ipairs(plan.waiting) do why[s.slot] = s.reason end
    eq("conflict: stays empty, with the reason", why[4], "macro name conflict")
    eq("conflict: nothing to create", #plan.creates, 0)
    L.Load(entry, plan)
    eq("conflict: still one Shield", #A.Game.MacrosNamed("Shield"), 1)
    eq("conflict: its body untouched", A.Game.MacrosNamed("Shield")[1].body, "/different")

    -- An occupied destination this slice can't restore exactly.
    boot(); ready(); save()
    alt({ actions = { [1] = { flyout = 7 } } })
    plan = L.Plan(entry)
    why = {}
    for _, s in ipairs(plan.skips) do why[s.slot] = s.reason end
    eq("unrestorable destination: skipped", why[1], "slot holds something this slice can't put back")
    L.Load(entry, plan)
    eq("unrestorable destination: untouched", G.actions[1].kind, "flyout")

    -- A18: macro slots full.
    boot(); ready(); save()
    local full = { { name = "Acct", body = "/say hi" } }
    for i = 1, 30 do full[#full + 1] = { name = ("M%02d"):format(i), body = "/m" .. i, char = true } end
    alt({ macros = full })
    plan = L.Plan(entry)
    why = {}
    for _, s in ipairs(plan.waiting) do why[s.slot] = s.reason end
    eq("A18: macro slots full", why[4], "macro slots full")
    G.calls = {}
    L.Load(entry, plan)
    for _, c in ipairs(G.calls) do check("A18: no CreateMacro", c ~= "CreateMacro") end

    -- Account macro missing: never created.
    boot(); ready(); save()
    alt({ macros = { { name = "Zed", body = "/z", char = true } } })
    plan = L.Plan(entry)
    why = {}
    for _, s in ipairs(plan.waiting) do why[s.slot] = s.reason end
    eq("account macro missing: stays empty, with the reason", why[5], "account macro missing")

    -- A20: account bindings -> the load is blocked with the instruction (#7:
    -- block and explain; never a partial load reported as done).
    boot(); ready(); save()
    alt({ bindingSet = 1 })
    plan = L.Plan(entry)
    check("A20: load blocked with the instruction", (plan.blocked or ""):find("character%-specific") ~= nil, tostring(plan.blocked))
    G.calls = {}
    local r, err = L.Load(entry, plan)
    check("A20: refused", r == nil and tostring(err):find("character%-specific") ~= nil)
    eq("A20: nothing written", #G.calls, 0)
    A.Commands.load("Everyday")
    eq("A20: preview offers the switch (#7)", A._shown.confirm, "OK")
    -- A set that can't be read is not Account: no switch offered.
    G.bindingSet = nil
    A.Commands.load("Everyday")
    eq("#7: unreadable set: no switch", A._shown.confirm, false)
end

------------------------------------------------------------
-- Interruptions: combat after a macro creation, mid-actions, at bindings;
-- read-back failure; SaveBindings failure. Each leaves the backup pinned, and
-- `restore op` returns exactly.
------------------------------------------------------------
local function interrupted(label, arrange, wantWhy, cleanup)
    boot(); ready(); save(); alt()
    local before = state()
    local plan = L.Plan(entry)
    arrange()
    local r = L.Load(entry, plan)
    if cleanup then cleanup() end
    eq(label .. ": cursor empty after the stop", G.cursor, nil)
    check(label .. ": stopped", r and r.failed ~= nil, r and tostring(r.failed))
    if wantWhy then eq(label .. ": why", r and tostring(r.failed):sub(1, #wantWhy), wantWhy) end
    check(label .. ": backup pinned", A.Backups.Operation() ~= nil)
    check(label .. ": interrupted recorded", A.char.interrupted ~= nil)
    -- No resume: a plain Load is refused until abandoned.
    G.combat, G.combatAfter = false, nil
    local again, err = L.Load(entry, L.Plan(entry))
    eq(label .. ": another load refused while pinned", err, "incomplete")
    -- Restore the pinned operation.
    local rp = L.PlanRestore("op")
    local rr = L.Restore("op", rp)
    check(label .. ": restored", rr and not rr.failed, rr and tostring(rr.failed))
    eq(label .. ": back exactly", state(), before)
    eq(label .. ": released", A.Backups.Operation(), nil)
    eq(label .. ": cursor empty", G.cursor, nil)
end

interrupted("combat after macro creation", function() G.combatAfter = 1 end, "combat")
interrupted("combat mid-actions", function() G.combatAfter = 6 end, "combat")
local realPlace = PlaceAction
interrupted("place never lands (A25)", function()
    PlaceAction = function() WoW.game.calls[#WoW.game.calls + 1] = "PlaceAction" end   -- does nothing
end, "place failed", function() PlaceAction = realPlace end)
interrupted("read-back differs (A25)", function()
    -- Places the WRONG spell: lands, but reads back different.
    PlaceAction = function(slot)
        WoW.game.calls[#WoW.game.calls + 1] = "PlaceAction"
        WoW.game.actions[slot] = { kind = "spell", id = 2052 }
        WoW.game.cursor = nil
    end
end, "verify failed", function() PlaceAction = realPlace end)
interrupted("SaveBindings fails", function() G.saveFails = true end, "bindings not saved",
            function() G.saveFails = false end)
-- Codex follow-up: a hook changes a planned key while saving. The post-save
-- read-back catches it; the work stays pending and the backup pinned.
local realSaveB = SaveBindings
interrupted("key changed while saving", function()
    SaveBindings = function(set)
        WoW.game.keys["SHIFT-2"] = "ACTIONBUTTON12"
        return realSaveB(set)
    end
end, "bindings changed while saving", function()
    SaveBindings = realSaveB
    check("key changed while saving: still unsaved", A.char.bindingsUnsaved == true)
end)

-- Combat begins in the middle of the binding writes. Rollback is a protected
-- call too, so it can't run in combat: nothing is attempted in combat, nothing
-- is saved, the backup stays pinned, and `restore op` after combat puts every
-- key back exactly.
do
    boot(); ready(); save(); alt()
    local before = state()
    local plan = L.Plan(entry)
    local realSet = SetBinding
    local nSet = 0
    SetBinding = function(k, c)
        local r = realSet(k, c)
        nSet = nSet + 1
        if nSet == 2 then WoW.game.combat = true end
        return r
    end
    local r = L.Load(entry, plan)
    SetBinding = realSet
    check("combat at bindings: stopped", r and tostring(r.failed):find("combat") ~= nil, r and tostring(r.failed))
    eq("combat at bindings: no protected call attempted in combat", #G.blocked, 0)
    eq("combat at bindings: not saved", G.savedKeys["SHIFT-2"], "MOVEFORWARD")
    check("combat at bindings: backup pinned", A.Backups.Operation() ~= nil)
    G.combat = false
    local rr = L.Restore("op", L.PlanRestore("op"))
    check("combat at bindings: restored after combat", rr and not rr.failed, rr and tostring(rr.failed))
    eq("combat at bindings: back exactly", state(), before)
end

-- Combat between the pickup and the place: no PlaceAction in combat, and the
-- cursor is not left holding our pickup.
do
    boot(); ready(); save(); alt()
    local plan = L.Plan(entry)
    local realPick = C_Spell.PickupSpell
    C_Spell.PickupSpell = function(id) realPick(id); WoW.game.combat = true end
    local r = L.Load(entry, plan)
    C_Spell.PickupSpell = realPick
    eq("combat after pickup: stopped", r and r.failed, "combat")
    eq("combat after pickup: nothing protected attempted in combat", #G.blocked, 0)
    eq("combat after pickup: cursor empty", G.cursor, nil)
    G.combat = false
end

-- A client call that throws: caught, cursor cleaned, interruption recorded.
do
    boot(); ready(); save(); alt()
    local plan = L.Plan(entry)
    local realPlace = PlaceAction
    PlaceAction = function() error("boom") end
    local ok, r = pcall(L.Load, entry, plan)
    PlaceAction = realPlace
    check("throwing client call: Load did not raise", ok, tostring(r))
    check("throwing client call: reported", ok and r and tostring(r.failed):find("client error") ~= nil, ok and r and tostring(r.failed))
    eq("throwing client call: cursor empty", G.cursor, nil)
    check("throwing client call: interruption recorded", A.char.interrupted ~= nil)
end

-- The binding set switches to Account mid-apply: no binding write.
do
    boot(); ready(); save(); alt()
    local plan = L.Plan(entry)
    local realPlace = PlaceAction
    PlaceAction = function(slot) realPlace(slot); WoW.game.bindingSet = 1 end
    G.calls = {}
    local r = L.Load(entry, plan)
    PlaceAction = realPlace
    eq("set switched: stopped", r and r.failed, "binding set changed")
    for _, c in ipairs(G.calls) do check("set switched: no binding write", c ~= "SetBinding" and c ~= "SaveBindings") end
    check("set switched: backup pinned", A.Backups.Operation() ~= nil)
end

-- CreateMacro "succeeds" but the macro reads back wrong: stop before placing it.
do
    boot(); ready(); save(); alt()
    local plan = L.Plan(entry)
    local realCreate = CreateMacro
    CreateMacro = function(name, icon, body, perChar) return realCreate(name, icon, body:sub(1, 5), perChar) end
    local r = L.Load(entry, plan)
    CreateMacro = realCreate
    eq("bad create: stopped", r and r.failed, "macro not created")
    check("bad create: nothing placed", G.actions[4] == nil)
    check("bad create: backup pinned", A.Backups.Operation() ~= nil)
end

-- A stale extra key on one of the commands is unbound, and restore brings it back.
do
    boot(); ready(); save()
    alt({ keys = { ["1"] = "ACTIONBUTTON1", ["Q"] = "ACTIONBUTTON1", ["2"] = "ACTIONBUTTON2" } })
    local before = state()
    local plan = L.Plan(entry)
    eq("stale key: planned unbind", plan.keys.Q and tostring(plan.keys.Q.to), "false")
    L.Load(entry, plan)
    eq("stale key: Q unbound", G.keys.Q, nil)
    L.Restore(1, L.PlanRestore(1))
    eq("stale key: restore brings Q back", state(), before)
end

-- Abandoning a pinned load: its backup moves into the ring, the new load runs.
do
    boot(); ready(); save(); alt()
    local plan = L.Plan(entry)
    G.combatAfter = 4
    L.Load(entry, plan)
    G.combat = false
    local r = L.Load(entry, L.Plan(entry), true)
    check("abandon: new load ran", r and not r.failed, r and tostring(r.failed))
    eq("abandon: old backup kept in the ring + the new one", #(select(1, A.Backups.List())), 2)
end

-- A27: an exact value that no longer exists is reported, never substituted.
do
    boot(); ready(); save()
    alt({ actions = { [1] = { spell = 2050 } } })    -- slot 1 holds Lesser Heal r1 before the load
    L.Load(entry, L.Plan(entry))
    eq("A27 setup: load replaced slot 1", G.actions[1].id, 2061)
    for _, sp in ipairs(G.spells) do if sp.id == 2050 then sp.known = false end end
    local rp = L.PlanRestore(1)
    local reason
    for _, u in ipairs(rp.unavailable) do if u.slot == 1 then reason = u.reason end end
    eq("A27: reported unavailable in the preview", reason, "spell no longer known")
    check("A27: preview says so", table.concat(A.Commands.Describe(rp), "\n"):find("can't be restored exactly") ~= nil)
    local rr = L.Restore(1, rp)
    check("A27: reported partial", rr and rr.partial == true)
    eq("A27: slot 1 not substituted with another rank", G.actions[1].id, 2061)
end

------------------------------------------------------------
-- Hand-made entries for the edge cases the review named
------------------------------------------------------------
local function custom(modules)
    modules.cover = modules.cover or FULL
    return assert(A.Catalog.Create("loadout", { class = "PRIEST", category = "general",
        name = "Custom " .. tostring(math.random(1, 1e9)) }, modules))
end

-- Restore over a slot that now holds something it couldn't put back (a used-up
-- item): reported, slot untouched.
do
    boot(); ready(); save(); alt()
    L.Load(entry, L.Plan(entry))
    G.actions[1] = { kind = "item", id = 9999 }          -- on the bar, 0 in the bags
    local rp = L.PlanRestore(1)
    local reason
    for _, u in ipairs(rp.unavailable) do if u.slot == 1 then reason = u.reason end end
    eq("restore destination: reported", reason, "slot now holds something that couldn't be put back")
    L.Restore(1, rp)
    eq("restore destination: untouched", G.actions[1].id, 9999)
end

-- A macro is never created for a slot that is skipped.
do
    boot(); ready()
    local e = custom({ actions = { [1] = { kind = "macro", name = "Fresh", body = "/fresh", scope = "char" } },
                       macros = { Fresh = { body = "/fresh" } } })
    alt({ actions = { [1] = { flyout = 3 } } })
    local plan = L.Plan(e)
    eq("skipped slot: no macro to create", #plan.creates, 0)
    L.Load(e, plan)
    eq("skipped slot: macro not created", #A.Game.MacrosNamed("Fresh"), 0)
end

-- Bindings: a missing first key never hides the second; a third key on the
-- command is unbound when the entry doesn't want it.
do
    boot(); ready()
    local e = custom({ bindings = { ACTIONBUTTON1 = { [2] = "Q" } } })
    alt({ keys = { ["1"] = "ACTIONBUTTON1" } })
    L.Load(e, L.Plan(e))
    eq("key hole: Q bound", G.keys.Q, "ACTIONBUTTON1")
    eq("key hole: 1 unbound (not wanted)", G.keys["1"], nil)

    boot(); ready()
    local e2 = custom({ bindings = { ACTIONBUTTON1 = { "1" } } })
    alt({ keys = { ["1"] = "ACTIONBUTTON1", ["Q"] = "ACTIONBUTTON1", ["Z"] = "ACTIONBUTTON1" } })
    L.Load(e2, L.Plan(e2))
    eq("three keys: Q unbound", G.keys.Q, nil)
    eq("three keys: Z unbound", G.keys.Z, nil)
    eq("three keys: 1 kept", G.keys["1"], "ACTIONBUTTON1")
    -- And capture keeps all of them.
    alt({ keys = { ["1"] = "ACTIONBUTTON1", ["Q"] = "ACTIONBUTTON1", ["Z"] = "ACTIONBUTTON1" } })
    eq("three keys: captured", table.concat(L.Capture().bindings.ACTIONBUTTON1, ","), "1,Q,Z")
end

-- Reindex: creating "Ant" shifts the existing "Zed"; placing Zed afterwards
-- must use its NEW index (indices are looked up at placement time).
do
    boot(); ready()
    local e = custom({
        actions = { [9] = { kind = "macro", name = "Ant", body = "/ant", scope = "char" },
                    [10] = { kind = "macro", name = "Zed", body = "/z", scope = "char" } },
        macros = { Ant = { body = "/ant" }, Zed = { body = "/z" } } })
    alt()                                                -- has char macro Zed at 121
    eq("reindex setup: Zed at 121", A.Game.MacrosNamed("Zed")[1].index, 121)
    local r = L.Load(e, L.Plan(e))
    check("reindex: loaded", r and not r.failed, r and tostring(r.failed))
    eq("reindex: Zed moved to 122", A.Game.MacrosNamed("Zed")[1].index, 122)
    eq("reindex: slot 9 is Ant", G.actions[9].ref.name, "Ant")
    eq("reindex: slot 10 is Zed", G.actions[10].ref.name, "Zed")
end

------------------------------------------------------------
-- Round-2 review cases
------------------------------------------------------------

-- A restore interrupted after SetBinding but before SaveBindings, then retried
-- out of combat: the retry still saves, so the keys survive a relaunch.
do
    boot(); ready(); save(); alt()
    L.Load(entry, L.Plan(entry))
    eq("persist: load saved SHIFT-2", G.savedKeys["SHIFT-2"], "ACTIONBUTTON2")
    local realSave = SaveBindings
    SaveBindings = function(set) WoW.game.combat = true; return realSave(set) end
    local rr = L.Restore(1, L.PlanRestore(1))
    SaveBindings = realSave
    check("persist: first restore stopped before saving", rr and rr.failed ~= nil, rr and tostring(rr.failed))
    G.combat = false
    local rp = L.PlanRestore(2)                  -- the load's backup is now ring #2
    check("persist: retry still saves the bindings", rp.resave == true)
    rr = L.Restore(2, rp)
    check("persist: retry ok", rr and not rr.failed, rr and tostring(rr.failed))
    WoW.relaunch(); ready()
    eq("persist: SHIFT-2 back after relaunch", G.keys["SHIFT-2"], "MOVEFORWARD")
end

-- An unreadable binding read never becomes "unbound": nothing is planned or written.
do
    boot(); ready(); save(); alt()
    local realGet = GetBindingAction
    GetBindingAction = function() error("read failed") end
    G.calls = {}
    local plan = L.Plan(entry)
    GetBindingAction = realGet
    check("unreadable key: plan blocked", (plan.blocked or ""):find("read the key bindings") ~= nil, tostring(plan.blocked))
    eq("unreadable key: wrote nothing", #G.calls, 0)
    local realKey = GetBindingKey
    GetBindingKey = function() error("read failed") end
    local m, err = L.Capture()
    GetBindingKey = realKey
    check("unreadable key: capture refused", m == nil and tostring(err):find("read the key bindings") ~= nil)
end

-- A cursor read that fails right after placing: treated as a failure, the
-- cursor is cleared, nothing reported as success.
do
    boot(); ready(); save(); alt({ actions = { [1] = { spell = 2052 } } })
    local plan = L.Plan(entry)
    local realPlace, realCursor = PlaceAction, GetCursorInfo
    local broken = false
    PlaceAction = function(slot) realPlace(slot); broken = true end
    GetCursorInfo = function(...) if broken then broken = false; error("read failed") end return realCursor(...) end
    local r = L.Load(entry, plan)
    PlaceAction, GetCursorInfo = realPlace, realCursor
    eq("unreadable cursor: stopped", r and r.failed, "cursor unreadable")
    eq("unreadable cursor: cursor cleared", G.cursor, nil)
    check("unreadable cursor: backup pinned", A.Backups.Operation() ~= nil)
end

-- A fully matching restore of the pinned operation gets "Done" and releases it.
do
    boot(); ready()
    local e = custom({ actions = { [9] = { kind = "macro", name = "Late", body = "/late", scope = "char" } },
                       macros = { Late = { body = "/late" } } })
    alt()
    G.combatAfter = 1                                 -- combat right after CreateMacro
    local r = L.Load(e, L.Plan(e))
    G.combat = false
    eq("op done: stopped after the macro", r and r.failed, "combat")
    A.Commands.restore("op")
    eq("op done: preview offers Done", A._shown and A._shown.confirm, "Done")
    A._shown.onConfirm()
    eq("op done: released", A.Backups.Operation(), nil)
end

-- A partial restore of the pinned operation keeps it pinned.
do
    boot(); ready(); save(); alt({ actions = { [1] = { spell = 2050 } } })
    local plan = L.Plan(entry)
    G.combatAfter = 6
    L.Load(entry, plan)
    G.combat = false
    for _, sp in ipairs(G.spells) do if sp.id == 2050 then sp.known = false end end
    local rp = L.PlanRestore("op")
    check("partial op: something unavailable", #rp.unavailable > 0)
    local rr = L.Restore("op", rp)
    check("partial op: reported partial", rr and rr.partial == true)
    check("partial op: still pinned", A.Backups.Operation() ~= nil)
end

-- A load where everything was left alone says so instead of "already
-- matches"; one where the only differences stay empty says that (#46).
do
    boot(); ready()
    local e = custom({ actions = { [1] = { kind = "spell", id = 2060, name = "Greater Heal", policy = "highest", class = true } } })
    alt({ actions = { [1] = { flyout = 7 } } })
    WoW.chatLines = {}
    local p = L.Plan(e)
    A.Commands.Report("load", L.Load(e, p), nil, p)
    local said = table.concat(WoW.chat(), "\n")
    check("skipped only: honest message", said:find("Nothing applied") ~= nil, said)
    alt({ actions = {} })
    WoW.chatLines = {}
    p = L.Plan(e)
    A.Commands.Report("load", L.Load(e, p), nil, p)
    said = table.concat(WoW.chat(), "\n")
    check("waiting only: says it stays empty", said:find("1 slot stays empty", 1, true) ~= nil, said)
end

------------------------------------------------------------
-- Round-3 review cases
------------------------------------------------------------

-- A slot read that fails only while taking the backup: no backup, no writes.
do
    boot(); ready(); save(); alt({ actions = { [1] = { spell = 2052 } } })
    local plan = L.Plan(entry)
    local real = GetActionInfo
    local n = 0
    GetActionInfo = function(...) n = n + 1; return real(...) end
    L.Plan(entry)                            -- count the reads one plan takes
    local perPlan = n
    n = 0
    GetActionInfo = function(slot, ...)
        n = n + 1
        if n == perPlan + 1 then error("read failed") end   -- the first read after Load's re-plan
        return real(slot, ...)
    end
    G.calls = {}
    local r, err = L.Load(entry, plan)
    GetActionInfo = real
    check("snapshot read fails: refused", r == nil and tostring(err):find("backup") ~= nil, tostring(err))
    eq("snapshot read fails: zero writes", #G.calls, 0)
    eq("snapshot read fails: nothing pinned", A.Backups.Operation(), nil)
end

-- A macro read that throws while checking a macro pickup on the cursor:
-- caught, cursor cleared, interruption recorded, Load does not raise.
do
    boot(); ready()
    local e = custom({ actions = { [9] = { kind = "macro", name = "Zed", body = "/z", scope = "char" } },
                       macros = { Zed = { body = "/z" } } })
    alt()
    local plan = L.Plan(e)
    local realPick, realInfo = PickupMacro, GetMacroInfo
    local armed = false
    PickupMacro = function(i) realPick(i); armed = true end
    GetMacroInfo = function(...) if armed then armed = false; error("read failed") end return realInfo(...) end
    local ok, r = pcall(L.Load, e, plan)
    PickupMacro, GetMacroInfo = realPick, realInfo
    check("macro read throws: Load did not raise", ok, tostring(r))
    check("macro read throws: stopped", ok and r and r.failed ~= nil, ok and r and tostring(r.failed))
    eq("macro read throws: cursor cleared", G.cursor, nil)
    check("macro read throws: interruption recorded", A.char.interrupted ~= nil)
end

-- An unreadable macro list is never "no macros": nothing is created.
do
    boot(); ready(); save(); alt()
    local real = GetMacroInfo
    GetMacroInfo = function() error("read failed") end
    local plan = L.Plan(entry)
    GetMacroInfo = real
    eq("macros unreadable: nothing to create", #plan.creates, 0)
    local why
    for _, sk in ipairs(plan.skips) do if sk.slot == 4 then why = sk.reason end end
    eq("macros unreadable: macro slot skipped", why, "macros unreadable")
end

-- GetBindingKey with a nil in the middle of its return tuple.
do
    boot(); ready()
    local real = GetBindingKey
    GetBindingKey = function() return nil, "Q", nil end
    local keys = A.Game.KeysFor("ACTIONBUTTON1")
    GetBindingKey = real
    eq("sparse keys: Q read", table.concat(keys, ","), "Q")
end

-- A matching restore of the pinned operation still says which macros it keeps.
do
    boot(); ready()
    local e = custom({ actions = { [9] = { kind = "macro", name = "Late", body = "/late", scope = "char" } },
                       macros = { Late = { body = "/late" } } })
    alt()
    G.combatAfter = 1
    L.Load(e, L.Plan(e))
    G.combat = false
    A.Commands.restore("op")
    check("kept on match: preview names the kept macro",
          table.concat(A._shown.lines, "\n"):find("Kept: 1 macro that load created") ~= nil, table.concat(A._shown.lines, " / "))
    WoW.chatLines = {}
    A._shown.onConfirm()
    check("kept on match: result says so too", table.concat(WoW.chat(), "\n"):find("Kept 1 macro") ~= nil,
          table.concat(WoW.chat(), " / "))
end

-- Combat after the first of two macro creations: the second CreateMacro is
-- never attempted (its own guard), and the backup stays pinned.
do
    boot(); ready()
    local e = custom({
        actions = { [9] = { kind = "macro", name = "One", body = "/one", scope = "char" },
                    [10] = { kind = "macro", name = "Two", body = "/two", scope = "char" } },
        macros = { One = { body = "/one" }, Two = { body = "/two" } } })
    alt()
    G.combatAfter = 1
    local r = L.Load(e, L.Plan(e))
    eq("two creates: stopped", r and r.failed, "combat")
    eq("two creates: only the first exists", #A.Game.MacrosNamed("One") .. "/" .. #A.Game.MacrosNamed("Two"), "1/0")
    eq("two creates: nothing protected attempted in combat", #G.blocked, 0)
    check("two creates: backup pinned", A.Backups.Operation() ~= nil)
    G.combat = false
end

-- An interrupted restore points to the backups list, not to "restore op".
do
    WoW.chatLines = {}
    A.Commands.Report("restore", { failed = "combat", at = "slot 1", changed = 0, keys = 0, created = 0 })
    local said = table.concat(WoW.chat(), "\n")
    check("restore stopped: points to backups", said:find("/altsync backups") ~= nil and not said:find("restore op"), said)
end

------------------------------------------------------------
-- PR #35 review cases (Codex + /code-review)
------------------------------------------------------------

-- An unrecognised restore argument never falls back to another backup;
-- the argument is case-insensitive.
do
    boot(); ready(); save(); alt()
    G.combatAfter = 6
    L.Load(entry, L.Plan(entry))
    G.combat, G.combatAfter = false, nil
    A.Backups.PushRing({ reason = "newest", actions = {}, keys = {}, createdMacros = {} })
    eq("restore arg: 'pinned' is no backup", A.Backups.Get("pinned"), nil)
    eq("restore arg: 'last' is no backup", A.Backups.Get("last"), nil)
    eq("restore arg: '1.5' is no backup", A.Backups.Get("1.5"), nil)
    check("restore arg: unknown -> blocked", L.PlanRestore("last").blocked == "No such backup.")
    A.Commands.restore("OP")
    eq("restore arg: OP means op", A._shown.title, "Restore backup op?")
    A._shown.onConfirm()
    eq("restore arg: OP released the pinned op", A.Backups.Operation(), nil)
end

-- Restoring the oldest backup with a full ring keeps it, so it can be retried.
do
    boot(); ready(); save(); alt()
    L.Load(entry, L.Plan(entry))
    for i = 1, A.Backups.RING - 1 do
        A.Backups.PushRing({ reason = "filler " .. i, actions = {}, keys = {}, createdMacros = {} })
    end
    local target = A.Backups.Get(A.Backups.RING)
    check("full ring: oldest is the load's backup", tostring(target and target.reason):find("^load") ~= nil)
    G.combatAfter = 1
    local rr = L.Restore(A.Backups.RING, L.PlanRestore(A.Backups.RING))
    G.combat, G.combatAfter = false, nil
    check("full ring: restore interrupted", rr and rr.failed ~= nil)
    eq("full ring: target still at the oldest position", A.Backups.Get(A.Backups.RING), target)
    rr = L.Restore(A.Backups.RING, L.PlanRestore(A.Backups.RING))
    check("full ring: retry ok", rr and not rr.failed, rr and tostring(rr.failed))
end

-- A failed rollback says so without pointing at "restore op"; a rollback is
-- read back (SetBinding signals failure by returning false).
do
    boot(); ready(); save(); alt()
    local before = G.keys["2"]
    local realSet = SetBinding
    local n = 0
    SetBinding = function(k, c)
        n = n + 1
        if n == 1 then return realSet(k, c) end
        return false                                   -- refused, nothing changed
    end
    local r = L.Load(entry, L.Plan(entry))
    SetBinding = realSet
    check("rollback refused: reported", r and tostring(r.failed):find("couldn't be put back") ~= nil, r and tostring(r.failed))
    check("rollback refused: no 'restore op' in the engine message", not tostring(r and r.failed):find("restore op"))
    check("rollback refused: still marked unsaved", A.char.bindingsUnsaved == true)
    local rp = L.PlanRestore("op")
    check("rollback refused: restore saves", rp.resave == true)
    local rr = L.Restore("op", rp)
    check("rollback refused: restored", rr and not rr.failed, rr and tostring(rr.failed))
    eq("rollback refused: key back", G.keys["2"], before)
    eq("rollback refused: no longer unsaved", A.char.bindingsUnsaved, nil)
end

-- SaveBindings fails: the in-memory keys are rolled back at once.
do
    boot(); ready(); save(); alt()
    local keysBefore = {}
    for k, c in pairs(G.keys) do keysBefore[k] = c end
    G.saveFails = true
    local r = L.Load(entry, L.Plan(entry))
    G.saveFails = false
    check("save fails: stopped", r and tostring(r.failed):find("not saved") ~= nil, r and tostring(r.failed))
    for k, c in pairs(keysBefore) do eq("save fails: " .. k .. " rolled back in memory", G.keys[k], c) end
    eq("save fails: rollback verified, nothing unsaved", A.char.bindingsUnsaved, nil)
end

-- Codex 2: keys set but not saved, then a confirmed new load of the same
-- setup: not a no-op; it saves, and the keys survive a relaunch.
do
    boot(); ready(); save(); alt()
    local realSave = SaveBindings
    SaveBindings = function() return false end            -- "saved" nothing
    local realSet = SetBinding
    L.Load(entry, L.Plan(entry))
    SaveBindings = realSave
    -- Simulate a rollback that couldn't run: put the loaded keys back in memory only.
    for k, c in pairs({ ["1"] = "ACTIONBUTTON1", ["2"] = "ACTIONBUTTON2", ["SHIFT-2"] = "ACTIONBUTTON2" }) do G.keys[k] = c end
    A.char.bindingsUnsaved = true
    local plan = L.Plan(entry)
    check("unsaved: not a no-op", not plan.noop)
    check("unsaved: resave planned", plan.resave == true)
    local r = L.Load(entry, plan, true)
    check("unsaved: load ok", r and not r.failed, r and tostring(r.failed))
    eq("unsaved: interrupted cleared", A.char.interrupted, nil)
    WoW.relaunch(); ready()
    eq("unsaved: keys survive a relaunch", G.keys["SHIFT-2"], "ACTIONBUTTON2")
end

-- Readiness: entering the world is not "quiet" before any data event.
do
    boot(); main()
    WoW.fire("PLAYER_ENTERING_WORLD", true, false)
    check("ready: not right after entering the world", (L.Blocked() or ""):find("still loading") ~= nil, L.Blocked())
    WoW.clock = WoW.clock + 3
    eq("ready: 2 s after entering with no events", L.Blocked(), nil)
end

-- Abandon: a backup read that fails leaves the old pin and record in place;
-- an abandoning no-op releases the pin and clears the record.
do
    boot(); ready(); save(); alt()
    G.combatAfter = 6
    L.Load(entry, L.Plan(entry))
    G.combat, G.combatAfter = false, nil
    local pinned = A.Backups.Operation()
    local plan = L.Plan(entry)
    local real = GetActionInfo
    local n, perPlan = 0, 0
    GetActionInfo = function(...) perPlan = perPlan + 1; return real(...) end
    L.Plan(entry)
    GetActionInfo = function(slot, ...)
        n = n + 1
        if n == perPlan + 1 then error("read failed") end
        return real(slot, ...)
    end
    local r, err = L.Load(entry, plan, true)
    GetActionInfo = real
    check("abandon: backup read failed -> refused", r == nil, tostring(err))
    eq("abandon: old pin kept", A.Backups.Operation(), pinned)
    check("abandon: interrupted kept", A.char.interrupted ~= nil)

    -- An abandoning load that turns out to be a no-op still releases the old
    -- pin and clears its record.
    boot(); ready(); save(); alt()
    L.Load(entry, L.Plan(entry))                       -- fully loaded
    A.Backups.Pin({ reason = "older", actions = {}, keys = {}, createdMacros = {} }, { kind = "load", name = "Older" })
    A.char.interrupted = { id = "x", version = "y", why = "combat" }
    plan = L.Plan(entry)
    check("abandon no-op: plan is a no-op", plan.noop)
    r = L.Load(entry, plan, true)
    check("abandon no-op: ok", r and r.noop)
    eq("abandon no-op: pin released", A.Backups.Operation(), nil)
    eq("abandon no-op: interrupted cleared", A.char.interrupted, nil)
end

-- Codex 1: the catalog entry changes between preview and confirmation.
do
    boot(); ready(); save(); alt()
    local plan = L.Plan(entry)
    local succ = A.Catalog.Copy(entry)
    succ.version, succ.ancestors = "beefbeefbeef:1", { entry.version }
    succ.modules.actions[1] = nil
    eq("stale entry: upsert fast-forwards", (A.Catalog.Upsert(succ, "Other-Realm")), "replace")
    G.calls = {}
    local r, err = L.Load(entry, plan)
    check("stale entry (replaced): refused", r == nil and tostring(err):find("changed") ~= nil, tostring(err))
    eq("stale entry (replaced): nothing written", #G.calls, 0)

    boot(); ready(); save(); alt()
    plan = L.Plan(entry)
    local tomb = { id = entry.id, kind = "loadout", class = entry.class, category = entry.category, name = entry.name,
                   version = "beefbeefbeef:2", ancestors = { entry.version }, deleted = true }
    eq("stale entry: tombstone upserted", (A.Catalog.Upsert(tomb, "Other-Realm")), "replace")
    G.calls = {}
    r, err = L.Load(entry, plan)
    check("stale entry (deleted): refused", r == nil and tostring(err):find("deleted") ~= nil, tostring(err))
    eq("stale entry (deleted): nothing written", #G.calls, 0)
end

-- Restoring the same backup twice: the second is a true no-op.
do
    boot(); ready(); save(); alt()
    L.Load(entry, L.Plan(entry))
    L.Restore(1, L.PlanRestore(1))
    local rp = L.PlanRestore(2)
    check("restore twice: no-op", rp.noop, A.Commands.Describe(rp)[1])
    eq("restore twice: no key listed", next(rp.keys), nil)
end

-- A command with no key in the entry leaves the destination's keys alone.
do
    boot(); ready()
    local e = custom({ bindings = { ACTIONBUTTON1 = { "1" }, ACTIONBUTTON7 = {} } })
    alt({ keys = { ["1"] = "ACTIONBUTTON1", ["7"] = "ACTIONBUTTON7" } })
    local plan = L.Plan(e)
    eq("no keys in entry: nothing planned", next(plan.keys), nil)
    L.Load(e, plan)
    eq("no keys in entry: 7 kept", G.keys["7"], "ACTIONBUTTON7")
end

-- A loadout with no keys at all still loads while Account bindings are active.
do
    boot(); ready()
    local e = custom({ actions = { [1] = { kind = "spell", id = 2061, name = "Flash Heal", policy = "highest" } },
                       bindings = { ACTIONBUTTON1 = {} } })
    alt({ bindingSet = 1, actions = {} })
    local plan = L.Plan(e)
    eq("no keys + account set: not blocked", plan.blocked, nil)
    local r = L.Load(e, plan)
    check("no keys + account set: loaded", r and r.changed == 1, r and tostring(r.failed))
end

-- Macro bodies: the server's trailing newline is dropped before creating; an
-- over-long body is skipped, never created.
do
    boot(); ready()
    local e = custom({ actions = { [9] = { kind = "macro", name = "Nl", body = "/nl\n", scope = "char" },
                                   [10] = { kind = "macro", name = "Long", body = string.rep("x", 255), scope = "char" } },
                       macros = { Nl = { body = "/nl\n" }, Long = { body = string.rep("x", 255) } } })
    alt()
    local plan = L.Plan(e)
    eq("macro body: one create", #plan.creates, 1)
    eq("macro body: newline dropped", plan.creates[1] and plan.creates[1].body, "/nl")
    local why
    for _, sk in ipairs(plan.skips) do if sk.slot == 10 then why = sk.reason end end
    eq("macro body: too long skipped", why, "macro too long")
    L.Load(e, plan)
    eq("macro body: Long not created", #A.Game.MacrosNamed("Long"), 0)
end

-- Low ranks come from the spellbook scan, not IsSpellKnown.
do
    boot(); ready(); save(); alt()
    local real = C_SpellBook.IsSpellKnown
    C_SpellBook.IsSpellKnown = function() return false end
    local plan = L.Plan(entry)
    C_SpellBook.IsSpellKnown = real
    local skipped2
    for _, sk in ipairs(plan.skips) do if sk.slot == 2 then skipped2 = sk.reason end end
    eq("downrank: not skipped when IsSpellKnown says no", skipped2, nil)
end

-- Reading never creates a backup record.
do
    boot(); ready(); save(); alt()
    A.Commands.backups()
    L.Plan(entry)
    L.PlanRestore("op")
    eq("read-only: no backup record", A.db.backups["Player-70-ALT"], nil)
end

-- Error codes are shown as sentences.
do
    boot(); ready(); save()
    WoW.chatLines = {}
    A.Commands.saveas("Everyday")
    local said = table.concat(WoW.chat(), "\n")
    check("copy: duplicate name explained", said:find("already has a loadout with that name") ~= nil, said)
end

-- Rename takes an id or a one-word name (rehearsal: "rename Sync2 SyncA").
do
    boot(); ready(); save()
    local e = A.Catalog.List("loadout", "PRIEST", "general")[1]
    A._shown = nil
    A.Commands.rename(e.name .. " Holiday")
    eq("rename by name: preview shown", A._shown and A._shown.confirm, "Rename")
    A._shown.onConfirm()
    eq("rename by name: renamed", A.Catalog.Get(e.id).name, "Holiday")
    A._shown = nil
    A.Commands.rename(e.id .. " By Id")
    A._shown.onConfirm()
    eq("rename by id: renamed", A.Catalog.Get(e.id).name, "By Id")
    WoW.chatLines = {}; A._shown = nil
    A.Commands.rename("Nope Other")
    eq("rename unknown: no preview", A._shown, nil)
    check("rename unknown: says so", table.concat(WoW.chat(), " "):find("No loadout named") ~= nil)
end

-- #39: Save As carries the Link addon's off note (Link stubbed: test_sync covers Link itself).
do
    boot(); ready(); save()
    WoW.chatLines = {}
    A.Link = { OffNote = function() return "Link is off: test" end }
    A.Commands.saveas("Noted")
    local said = table.concat(WoW.chat(), " ")
    check("saveas: off note after the result", (said:find("Link is off", 1, true) or 0) > (said:find("Saved", 1, true) or 1e9), said)
    A.Link = nil
    WoW.chatLines = {}
    A.Commands.saveas("Plain")
    said = table.concat(WoW.chat(), " ")
    check("saveas: no Link addon, no note", said:find("Saved", 1, true) and not said:find("Link is off", 1, true), said)
end

------------------------------------------------------------
-- Preserve intent on Save (#28): A07-A11, A35, A39 and the plan's cases
------------------------------------------------------------

-- A low alt that loaded "Everyday": slots 6/7 (unsupported wants) and 8
-- (Greater Heal, not learned; food stays) were skipped.
local function loadedAlt(opts)
    boot(); ready(); save(); alt(opts)
    local r = L.Load(entry, L.Plan(entry))
    assert(r and not r.failed, "loadedAlt: load failed")
    return A.char.loaded.loadout
end
local function rec() return A.char.loaded.loadout end
local function saveNow(drop)
    local m, err = L.PlanSave(drop)
    if not m then return nil, err end
    return L.Save(m)
end

do
    local r0 = loadedAlt()
    check("record: comparison taken after the load", r0.after ~= nil and r0.after.actions ~= nil)
    eq("record: unavailable from the skips", r0.unavailable[8], "not learned")
    check("record: unsupported wants unavailable too", r0.unavailable[6] ~= nil and r0.unavailable[7] ~= nil)
    local m = L.PlanSave()
    check("A08: nothing changed -> already saved", m and m.noop, m and "not noop")
    local calls = #G.calls

    -- A deliberate change in slot 10; everything else stays as loaded.
    G.actions[10] = { kind = "spell", id = 2052 }
    m = L.PlanSave()
    eq("change: one slot", m and #m.changed, 1)
    eq("change: kept the three unusable entries", m and #m.kept, 3)
    local r, mm = L.Save(m)
    check("save: written", r ~= nil, tostring(mm))
    local e = A.Catalog.Get(entry.id)
    eq("A08: future spell kept", e.modules.actions[8].name, "Greater Heal")
    eq("A08: not the food", e.modules.actions[8].kind, "spell")
    eq("A10: policy still highest", e.modules.actions[1].policy, "highest")
    eq("A10: the main's rank, not the alt's", e.modules.actions[1].id, 9472)
    eq("A11: exact downrank kept", e.modules.actions[2].policy, "exact")
    eq("change: slot 10 saved", e.modules.actions[10].id, 2052)
    eq("save: unsupported want kept", e.modules.actions[6].kind, "unsupported")
    eq("save: the character macro definition kept", e.modules.macros.Shield.body, "/cast Power Word: Shield")
    eq("save: wrote no game state", #G.calls, calls)
    eq("advance: record at the new version", rec().version, e.version)
    eq("advance: unavailable carried", rec().unavailable[8], "not learned")
    check("advance: second save is a no-op", L.PlanSave().noop)

    -- The skipped destination emptied (the food moved away): still kept. A
    -- load since #46 empties it itself; a record from before #46, or a slot
    -- left alone on a failed read, still holds the food in the comparison.
    G.actions[8] = { kind = "item", id = 4540 }
    rec().after.actions[8] = { kind = "item", id = 4540 }
    G.actions[8] = nil
    check("A07: emptied skipped slot -> still the spell", L.PlanSave().noop)
    -- Replaced deliberately with something supported: that is saved.
    G.actions[8] = { kind = "spell", id = 2052 }
    m = L.PlanSave()
    eq("replaced skipped slot: saved", m.modules.actions[8].id, 2052)
    G.actions[8] = { kind = "item", id = 4540 }

    -- A slot the load filled, cleared by the player: no longer covered.
    G.actions[3] = nil
    m = L.PlanSave()
    eq("cleared applied slot: not covered", m.modules.actions[3], nil)
    G.actions[3] = { kind = "item", id = 5512 }

    -- Keys: an unchanged key keeps B, a rebound key takes C.
    G.keys["3"] = "ACTIONBUTTON3"
    m = L.PlanSave()
    eq("keys: rebound saved", m.modules.bindings.ACTIONBUTTON3[1], "3")
    eq("keys: unchanged kept", table.concat(m.modules.bindings.ACTIONBUTTON2, ","), "2,SHIFT-2")
    G.keys["3"] = nil
end

-- r1-1/r3-1: an unreadable slot keeps B, and the comparison stays the old one.
do
    loadedAlt()
    G.actions[1] = { kind = "flyout", id = 2 }              -- reads as unsupported
    G.actions[10] = { kind = "spell", id = 2052 }
    local r = saveNow()
    check("unreadable: saved", r ~= nil)
    eq("unreadable: B kept", A.Catalog.Get(entry.id).modules.actions[1].id, 9472)
    eq("unreadable: old comparison kept", rec().after.actions[1].kind, "spell")
    G.actions[1] = { kind = "spell", id = 2061 }             -- readable again, as loaded
    check("unreadable then readable: still B (no-op)", L.PlanSave().noop)
end

-- Macros: an icon-only or body edit is a change; a clash is refused.
do
    loadedAlt()
    for _, mm in ipairs(G.char) do if mm.name == "Shield" then mm.icon = 999 end end
    local m = L.PlanSave()
    eq("macro icon edit: saved", m.modules.macros.Shield.icon, 999)
    for _, mm in ipairs(G.char) do if mm.name == "Shield" then mm.body = "/cast Renew" end end
    m = L.PlanSave()
    eq("macro body edit: saved", m.modules.macros.Shield.body, "/cast Renew")
    -- Pure merge: slot 1 keeps B's Heal, slot 2 takes C's different Heal.
    local mac = function(body) return { kind = "macro", name = "Heal", scope = "char", body = body } end
    local recM = { baseline = { cover = FULL, actions = { [1] = mac("/x"), [2] = mac("/x") }, macros = { Heal = { body = "/x" } } },
                   after = { cover = FULL, actions = { [1] = { kind = "item", id = 1 }, [2] = mac("/x") }, macros = { Heal = { body = "/x" } } },
                   unavailable = { [1] = "slot holds something this slice can't put back" } }
    local cur = { actions = { [1] = { kind = "item", id = 1 }, [2] = mac("/y") }, macros = { Heal = { body = "/y" } }, bindings = {} }
    local out, why = L.Merge(recM, cur, true)
    eq("macro clash: refused", out, nil)
    check("macro clash: says so", tostring(why):find("differs", 1, true) ~= nil, why)
    -- Pure merge: a key that would end up on two commands is refused.
    local recK = { baseline = { cover = FULL, actions = {}, bindings = { ACTIONBUTTON1 = { "Q" } } },
                   after = { cover = FULL, actions = {}, bindings = { ACTIONBUTTON1 = { "X" }, ACTIONBUTTON2 = { "Y" } } } }
    local curK = { actions = {}, bindings = { ACTIONBUTTON1 = { "X" }, ACTIONBUTTON2 = { "Q" } } }
    out, why = L.Merge(recK, curK, true)
    eq("key clash: refused", out, nil)
    -- Pure merge: a slot that was unreadable when the comparison was taken.
    -- Where the load skipped it, B is kept and A stays the comparison; where
    -- the load placed B, a readable C is what is there now.
    local recU = { baseline = { cover = FULL, actions = { [1] = { kind = "spell", id = 7, name = "X", policy = "highest" } } },
                   after = { cover = FULL, actions = { [1] = { kind = "unsupported", what = "unreadable" } } },
                   unavailable = { [1] = "not learned" } }
    local curU = { actions = { [1] = { kind = "spell", id = 8, name = "Y", policy = "highest" } }, bindings = {} }
    out = L.Merge(recU, curU, true)
    eq("unreadable at a skipped slot: B kept", out and out.modules.actions[1].id, 7)
    eq("unreadable at a skipped slot: A stays", out and out.advanced.actions[1].kind, "unsupported")
    recU.unavailable = {}
    out = L.Merge(recU, curU, true)
    eq("unreadable at a placed slot: C saved", out and out.modules.actions[1].id, 8)
    check("key clash: says so", tostring(why):find("bound twice", 1, true) ~= nil, why)
end

-- A39 and sync: a newer catalog version refuses Save; Save As forks what was loaded.
do
    loadedAlt()
    G.actions[10] = { kind = "spell", id = 2052 }
    local before = rec().version
    A.Catalog.Upsert({ id = entry.id, version = "ffffffffffff:1", parent = entry.version,
                       ancestors = { entry.version }, kind = "loadout", class = "PRIEST", category = "general",
                       name = "Everyday", modules = { actions = {}, cover = { { 1, 12 } } } }, "Other")
    eq("sync never touches the record", rec().version, before)
    local m, why = L.PlanSave()
    eq("A39: stale refused", m, nil)
    check("A39: says load again or Save As", tostring(why):find("changed since you loaded", 1, true) ~= nil, why)
    eq("A39: catalog untouched", A.Catalog.Get(entry.id).version, "ffffffffffff:1")
    A.Commands.saveas("Fork")
    local fork
    for _, e in ipairs(A.Catalog.List("loadout", "PRIEST", "general")) do if e.name == "Fork" then fork = e end end
    check("A09: fork made", fork ~= nil)
    eq("A09: fork keeps the future spell from the loaded baseline", fork and fork.modules.actions[8].name, "Greater Heal")
    eq("A09: and its policy", fork and fork.modules.actions[1].policy, "highest")
    eq("A09: the record moves to the fork", rec().id, fork and fork.id)
end

-- A35: a module this build doesn't capture survives Save.
do
    boot(); ready()
    local mods = A.Catalog.Copy(captured); mods.addons = { Bartender = { x = 1 } }
    entry = A.Catalog.Create("loadout", { class = "PRIEST", category = "general", name = "WithAddon" }, mods)
    alt()
    L.Load(entry, L.Plan(entry))
    G.actions[10] = { kind = "spell", id = 2052 }
    check("A35: saved", saveNow() ~= nil)
    eq("A35: payload kept", A.Catalog.Get(entry.id).modules.addons.Bartender.x, 1)
end

-- save drop: the unusable entries stop being covered; works after a Save too.
do
    loadedAlt()
    G.actions[10] = { kind = "spell", id = 2052 }
    check("drop: first a normal save", saveNow() ~= nil)
    G.actions[11] = { kind = "spell", id = 2052 }
    local m = L.PlanSave(true)
    eq("drop: lists the three", #m.dropped, 3)
    check("drop: saved", L.Save(m) ~= nil)
    local e = A.Catalog.Get(entry.id)
    eq("drop: slot 8 not covered", e.modules.actions[8], nil)
    eq("drop: applied slots stay", e.modules.actions[1].id, 9472)
    eq("drop: nothing unavailable now", next(rec().unavailable), nil)
end

-- Binding sets.
do
    -- (a) A Character comparison survives a Save made under Account bindings.
    loadedAlt()
    G.bindingSet = 1
    G.keys["4"] = "ACTIONBUTTON4"                           -- an Account-set key (one key table in the stub)
    G.actions[10] = { kind = "spell", id = 2052 }
    local m = L.PlanSave()
    eq("account: the Account key not taken", m.modules.bindings.ACTIONBUTTON4 and #m.modules.bindings.ACTIONBUTTON4, 0)
    check("account: keys not saved, said so", m.notes[1] and m.notes[1]:find("Account", 1, true) ~= nil)
    check("account: saved", L.Save(m) ~= nil)
    check("account: comparison kept", rec().after.bindings ~= nil)
    G.bindingSet = 2
    G.keys["3"] = "ACTIONBUTTON3"
    check("account -> character: key saved", saveNow() ~= nil)
    eq("account -> character: key in the entry", A.Catalog.Get(entry.id).modules.bindings.ACTIONBUTTON3[1], "3")
    -- A load under Account bindings records no key comparison (an entry with
    -- no keys loads there).
    boot(); ready()
    local nokeys = A.Catalog.Copy(captured); nokeys.bindings = {}
    entry = A.Catalog.Create("loadout", { class = "PRIEST", category = "general", name = "NoKeys" }, nokeys)
    alt({ bindingSet = 1 })
    local lr = L.Load(entry, L.Plan(entry))
    check("account load: completed", lr and not lr.failed, lr and tostring(lr.failed))
    eq("account load: no key comparison", rec().after and rec().after.bindings, nil)
    -- (b) Never had a Character comparison: keys kept, said so; never set by a Save.
    boot(); ready(); main()
    G.bindingSet = 1
    A.Commands.saveas("Fresh")
    eq("fresh under account: no key comparison", rec().after.bindings, nil)
    G.bindingSet = 2
    G.keys["9"] = "ACTIONBUTTON9"
    m = L.PlanSave()
    check("no comparison: no-op", m and m.noop)
    check("no comparison: says to load first", m.notes[1] and m.notes[1]:find("load this loadout", 1, true) ~= nil)
    G.actions[11] = { kind = "spell", id = 9472 }
    check("no comparison: an action save works", saveNow() ~= nil)
    eq("no comparison: still none after a Save", rec().after.bindings, nil)
    eq("no comparison: key not saved", #(A.Catalog.Get(rec().id).modules.bindings.ACTIONBUTTON9 or {}), 0)
end

-- No usable comparison: a failed load, a failed post-load capture, an old record.
do
    boot(); ready(); save(); alt()
    G.combatAfter = 1
    local r = L.Load(entry, L.Plan(entry))
    G.combat, G.combatAfter = false, nil
    check("failed load: failed", r and r.failed)
    eq("failed load: no comparison", rec().after, nil)
    local m, why = L.PlanSave()
    check("failed load: Save refused", m == nil and tostring(why):find("No usable comparison", 1, true) ~= nil, why)
    local n = #A.Catalog.List("loadout", "PRIEST", "general")
    A._shown = nil
    A.Commands.saveas("Alt copy")
    check("failed load: Save As warns", A._shown and A._shown.lines[2]:find("may leave out", 1, true) ~= nil)
    eq("failed load: nothing saved before confirming", #A.Catalog.List("loadout", "PRIEST", "general"), n)
    A._shown.onConfirm()
    eq("failed load: saved on confirm", #A.Catalog.List("loadout", "PRIEST", "general"), n + 1)

    boot(); ready(); save(); alt()
    local cap = L.Capture
    L.Capture = function() return nil, "x" end
    L.Load(entry, L.Plan(entry))
    L.Capture = cap
    eq("capture failed after load: no comparison", rec().after, nil)
    check("capture failed after load: Save refused", L.PlanSave() == nil)

    loadedAlt()
    rec().after = nil                                       -- what an older build leaves
    check("old record: Save refused", L.PlanSave() == nil)
    A._shown = nil
    A.Commands.saveas("Old copy")
    check("old record: Save As warns", A._shown ~= nil)
end

-- Code review on #41.
do
    -- Slots, commands and macros outside this build's set survive a Save.
    local far = { kind = "macro", name = "Far", scope = "char", body = "/x" }
    local recF = { baseline = { cover = FULL, actions = { [1] = { kind = "spell", id = 7 }, [130] = far },
                                macros = { Far = { body = "/x", icon = 1 } },
                                bindings = { ACTIONBUTTON1 = { "1" }, MULTIACTIONBAR1BUTTON1 = { "F" } } },
                   after = { cover = FULL, actions = { [1] = { kind = "spell", id = 7 } }, bindings = { ACTIONBUTTON1 = { "1" } } } }
    local curF = { actions = { [1] = { kind = "spell", id = 9 } }, macros = {}, bindings = { ACTIONBUTTON1 = { "1" } } }
    local out = L.Merge(recF, curF, true)
    -- #5: a slot with no comparison whose character macro changed only its
    -- icon is kept from B, and the Save says it isn't saved.
    local mac = { kind = "macro", name = "Far", scope = "char", body = "/x" }
    local recS = { baseline = { cover = FULL, actions = { [30] = mac }, macros = { Far = { body = "/x", icon = 1 } } },
                   after = { cover = { { 1, 12 } }, actions = {} } }
    local outS = L.Merge(recS, { actions = { [30] = mac }, macros = { Far = { body = "/x", icon = 2 } }, bindings = {} }, true)
    eq("#5 stale icon: B kept", outS and outS.modules.macros.Far.icon, 1)
    check("#5 stale icon: noted", outS and outS.notes[1] and outS.notes[1]:find("1 slot differs", 1, true) ~= nil, outS and outS.notes[1])
    eq("outside slots: slot 130 kept", out and out.modules.actions[130] and out.modules.actions[130].name, "Far")
    eq("outside slots: its macro kept", out and out.modules.macros.Far and out.modules.macros.Far.body, "/x")
    eq("outside commands: kept", out and out.modules.bindings.MULTIACTIONBAR1BUTTON1[1], "F")
    eq("outside commands: in-range change still saved", out and out.modules.actions[1].id, 9)
    -- An entry without some modules is still a noop when nothing changed.
    local full = { { 1, 120 }, { 145, 180 } }
    local recN = { baseline = { actions = { [1] = { kind = "spell", id = 7 } }, cover = full },
                   after = { actions = { [1] = { kind = "spell", id = 7 } }, cover = full } }
    out = L.Merge(recN, { actions = { [1] = { kind = "spell", id = 7 } }, macros = {}, bindings = { ACTIONBUTTON1 = {} } }, true)
    check("missing modules: noop", out and out.noop)

    -- An icon-only macro edit is listed as a changed slot.
    loadedAlt()
    for _, mm in ipairs(G.char) do if mm.name == "Shield" then mm.icon = 999 end end
    local m = L.PlanSave()
    eq("icon edit: one slot listed", m and #m.changed, 1)

    -- A restore since the load removes the comparison.
    loadedAlt()
    L.Restore(1, L.PlanRestore(1))
    local m2, why = L.PlanSave()
    check("restore: Save refused", m2 == nil and tostring(why):find("No usable comparison", 1, true) ~= nil, why)

    -- Save As falls back to a warned plain capture when the merge refuses.
    loadedAlt()
    local merge = L.Merge
    L.Merge = function() return nil, "Macro clash here." end
    A._shown = nil
    A.Commands.saveas("Clash")
    eq("saveas clash: warns with the reason", A._shown and A._shown.lines[1], "Macro clash here.")
    A._shown.onConfirm()
    L.Merge = merge
    local made
    for _, e in ipairs(A.Catalog.List("loadout", "PRIEST", "general")) do if e.name == "Clash" then made = e end end
    check("saveas clash: saved on confirm", made ~= nil)

    -- Save As plans once.
    loadedAlt()
    local cap, n = L.Capture, 0
    L.Capture = function(...) n = n + 1 return cap(...) end
    A.Commands.saveas("Once")
    L.Capture = cap
    eq("saveas: one capture", n, 1)

    -- The preview lists the changed keys; a dropped slot is listed once.
    loadedAlt()
    eq("load record: result kept", rec().result ~= nil, true)
    G.keys["3"] = "ACTIONBUTTON3"
    A._shown = nil
    A.Commands.save("drop")
    local text = table.concat(A._shown.lines, "\n")
    check("preview: key listed", text:find("ACTIONBUTTON3: 3", 1, true) ~= nil, text)
    local _, n8 = text:gsub("button 8:", "")
    eq("preview: dropped slot listed once", n8, 1)
    G.keys["3"] = nil
end

-- Codex on #41 at 094882a.
do
    -- A frozen slot keeps its own macro icon comparison when another slot
    -- using the same macro advances.
    local M = { kind = "macro", name = "M", scope = "char", body = "/m" }
    local fut = { kind = "spell", id = 7, name = "Future", policy = "highest" }
    local rec1 = { baseline = { cover = FULL, actions = { [1] = fut, [2] = M }, macros = { M = { body = "/m", icon = 1 } } },
                   after = { cover = FULL, actions = { [1] = M, [2] = M }, macros = { M = { body = "/m", icon = 1 } } },
                   unavailable = { [1] = "not learned" } }
    local cur1 = { actions = { [1] = { kind = "unsupported", what = "unreadable" }, [2] = M },
                   macros = { M = { body = "/m", icon = 2 } }, bindings = {} }
    local o1 = L.Merge(rec1, cur1, true)
    eq("frozen icon: slot 1 kept", o1 and o1.modules.actions[1].name, "Future")
    eq("frozen icon: slot 2 icon saved", o1 and o1.modules.macros.M.icon, 2)
    local rec2 = { baseline = o1.modules, after = o1.advanced, unavailable = o1.unavailable }
    local cur2 = { actions = { [1] = M, [2] = M }, macros = { M = { body = "/m", icon = 2 } }, bindings = {} }
    local o2 = L.Merge(rec2, cur2, true)
    eq("frozen icon: slot 1's edit compared with its own icon", o2 and o2.modules.actions[1].kind, "macro")

    -- The confirm refuses when the comparison it would commit changed, even
    -- if the saved modules didn't.
    loadedAlt()
    -- A record from before #46: the load left the food in the skipped slot.
    G.actions[8] = { kind = "item", id = 4540 }
    rec().after.actions[8] = { kind = "item", id = 4540 }
    G.actions[10] = { kind = "spell", id = 2052 }
    local m = L.PlanSave()
    local v = A.Catalog.Get(entry.id).version
    G.actions[8] = nil                                      -- the food leaves the skipped slot
    local r, why = L.Save(m)
    eq("frozen comparison: refused", r, nil)
    check("frozen comparison: says so", tostring(why):find("changed since the preview", 1, true) ~= nil, why)
    eq("frozen comparison: catalog untouched", A.Catalog.Get(entry.id).version, v)
end

-- #42: rank policy. Caster bars keep an old rank after training; hunter
-- bars switch to the new one; healers keep a ladder of ranks on purpose.
do
    boot(); main(); ready()
    G.actions[2], G.actions[12] = nil, nil
    G.actions[10] = { kind = "spell", id = 2050 }           -- Lesser Heal r1 alone, r2 known: stale
    local m = L.Capture()
    eq("#42: a lone low rank -> highest", m.actions[10].policy, "highest")
    G.actions[11] = { kind = "spell", id = 2050 }           -- the same rank twice is no ladder
    m = L.Capture()
    eq("#42: one rank twice -> highest", m.actions[11].policy, "highest")
    G.actions[11] = { kind = "spell", id = 2052 }
    m = L.Capture()
    eq("#42: ladder low rank -> exact", m.actions[10].policy, "exact")
    eq("#42: ladder high rank -> highest", m.actions[11].policy, "highest")
    G.actions[10], G.actions[11] = { kind = "spell", id = 2052 }, { kind = "spell", id = 2050 }
    m = L.Capture()
    eq("#42: rank order, not slot order: high", m.actions[10].policy, "highest")
    eq("#42: rank order, not slot order: low", m.actions[11].policy, "exact")

    -- The alt trains Flash Heal r2 after loading.
    local function train()
        G.spells[1].low = true
        G.spells[#G.spells + 1] = { id = 9473, name = "Flash Heal" }    -- not the main's id
    end
    loadedAlt()
    train()
    G.actions[1] = { kind = "spell", id = 9473 }            -- a hunter-style bar update
    m = L.PlanSave()
    check("#42: auto-updated rank is no change", m and m.noop, m and #m.changed)
    G.actions[1] = { kind = "spell", id = 2061 }            -- a caster bar: the old rank stays
    m = L.PlanSave()
    check("#42: stale rank is no change", m and m.noop, m and #m.changed)
    -- r1 untouched in slot 1, r2 dragged into slot 11: slot 1 now reads as
    -- a ladder's downrank, but a caster's stale rank looks the same, so the
    -- untouched slot keeps the loaded policy (never freeze a low rank).
    G.actions[11] = { kind = "spell", id = 9473 }
    m = L.PlanSave()
    eq("#42: untouched rank keeps the loaded policy", m and m.modules.actions[1].policy, "highest")
    eq("#42: and the main's rank", m and m.modules.actions[1].id, 9472)

    -- A rung removed: the untouched downrank stays exact.
    loadedAlt()
    eq("#42: ladder loaded", rec().after.actions[2].policy, "exact")
    G.actions[12] = nil
    m = L.PlanSave()
    eq("#42: rung removed, the downrank stays exact", m and m.modules.actions[2].policy, "exact")
    -- A record taken by the old rule (a lone low rank as exact) reads the same.
    loadedAlt()
    G.actions[12] = nil
    rec().after.actions[12] = nil
    rec().after.actions[2].policy = "exact"
    m = L.PlanSave()
    eq("#42: old-rule record: nothing listed", m and #m.changed, 0)
    eq("#42: old-rule record: policy as loaded", m and m.modules.actions[2].policy, "exact")

    -- The low-rank flag wins over book order.
    boot(); ready()
    G.setup{ class = "PRIEST", guid = "Player-70-ODD",
             spells = { { id = 2052, name = "Lesser Heal" }, { id = 2050, name = "Lesser Heal", low = true } },
             actions = { [1] = { spell = 2050 }, [2] = { spell = 2052 } } }
    m = L.Capture()
    eq("#42: flag over order: the low rank", m.actions[1].policy, "exact")
    eq("#42: flag over order: the top rank", m.actions[2].policy, "highest")
    -- Two low ranks (r3 known): book order says which is the ladder's top.
    boot(); ready()
    G.setup{ class = "PRIEST", guid = "Player-70-THREE",
             spells = { { id = 1, name = "Heal", low = true }, { id = 2, name = "Heal", low = true }, { id = 3, name = "Heal" } },
             actions = { [1] = { spell = 2 }, [2] = { spell = 1 } } }
    m = L.Capture()
    eq("#42: two low ranks: the higher one", m.actions[1].policy, "highest")
    eq("#42: two low ranks: the lower one", m.actions[2].policy, "exact")

    -- A rung changed to another rank of the same spell is an edit.
    loadedAlt()
    G.actions[10] = { kind = "spell", id = 2052 }           -- r2 into a new slot
    G.actions[12] = { kind = "spell", id = 2050 }           -- slot 12's r2 becomes r1: a downrank
    m = L.PlanSave()
    eq("#42: rung edit saved", m and m.modules.actions[12].id, 2050)
    eq("#42: rung edit exact", m and m.modules.actions[12].policy, "exact")

    -- An entry's lone exact rank (the old rule made these), loaded: the
    -- post-load capture reads it as highest. Changing its rank is an edit,
    -- for Save and Save As.
    boot(); ready(); main()
    entry = custom({ actions = { [9] = { kind = "spell", id = 2050, name = "Lesser Heal", policy = "exact" } } })
    alt()
    local lr = L.Load(entry, L.Plan(entry))
    check("#42: lone exact loaded", lr and not lr.failed)
    eq("#42: post-load reads highest", rec().after.actions[9].policy, "highest")
    G.actions[9] = { kind = "spell", id = 2052 }
    m = L.PlanSave()
    eq("#42: exact rank edited: saved", m and m.modules.actions[9].id, 2052)
    eq("#42: exact rank edited: its policy", m and m.modules.actions[9].policy, "highest")
    local p = L.PlanSaveAs()
    eq("#42: exact rank edited: Save As too", p and p.modules.actions[9].id, 2052)

    -- The documented way to record a rung built on an alt: the lower rank
    -- in a slot that held something else after the load.
    loadedAlt()
    train()
    G.actions[11] = { kind = "spell", id = 9473 }           -- r2 into slot 11
    G.actions[10] = { kind = "spell", id = 2061 }           -- r1 into slot 10, which was empty
    m = L.PlanSave()
    eq("#42: rung via a changed slot: exact", m and m.modules.actions[10].policy, "exact")
end

-- #5: every bar (measured on 70291: 1-120 and 145-180).
local function R(c)
    local t = {}
    for _, r in ipairs(c or {}) do t[#t + 1] = r[1] .. "-" .. r[2] end
    return table.concat(t, ",")
end
do
    -- Capture covers the measured slots and nothing else.
    boot(); ready(); main()
    G.actions[30] = { kind = "item", id = 5512 }            -- Action Bar 4
    G.actions[80] = { kind = "spell", id = 9472 }           -- a stance/form page
    G.actions[150] = { kind = "item", id = 5512 }           -- Action Bar 6
    G.actions[130] = { kind = "item", id = 5512 }           -- skyriding/possess page: excluded
    G.actions[185] = { kind = "item", id = 5512 }           -- above 180: excluded
    local m = L.Capture()
    eq("#5: cover", R(m.cover), "1-120,145-180")
    check("#5: other bars captured", m.actions[30] and m.actions[80] and m.actions[150])
    check("#5: excluded slots not captured", m.actions[130] == nil and m.actions[185] == nil)
    eq("#5: labels", table.concat({ A.Game.SlotLabel(80) }, " "), "Stance/form page 1 8")
    eq("#5: labels, bar 2", table.concat({ A.Game.SlotLabel(61) }, " "), "Action Bar 2 1")

    -- Load across bars; excluded slots are never written; restore is exact.
    entry = A.Catalog.Create("loadout", { class = "PRIEST", category = "general", name = "Bars" }, m)
    alt()
    G.actions[130] = { kind = "item", id = 4540 }
    G.actions[185] = { kind = "item", id = 4540 }
    local before = state()
    local r = L.Load(entry, L.Plan(entry))
    check("#5: loaded", r and not r.failed, r and tostring(r.failed))
    eq("#5: bar 4 written", G.actions[30] and G.actions[30].id, 5512)
    eq("#5: form page written (the alt's top Flash Heal)", G.actions[80] and G.actions[80].id, 2061)
    eq("#5: bar 6 written", G.actions[150] and G.actions[150].id, 5512)
    eq("#5: excluded 130 untouched", G.actions[130].id, 4540)
    eq("#5: excluded 185 untouched", G.actions[185].id, 4540)
    L.Restore(1, L.PlanRestore(1))
    eq("#5: restored exactly across bars", state(), before)

    -- A backup slot outside the set is reported, never written, and doesn't
    -- keep the restore "partial" forever.
    A.Backups.Get(1).actions[130] = false
    local rp = L.PlanRestore(1)
    local why
    for _, u in ipairs(rp.skips) do if u.slot == 130 then why = u.reason end end
    eq("#5: restore outside the set: reported", why, "not supported on this build")
    eq("#5: restore outside the set: not unavailable", #rp.unavailable, 0)
    local rr = L.Restore(1, rp)
    eq("#5: restore outside the set: untouched", G.actions[130].id, 4540)
    check("#5: restore outside the set: not partial", rr and not rr.partial)

    -- Load lists an entry's slots outside the set instead of ignoring them.
    local wide = A.Catalog.Copy(entry)
    wide.modules.actions[130] = { kind = "item", id = 5512 }
    local lp = L.Plan(wide)
    why = nil
    for _, s in ipairs(lp.skips) do if s.slot == 130 then why = s.reason end end
    eq("#5: load outside the set: listed", why, "not supported on this build")
    for _, op in ipairs(lp.actions) do check("#5: load outside the set: never written", op.slot ~= 130) end

    -- An entry without a valid cover can't be loaded: Save could never use
    -- the record ("load it again" would loop).
    local bare = A.Catalog.Copy(entry)
    bare.modules.cover = nil
    local bp = L.Plan(bare)
    check("#5: no cover: load refused", bp.blocked and bp.blocked:find("damaged", 1, true) ~= nil, bp.blocked)

    -- A rank ladder split across two bars (#42).
    boot(); ready(); main()
    G.actions[12] = nil
    G.actions[40] = { kind = "spell", id = 2052 }
    m = L.Capture()
    eq("#5: ladder across bars: low", m.actions[2].policy, "exact")
    eq("#5: ladder across bars: high", m.actions[40].policy, "highest")
    -- Pages that take turns on Action Bar 1 never ladder with each other: a
    -- warrior's stale rank under the stance page stays "highest".
    G.actions[40] = nil
    G.actions[73] = { kind = "spell", id = 2052 }
    m = L.Capture()
    eq("#5: rank under a stance page: not a ladder", m.actions[2].policy, "highest")
    G.actions[73], G.actions[20] = nil, { kind = "spell", id = 2052 }
    m = L.Capture()
    eq("#5: rank on the other page: not a ladder", m.actions[2].policy, "highest")
    -- A bar beside a stance page is on screen with it: that is a ladder.
    G.actions[20] = nil
    G.actions[73], G.actions[40] = { kind = "spell", id = 2050 }, { kind = "spell", id = 2052 }
    m = L.Capture()
    eq("#5: stance page beside a bar: ladder low", m.actions[73].policy, "exact")
    eq("#5: stance page beside a bar: ladder high", m.actions[40].policy, "highest")
end

-- #5: an entry captured by a 1-12 build. Save adds the other bars once,
-- then is a no-op; Save As does the same.
do
    boot(); ready(); main()
    local old = L.Capture()
    for slot in pairs(old.actions) do if slot > 12 then old.actions[slot] = nil end end
    old.cover = { { 1, 12 } }
    entry = A.Catalog.Create("loadout", { class = "PRIEST", category = "general", name = "Old" }, old)
    alt()
    G.actions[40] = { kind = "item", id = 4540 }            -- the alt's own bar 5
    L.Load(entry, L.Plan(entry))
    local m = L.PlanSave()
    check("#5 old entry: not a no-op", m and not m.noop)
    eq("#5 old entry: slots added", m and m.added, #A.Game.SLOT_LIST - 12)
    eq("#5 old entry: with an action", m and m.addedFull, 1)
    A._shown = nil
    A.Commands.save()
    check("#5 old entry: preview says so", A._shown and table.concat(A._shown.lines, "\n"):find("didn't cover yet (1 with an action, counted above)", 1, true) ~= nil)
    check("#5 old entry: grouped under the bar", A._shown and table.concat(A._shown.lines, "\n"):find("  Action Bar 5 (1):\n    button 4: empty -> item 4540", 1, true) ~= nil,
          A._shown and table.concat(A._shown.lines, " | "))
    local p = L.PlanSaveAs()
    eq("#5 old entry: Save As covers every bar", p and R(p.modules.cover), "1-120,145-180")
    eq("#5 old entry: Save As takes bar 5", p and p.modules.actions[40] and p.modules.actions[40].id, 4540)
    A._shown = nil
    A.Commands.saveas("Widened")
    check("#5 old entry: Save As says it adds bars first", A._shown and A._shown.lines[1]:find("Adds", 1, true) ~= nil)
    -- The confirm saves what was shown or nothing: a merge that refuses by
    -- then (a new clash) must not turn into a plain capture.
    local merge = L.Merge
    L.Merge = function() return nil, "Macro clash here." end
    WoW.chatLines = {}
    A._shown.onConfirm()
    L.Merge = merge
    local widened
    for _, x in ipairs(A.Catalog.List("loadout", "PRIEST", "general")) do if x.name == "Widened" then widened = x end end
    eq("#5 widening confirm: changed plan refused", widened, nil)
    check("#5 widening confirm: says so", table.concat(WoW.chat(), " "):find("changed since the preview", 1, true) ~= nil)
    check("#5 old entry: saved", L.Save(m) ~= nil)
    local e = A.Catalog.Get(entry.id)
    eq("#5 old entry: cover now every bar", R(e.modules.cover), "1-120,145-180")
    eq("#5 old entry: bar 5 saved", e.modules.actions[40].id, 4540)
    check("#5 old entry: second Save is a no-op", L.PlanSave().noop)
end

-- #5: a comparison taken by a 1-12 build (A covers 1-12) never turns into
-- "observed": an inherited slot outside it is kept on every Save.
do
    boot(); ready(); main()
    G.actions[30] = { kind = "item", id = 5512 }
    entry = A.Catalog.Create("loadout", { class = "PRIEST", category = "general", name = "Wide" }, L.Capture())
    alt()
    L.Load(entry, L.Plan(entry))
    rec().after.cover = { { 1, 12 } }                       -- what the 1-12 build's load recorded
    for slot in pairs(rec().after.actions) do if slot > 12 then rec().after.actions[slot] = nil end end
    G.actions[30] = { kind = "item", id = 4540 }            -- different from the entry
    G.actions[10] = { kind = "spell", id = 2052 }           -- a real edit, so the Save happens
    local m = L.PlanSave()
    eq("#5 old comparison: inherited slot kept", m and m.modules.actions[30].id, 5512)
    check("#5 old comparison: says to load again", m and m.notes[1] and m.notes[1]:find("load it again to save", 1, true) ~= nil,
          m and m.notes[1])
    check("#5 old comparison: saved", L.Save(m) ~= nil)
    check("#5 old comparison: still not covered by the comparison", not A.Cover.Has(rec().after.cover, 30))
    m = L.PlanSave()
    eq("#5 old comparison: second Save keeps it", m and m.modules.actions[30].id, 5512)
end

-- #5: a newly covered slot that can't be read at the first Save stays
-- uncovered, is captured once it reads, and the next Save is a no-op.
local function unreadableThenReadable(viaSaveAs)
    boot(); ready(); main()
    local old = L.Capture()
    for slot in pairs(old.actions) do if slot > 12 then old.actions[slot] = nil end end
    old.cover = { { 1, 12 } }
    entry = A.Catalog.Create("loadout", { class = "PRIEST", category = "general", name = "Old2" }, old)
    alt()
    L.Load(entry, L.Plan(entry))
    G.actions[50] = { kind = "flyout", id = 2 }             -- unreadable at the first Save
    local tag = viaSaveAs and "#5 unreadable (Save As): " or "#5 unreadable: "
    if viaSaveAs then
        local p = L.PlanSaveAs()
        check(tag .. "forked", L.SaveAs(p, "Fork2") ~= nil)
    else
        check(tag .. "first Save", saveNow() ~= nil)
    end
    local e = A.Catalog.Get(rec().id)
    check(tag .. "not covered yet", not A.Cover.Has(e.modules.cover, 50))
    G.actions[50] = { kind = "item", id = 4540 }
    check(tag .. "second Save", saveNow() ~= nil)
    e = A.Catalog.Get(rec().id)
    eq(tag .. "captured", e.modules.actions[50] and e.modules.actions[50].id, 4540)
    check(tag .. "third Save is a no-op", L.PlanSave().noop)
end
unreadableThenReadable(false)
unreadableThenReadable(true)

-- #5: a record without a valid cover is never guessed at.
do
    loadedAlt()
    rec().baseline.cover = nil                              -- a hand edit
    local m, why = L.PlanSave()
    check("#5 damaged B: Save refused", m == nil and tostring(why):find("damaged", 1, true) ~= nil, why)
    A._shown = nil
    A.Commands.saveas("Fork3")
    check("#5 damaged B: Save As warns with the reason", A._shown and A._shown.lines[1]:find("damaged", 1, true) ~= nil)
    loadedAlt()
    rec().after.cover = { { 5, 1 } }
    m, why = L.PlanSave()
    check("#5 malformed A: Save refused", m == nil and tostring(why):find("damaged", 1, true) ~= nil, why)
end

-- Commands: the preview is frozen; no record means Save As; fresh Save As sets the record.
do
    boot(); ready(); main()
    A.Commands.save()
    check("no record: Save points to Save As", table.concat(WoW.chat(), " "):find("saveas", 1, true) ~= nil)
    A.Commands.saveas("Mine")
    eq("fresh Save As: record set", A.Catalog.Get(rec().id).name, "Mine")
    check("fresh Save As: comparison set", rec().after ~= nil)
    loadedAlt()
    G.actions[10] = { kind = "spell", id = 2052 }
    A._shown = nil
    A.Commands.save()
    check("save: previewed", A._shown and A._shown.confirm == "Save")
    check("save: preview lists the kept entries", table.concat(A._shown.lines, "\n"):find("Greater Heal (not learned)", 1, true) ~= nil)
    check("save: preview offers the drop", table.concat(A._shown.lines, "\n"):find("/altsync save drop", 1, true) ~= nil)
    local v = A.Catalog.Get(entry.id).version
    G.actions[11] = { kind = "spell", id = 2052 }          -- changed after the preview
    WoW.chatLines = {}
    A._shown.onConfirm()
    eq("frozen preview: refused", A.Catalog.Get(entry.id).version, v)
    check("frozen preview: says so", table.concat(WoW.chat(), " "):find("changed since the preview", 1, true) ~= nil)
    A.Commands.save()
    A._shown.onConfirm()
    check("save: confirmed", A.Catalog.Get(entry.id).version ~= v)
    A.Commands.save("nonsense")
    check("save: usage", table.concat(WoW.chat(), " "):find("Usage: /altsync save", 1, true) ~= nil)
end

------------------------------------------------------------
-- Preview text
------------------------------------------------------------
do
    boot(); ready(); save(); alt()
    local lines = table.concat(A.Commands.Describe(L.Plan(entry)), "\n")
    check("preview: counts", lines:find("Actions:") ~= nil and lines:find("Bindings") ~= nil)
    check("preview: skip reasons", lines:find("not learned") ~= nil)
    check("preview: displaced key shown", lines:find("SHIFT%-2: MOVEFORWARD %-> ACTIONBUTTON2") ~= nil, lines)
    -- (StaticPopup is checked by test_packaging's source scan of every shipped file.)
    -- A blocked load offers no confirm button (the old "and false or" bug showed "Done").
    G.combat = true
    A.Commands.load("Everyday")
    eq("preview: blocked -> no confirm", A._shown and A._shown.confirm, false)
    G.combat = false
    A.Commands.load("Everyday")
    eq("preview: changes -> Load", A._shown and A._shown.confirm, "Load")
end

------------------------------------------------------------
-- #46: Load makes the covered slots match the loadout. Placed where this
-- character can; emptied where the loadout is empty or holds what this
-- character verifiably can't use; everything else left alone.
------------------------------------------------------------
local GH = { kind = "spell", id = 2060, name = "Greater Heal", policy = "highest", class = true }
local FH = { kind = "spell", id = 2061, name = "Flash Heal", policy = "highest", class = true }
local function byReason(list)
    local t = {}
    for _, x in ipairs(list or {}) do t[x.slot] = x.reason or x.why or "op" end
    return t
end
local function ops(plan)
    local t = {}
    for _, op in ipairs(plan.actions) do t[op.slot] = op end
    return t
end
do
    -- The warlock case: the loadout's slot 3 holds a spell this character
    -- hasn't learned; the character has its own Flash Heal there, which the
    -- loadout puts on slot 40. One copy is left, and the bar matches.
    boot(); ready()
    local e = custom({ actions = { [3] = GH, [40] = FH } })
    alt({ actions = { [3] = { spell = 2061 }, [8] = { item = 4540 } } })
    local before = state()
    local plan = L.Plan(e)
    local o = ops(plan)
    eq("#46: unusable slot emptied", o[3] and o[3].target, nil)
    eq("#46: with the loadout's reason", o[3] and o[3].why, "not learned")
    eq("#46: loadout-empty slot in the cover emptied", o[8] and o[8].target == nil and o[8].why, nil)
    check("#46: loadout-empty slot op exists", o[8] ~= nil)
    eq("#46: not listed as left unchanged", byReason(plan.skips)[3], nil)
    local text = table.concat(A.Commands.Describe(plan), "\n")
    check("#46: preview names what goes and why", text:find("button 3: Flash Heal -> empty (Greater Heal: not learned)", 1, true) ~= nil, text)
    check("#46: preview footer", text:find("Backup first. Verify every write.", 1, true) ~= nil, text)
    WoW.chatLines = {}
    A.Commands.Report("load", L.Load(e, plan), nil, plan)
    local said = table.concat(WoW.chat(), "\n")
    check("#46: result counts the emptied slots", said:find("(2 emptied)", 1, true) ~= nil, said)
    eq("#46: slot 3 empty", G.actions[3], nil)
    eq("#46: Flash Heal only where the loadout has it", G.actions[40] and G.actions[40].id, 2061)
    eq("#46: food slot emptied", G.actions[8], nil)
    eq("#46: recorded as unavailable", rec().unavailable[3], "not learned")
    eq("#46: an emptied loadout-empty slot isn't unavailable", rec().unavailable[8], nil)
    -- Again: nothing to write, and it says what stays empty.
    local again = L.Plan(e)
    check("#46: second load is a no-op", again.noop)
    eq("#46: the slot waits", byReason(again.waiting)[3], "not learned")
    local atext = table.concat(A.Commands.Describe(again), "\n")
    check("#46: no-op preview lists the waiting slot", atext:find("Stays empty until this character can use it", 1, true) ~= nil, atext)
    WoW.chatLines = {}
    A.Commands.Report("load", L.Load(e, again), nil, again)
    said = table.concat(WoW.chat(), "\n")
    check("#46: no-op says it stays empty", said:find("Already matches the loadout; 1 slot stays empty", 1, true) ~= nil, said)
    -- Save keeps the inherited spell (A08) and is a no-op.
    local m = L.PlanSave()
    check("#46 A08: save is a no-op", m and m.noop, m and #m.changed)
    -- Restore puts back exactly what the load emptied.
    L.Restore(1, L.PlanRestore(1))
    eq("#46: restored exactly", state(), before)
end

do
    -- What isn't touched: a slot outside the cover (never captured), even
    -- with stray data; content the backup can't put back; a failed read.
    boot(); ready()
    local e = custom({ cover = { { 1, 12 } }, actions = { [3] = GH, [30] = FH } })
    alt({ actions = { [3] = { flyout = 7 }, [30] = { item = 4540 }, [5] = { item = 4540 } } })
    local plan = L.Plan(e)
    local o = ops(plan)
    eq("#46: outside the cover untouched", o[30], nil)
    eq("#46: outside the cover not listed", byReason(plan.skips)[30], nil)
    eq("#46: unrestorable content left", byReason(plan.skips)[3], "slot holds something this slice can't put back")
    check("#46: loadout-empty covered slot emptied", o[5] ~= nil and o[5].target == nil)
    L.Load(e, plan)
    eq("#46: slot 30 keeps its item", G.actions[30] and G.actions[30].id, 4540)
    eq("#46: the flyout stays", G.actions[3] and G.actions[3].kind, "flyout")
end

do
    -- Absence must be verified: a failed read never empties a slot.
    local function untouched(label, breakFn, restoreFn, want, reason)
        boot(); ready()
        local e = custom({ actions = { [3] = want } })
        alt({ actions = { [3] = { item = 4540 } } })
        breakFn()
        local plan = L.Plan(e)
        restoreFn()
        eq(label .. ": left alone", byReason(plan.skips)[3], reason)
        eq(label .. ": no op", ops(plan)[3], nil)
    end
    local realLow = C_SpellBook.IsSpellBookItemLowRank
    untouched("#46 spellbook rank read fails", function()
        C_SpellBook.IsSpellBookItemLowRank = function() error("read failed") end
    end, function() C_SpellBook.IsSpellBookItemLowRank = realLow end, GH, "spellbook unreadable")
    untouched("#46 rank read not a boolean", function()
        C_SpellBook.IsSpellBookItemLowRank = function() return nil end
    end, function() C_SpellBook.IsSpellBookItemLowRank = realLow end, GH, "spellbook unreadable")
    local realInfo = C_SpellBook.GetSpellBookItemInfo
    untouched("#46 spellbook item read fails", function()
        -- Only the wanted rank's item fails (a whole failed book blocks on readiness).
        C_SpellBook.GetSpellBookItemInfo = function(i, ...) if i == 3 then error("read failed") end return realInfo(i, ...) end
    end, function() C_SpellBook.GetSpellBookItemInfo = realInfo end,
        { kind = "spell", id = 2060, name = "Greater Heal", policy = "exact" }, "spellbook unreadable")
    local realCount = C_Item.GetItemCount
    untouched("#46 item count fails", function()
        C_Item.GetItemCount = function() error("read failed") end
    end, function() C_Item.GetItemCount = realCount end, { kind = "item", id = 9999 }, "items unreadable")
    local realNum = GetNumMacros
    untouched("#46 macro count invalid", function()
        GetNumMacros = function() return nil, 1 end
    end, function() GetNumMacros = realNum end,
        { kind = "macro", name = "Gone", scope = "account", body = "/x" }, "macros unreadable")
    local realMI = GetMacroInfo
    untouched("#46 counted macro without a name", function()
        GetMacroInfo = function(i) if i == 1 then return nil end return realMI(i) end
    end, function() GetMacroInfo = realMI end,
        { kind = "macro", name = "Gone", scope = "account", body = "/x" }, "macros unreadable")
    -- A failed rank read never makes a spell the top rank.
    boot(); ready(); alt()
    C_SpellBook.IsSpellBookItemLowRank = function() error("read failed") end
    local book = A.Game.Spellbook()
    C_SpellBook.IsSpellBookItemLowRank = realLow
    eq("#46: unverified rank is not a top rank", book.top["Lesser Heal"], nil)
    -- And a known "highest" spell with no verified top rank isn't placed at
    -- its stored (possibly lower) rank.
    boot(); ready()
    local eL = custom({ actions = { [3] = { kind = "spell", id = 2050, name = "Lesser Heal", policy = "highest" } } })
    alt({ actions = { [3] = { item = 4540 } } })
    C_SpellBook.IsSpellBookItemLowRank = function() error("read failed") end
    local pL = L.Plan(eL)
    C_SpellBook.IsSpellBookItemLowRank = realLow
    eq("#48 Codex: known id, unverified top: no op", ops(pL)[3], nil)
    eq("#48 Codex: left alone as unreadable", byReason(pL.skips)[3], "spellbook unreadable")
    boot(); ready(); alt()
    check("#46: but the spell is known", book.byId[2050] ~= nil)
    eq("#46: book marked incomplete", book.complete, false)
    boot(); ready(); alt()
    eq("#46: a clean book is complete", A.Game.Spellbook().complete, true)
    -- Entry limitations are left alone too.
    boot(); ready()
    local e = custom({ actions = { [3] = { kind = "macro", name = "NoDef", scope = "char", body = "/x" },
                                   [4] = { kind = "unsupported", what = "flyout" } } })
    alt({ actions = { [3] = { item = 4540 }, [4] = { item = 4540 } } })
    local plan = L.Plan(e)
    eq("#46: missing definition left alone", byReason(plan.skips)[3], "macro definition missing")
    eq("#46: unsupported entry left alone", byReason(plan.skips)[4], "not supported yet")
end

do
    -- Macro capacity: an unreadable count never creates, and creations
    -- reserved by earlier slots fill the last free slot.
    boot(); ready()
    local mk = function(n) return { kind = "macro", name = n, scope = "char", body = "/" .. n } end
    local e = custom({ actions = { [1] = mk("NewA"), [2] = mk("NewB"), [3] = mk("NewA") },
                       macros = { NewA = { body = "/NewA" }, NewB = { body = "/NewB" } } })
    local mac = { { name = "Acct", body = "/say hi" } }
    for i = 1, 29 do mac[#mac + 1] = { name = ("M%02d"):format(i), body = "/m" .. i, char = true } end
    alt({ macros = mac, actions = { [2] = { item = 4540 } } })
    local plan = L.Plan(e)
    eq("#46: one free macro slot: one create", #plan.creates, 1)
    eq("#46: the repeated macro reuses its creation", ops(plan)[3] and ops(plan)[3].target and ops(plan)[3].target.name, "NewA")
    eq("#46: no room left: emptied with the reason", ops(plan)[2] and ops(plan)[2].why, "macro slots full")
    -- The capacity read fails (here: only the first count read): nothing is
    -- created and the slot is left alone.
    alt({ actions = { [1] = { item = 4540 } } })
    local realNum, first = GetNumMacros, true
    GetNumMacros = function() if first then first = false; return nil end return realNum() end
    plan = L.Plan(e)
    GetNumMacros = realNum
    eq("#46: unreadable capacity: nothing created", #plan.creates, 0)
    eq("#46: unreadable capacity: left alone", byReason(plan.skips)[1], "macros unreadable")
end

do
    -- A mixed preview: emptied, waiting and left-alone slots each in their
    -- own place, the waiting ones never counted as changes.
    boot(); ready()
    local e = custom({ actions = { [3] = GH, [4] = GH, [5] = GH } })
    alt({ actions = { [3] = { item = 4540 }, [5] = { flyout = 7 } } })
    local plan = L.Plan(e)
    local text = table.concat(A.Commands.Describe(plan), "\n")
    check("#46 mixed: one change", text:find("Actions: 1 slot change.", 1, true) ~= nil, text)
    check("#46 mixed: waiting listed", text:find("Stays empty until this character can use it:\n  Action Bar 1 (1):\n    button 4: Greater Heal: not learned", 1, true) ~= nil, text)
    check("#46 mixed: left alone listed", text:find("button 5: left unchanged: slot holds", 1, true) ~= nil, text)
end

do
    -- Stale confirmation: a waiting slot's reason changes after the preview.
    boot(); ready()
    local e = custom({ actions = { [4] = { kind = "macro", name = "Shield", scope = "char", body = "/cast Power Word: Shield" } },
                       macros = { Shield = { body = "/cast Power Word: Shield" } } })
    local mac = { { name = "Acct", body = "/say hi" }, { name = "Shield", body = "/different", char = true } }
    for i = 1, 29 do mac[#mac + 1] = { name = ("M%02d"):format(i), body = "/m" .. i, char = true } end
    alt({ macros = mac, actions = {} })
    local plan = L.Plan(e)
    eq("#46 stale: waits on the conflict", byReason(plan.waiting)[4], "macro name conflict")
    for _, m in ipairs(G.char) do if m.name == "Shield" then m.name = "Zzz" end end
    G.sortMacros()
    eq("#46 stale: now waits on capacity", byReason(L.Plan(e).waiting)[4], "macro slots full")
    G.calls = {}
    local had = A.char.loaded and A.char.loaded.loadout
    local r, err = L.Load(e, plan)
    check("#46 stale: refused", r == nil and tostring(err):find("changed", 1, true) ~= nil, tostring(err))
    eq("#46 stale: wrote nothing", #G.calls, 0)
    eq("#46 stale: record untouched", A.char.loaded and A.char.loaded.loadout, had)
end

do
    -- A gap the load kept for a spell this character can't use yet: the
    -- client drops a newly learned spell there, and Save must not take it
    -- over the loadout's (#46, owner: new spells go to the first empty slot).
    boot(); ready()
    local e = custom({ actions = { [3] = GH } })
    alt({ actions = {} })
    L.Load(e, L.Plan(e))
    local v0 = A.Catalog.Get(e.id).version
    G.actions[3] = { kind = "spell", id = 2061 }            -- "auto-placed"
    WoW.chatLines = {}
    A.Commands.save("")
    local said = table.concat(WoW.chat(), "\n")
    check("#48: only the gap differs: no changes to save", said:find("No changes to save", 1, true) ~= nil, said)
    check("#48: not 'matches this character'", said:find("matches this character", 1, true) == nil, said)
    check("#48: says what it left out", said:find("holds Flash Heal now: not saved (the loadout keeps Greater Heal there)", 1, true) ~= nil, said)
    eq("#48: catalog untouched", A.Catalog.Get(e.id).version, v0)
    -- Another real edit: saved, the gap still the loadout's, shown was -> now.
    G.actions[5] = { kind = "item", id = 4540 }
    A._shown = nil
    A.Commands.save("")
    local text = A._shown and table.concat(A._shown.lines, "\n") or ""
    check("#46: save preview shows was -> now", text:find("button 5: empty -> item 4540", 1, true) ~= nil, text)
    check("#48: preview lists the kept gap", text:find("holds Flash Heal now: not saved", 1, true) ~= nil, text)
    -- The gap's occupant changes after the preview: the confirm is refused.
    G.actions[3] = { kind = "item", id = 5512 }
    WoW.chatLines = {}
    A._shown.onConfirm()
    check("#48: changed gap occupant: refused", table.concat(WoW.chat(), " "):find("changed since the preview", 1, true) ~= nil)
    G.actions[3] = { kind = "spell", id = 2061 }
    A.Commands.save("")
    A._shown.onConfirm()
    eq("#48: edit saved", A.Catalog.Get(e.id).modules.actions[5].id, 4540)
    eq("#48: gap keeps the loadout's spell", A.Catalog.Get(e.id).modules.actions[3].id, 2060)
    check("#48: next Save is a no-op", L.PlanSave().noop)
    -- Save As keeps it too, and so does a Save on the new entry.
    WoW.chatLines = {}
    A.Commands.saveas("Fork")
    local fork
    for _, x in ipairs(A.Catalog.List("loadout", "PRIEST", "general")) do if x.name == "Fork" then fork = x end end
    eq("#48: Save As keeps the loadout's spell", fork and fork.modules.actions[3].id, 2060)
    check("#48: Save As says what it left out", table.concat(WoW.chat(), "\n"):find("holds Flash Heal now: not saved", 1, true) ~= nil)
    check("#48: Save after Save As: no-op", L.PlanSave().noop)
    -- A Load that still can't place it keeps the gap protected; one that
    -- can (the spell is learned) releases it, and an edit there is saved.
    L.Load(fork, L.Plan(fork))
    G.actions[3] = { kind = "spell", id = 2061 }
    check("#48: still protected after another Load", L.PlanSave().noop)
    G.spells[#G.spells + 1] = { id = 2060, name = "Greater Heal" }
    local pl = L.Plan(fork)
    L.Load(fork, pl)
    eq("#48: learned: the Load places it", G.actions[3] and G.actions[3].id, 2060)
    G.actions[3] = { kind = "item", id = 4540 }
    local mm = L.PlanSave()
    eq("#48: released: the edit is saved", mm and mm.modules.actions[3] and mm.modules.actions[3].id, 4540)
end

do
    -- save drop on a filled gap: the slot is saved empty, and the next Save
    -- doesn't take what is there.
    boot(); ready()
    local e = custom({ actions = { [3] = GH, [1] = FH } })
    alt({ actions = {} })
    L.Load(e, L.Plan(e))
    G.actions[3] = { kind = "spell", id = 2052 }
    G.actions[2] = { kind = "item", id = 4540 }
    local m = L.PlanSave(true)
    L.Save(m)
    eq("#48 drop: slot saved empty", A.Catalog.Get(e.id).modules.actions[3], nil)
    check("#48 drop: still covered", A.Cover.Has(A.Catalog.Get(e.id).modules.cover, 3))
    local m2 = L.PlanSave()
    check("#48 drop: next Save is a no-op", m2 and m2.noop, m2 and #m2.changed)
end

do
    -- Class marks: from a class tab only; a later Save adds them to an
    -- older (unmarked) entry once; a failed read never removes them.
    boot(); ready()
    G.setup{ class = "PRIEST", guid = "Player-70-MARK",
             spells = { { id = 20589, name = "Escape Artist", general = true }, { id = 2061, name = "Flash Heal" } },
             extra = { [3273] = "First Aid" },
             actions = { [1] = { spell = 20589 }, [2] = { spell = 2061 }, [3] = { spell = 3273 } } }
    ready()
    local c = L.Capture()
    eq("#48: racial (General tab) not marked", c.actions[1].class, nil)
    eq("#48: class tab spell marked", c.actions[2].class, true)
    eq("#48: profession not marked", c.actions[3].class, nil)
    -- An older entry without marks: one Save adds it, then nothing to save.
    local old = A.Catalog.Copy(c)
    old.actions[2].class = nil
    local e = custom(old)
    L.Load(e, L.Plan(e))
    local m = L.PlanSave()
    check("#48: adoption is a Save", m and not m.noop)
    eq("#48: no action listed as changed", m and #m.changed, 0)
    check("#48: says it marks", m and m.notes[1] and m.notes[1]:find("Marks 1 class spell", 1, true) ~= nil, m and m.notes[1])
    eq("#48: id and policy kept", m.modules.actions[2].id .. m.modules.actions[2].policy, "2061highest")
    L.Save(m)
    eq("#48: marked in the catalog", A.Catalog.Get(e.id).modules.actions[2].class, true)
    check("#48: then nothing to save", L.PlanSave().noop)
    -- A failed book read: the capture loses the mark, the entry keeps it.
    local realInfo2 = C_SpellBook.GetSpellBookItemInfo
    C_SpellBook.GetSpellBookItemInfo = function(i, ...) if i == 2 then error("read failed") end return realInfo2(i, ...) end
    check("#48: the capture really lost it", L.Capture().actions[2].class == nil)
    local m3 = L.PlanSave()
    C_SpellBook.GetSpellBookItemInfo = realInfo2
    check("#48: failed read keeps the mark", m3 and m3.modules.actions[2].class == true)
    -- Different family never adopts.
    eq("#48: same family by name", (function()
        local r = { baseline = { cover = FULL, actions = { [2] = { kind = "spell", id = 1, name = "X", policy = "highest" } } },
                    after = { cover = FULL, actions = { [2] = { kind = "spell", id = 2, name = "Y", policy = "highest" } } } }
        local o = L.Merge(r, { actions = { [2] = { kind = "spell", id = 2, name = "Y", policy = "highest", class = true } }, bindings = {} }, true)
        return o and tostring(o.modules.actions[2].class)
    end)(), "nil")
    -- A saved rank edit of a marked spell keeps the mark, even when the
    -- capture has none (its book item unreadable); another spell doesn't.
    local function rankEdit(cName)
        local x = { kind = "spell", id = 2050, name = "Lesser Heal", policy = "exact", class = true }
        local r = { baseline = { cover = FULL, actions = { [2] = x } }, after = { cover = FULL, actions = { [2] = A.Catalog.Copy(x) } } }
        local o = L.Merge(r, { actions = { [2] = { kind = "spell", id = 2052, name = cName, policy = "exact" } }, bindings = {} }, true)
        return o and o.modules.actions[2]
    end
    local o = rankEdit("Lesser Heal")
    eq("#48: rank edit saved", o and o.id, 2052)
    eq("#48: rank edit keeps the mark", o and o.class, true)
    eq("#48: another spell isn't marked", tostring((rankEdit("Renew") or {}).class), "nil")
end

do
    -- save drop: a dropped action is a covered empty slot, so a later Load
    -- empties it on another character; Restore puts it back.
    boot(); ready()
    local e = custom({ actions = { [3] = GH, [1] = FH } })
    alt({ actions = {} })
    L.Load(e, L.Plan(e))
    G.actions[2] = { kind = "item", id = 4540 }             -- a real edit, so the Save happens
    A._shown = nil
    A.Commands.save("drop")
    local text = A._shown and table.concat(A._shown.lines, "\n") or ""
    check("#46: drop preview says a later Load empties it", text:find("a later Load empties these slots", 1, true) ~= nil, text)
    A._shown.onConfirm()
    eq("#46: dropped from the entry", A.Catalog.Get(e.id).modules.actions[3], nil)
    check("#46: still covered", A.Cover.Has(A.Catalog.Get(e.id).modules.cover, 3))
    main(); ready()
    G.actions[3] = { kind = "spell", id = 2061 }
    local before = state()
    local live = A.Catalog.Get(e.id)
    local plan = L.Plan(live)
    L.Load(live, plan)
    eq("#46: the main's slot 3 emptied", G.actions[3], nil)
    L.Restore(1, L.PlanRestore(1))
    eq("#46: restore puts it back", state(), before)
end

do
    -- Interrupted while emptying: truthful failure, pinned backup, exact undo.
    boot(); ready()
    local e = custom({ actions = { [3] = GH } })
    alt({ actions = { [3] = { item = 4540 }, [4] = { spell = 2061 } } })
    local before = state()
    G.combatAfter = 1
    local p = L.Plan(e)
    local r = L.Load(e, p)
    G.combat = false
    check("#46 interrupted: failed", r and r.failed ~= nil)
    check("#46 interrupted: pinned", A.Backups.Operation() ~= nil)
    eq("#46 interrupted: cursor clean", G.cursor, nil)
    WoW.chatLines = {}
    A.Commands.Report("load", r, nil, p)
    local said = table.concat(WoW.chat(), "\n")
    check("#46 interrupted: no emptied count claimed", said:find("emptied", 1, true) == nil, said)
    L.Restore("op", L.PlanRestore("op"))
    eq("#46 interrupted: restored exactly", state(), before)
end

-- /code-review on #48.
do
    -- A loadout-empty slot holding what the backup can't restore is not this
    -- load's business: not listed, not unavailable, and a later edit there
    -- is saved.
    boot(); ready()
    local e = custom({ actions = { [3] = GH } })
    alt({ actions = { [30] = { flyout = 7 } } })
    local plan = L.Plan(e)
    eq("#48: blank slot with a flyout: not listed", byReason(plan.skips)[30], nil)
    L.Load(e, plan)
    eq("#48: not unavailable", rec().unavailable[30], nil)
    WoW.chatLines = {}
    local again = L.Plan(e)
    A.Commands.Report("load", L.Load(e, again), nil, again)
    local said = table.concat(WoW.chat(), "\n")
    check("#48: still 'already matches'", said:find("Already matches the loadout", 1, true) ~= nil, said)
    G.actions[30] = { kind = "spell", id = 2061 }
    local m = L.PlanSave()
    eq("#48: the edit there is saved", m and m.modules.actions[30] and m.modules.actions[30].id, 2061)

    -- A spell outside the class skill lines (a profession) is known by id:
    -- placed, never emptied as "not learned".
    local FA = { kind = "spell", id = 3273, name = "First Aid", policy = "highest" }
    boot(); ready()
    e = custom({ actions = { [3] = FA } })
    alt({ extra = { [3273] = "First Aid" }, actions = { [3] = { item = 4540 } } })
    plan = L.Plan(e)
    eq("#48: profession spell placed by id", ops(plan)[3] and ops(plan)[3].target and ops(plan)[3].target.id, 3273)
    L.Load(e, plan)
    eq("#48: on the bar", G.actions[3] and G.actions[3].id, 3273)
    alt({ actions = { [3] = { item = 4540 } } })
    plan = L.Plan(e)
    eq("#48: someone else's profession: left alone", byReason(plan.skips)[3], "not marked as a class spell")
    eq("#48: no op", ops(plan)[3], nil)
    -- No name to look it up by: left alone.
    e = custom({ actions = { [3] = { kind = "spell", id = 9999, policy = "highest" } } })
    plan = L.Plan(e)
    eq("#48: no name: left alone", byReason(plan.skips)[3], "spell name unknown")
    -- The by-id answer can't be read: left alone.
    e = custom({ actions = { [3] = GH } })
    local realPS = IsPlayerSpell
    IsPlayerSpell = function() error("read failed") end
    plan = L.Plan(e)
    IsPlayerSpell = realPS
    eq("#48: by-id read fails: left alone", byReason(plan.skips)[3], "spellbook unreadable")

    -- A book item of Spell type with no data yet: the book is incomplete.
    boot(); ready(); alt()
    local realInfo = C_SpellBook.GetSpellBookItemInfo
    C_SpellBook.GetSpellBookItemInfo = function(i, ...)
        if i == 1 then return { itemType = Enum.SpellBookItemType.Spell } end
        return realInfo(i, ...)
    end
    local book = A.Game.Spellbook()
    C_SpellBook.GetSpellBookItemInfo = realInfo
    eq("#48: nameless book spell: incomplete", book.complete, false)

    -- An account macro of that name with another body is the player's own:
    -- left alone, not "missing".
    boot(); ready()
    e = custom({ actions = { [3] = { kind = "macro", name = "Acct", scope = "account", body = "/say bye" } } })
    alt({ actions = { [3] = { macro = "Acct" } } })
    plan = L.Plan(e)
    eq("#48: edited account macro left alone", byReason(plan.skips)[3], "account macro differs")
    eq("#48: no op", ops(plan)[3], nil)

    -- Save preview: a rank change says so, not "macro text".
    boot(); ready()
    e = custom({ actions = { [2] = { kind = "spell", id = 2050, name = "Lesser Heal", policy = "exact" } } })
    alt({ actions = {} })
    L.Load(e, L.Plan(e))
    G.actions[2] = { kind = "spell", id = 2052 }
    A._shown = nil
    A.Commands.save("")
    local text = A._shown and table.concat(A._shown.lines, "\n") or ""
    check("#48: rank change labelled", text:find("Lesser Heal (rank or rank policy changed)", 1, true) ~= nil, text)
end

------------------------------------------------------------
-- #7: OK turns on character keybindings (Account -> Character only),
-- verified at every step, guarded after any stop.
------------------------------------------------------------
do
    local function calls()
        local out = {}
        for _, c in ipairs(G.calls) do
            if c == "SaveBindings" or c == "LoadBindings" or c == "SetBinding" or c == "PlaceAction" then out[#out + 1] = c end
        end
        return table.concat(out, ",")
    end
    local function chat() return table.concat(WoW.chat(), "\n") end
    -- The switch preview for "Everyday" on an Account-set alt.
    local function offer(opts)
        boot(); ready(); save()
        alt(opts or { bindingSet = 1 })
        A.Commands.load("Everyday")
        local shown = A._shown
        G.calls, WoW.chatLines = {}, {}
        return shown
    end

    -- Success: three calls, keys identical, guard gone, no load.
    local shown = offer()
    eq("#7: title", shown.title, "Load Everyday: step 1 of 2")
    local text = table.concat(shown.lines, "\n")
    check("#7: discloses the account save", text:find("saves your current keys as your account keybindings", 1, true) ~= nil)
    check("#7: says how to go back", text:find("untick it in Settings", 1, true) ~= nil)
    local before = A.Catalog.Copy(G.keys)
    G.keys["CTRL-9"] = "TOGGLEAUTORUN"                     -- another addon's unsaved key
    before["CTRL-9"] = "TOGGLEAUTORUN"
    shown.onConfirm()
    eq("#7: Blizzard's sequence, nothing else", calls(), "SaveBindings,LoadBindings,SaveBindings")
    eq("#7: character set on", G.bindingSet, 2)
    local function keystr(t)
        local o = {}
        for k, v in pairs(t) do o[#o + 1] = k .. "=" .. v end
        table.sort(o)
        return table.concat(o, " ")
    end
    eq("#7: keys identical", keystr(G.keys), keystr(before))
    eq("#7: saved as the character set", G.charStore["1"], before["1"])
    eq("#7: in-memory keys committed to the account set (disclosed)", G.accountKeys["CTRL-9"], "TOGGLEAUTORUN")
    eq("#7: guard cleared", A.char.bindingSwitch, nil)
    -- Step 2 waits (display only) for the switch's UPDATE_BINDINGS to settle,
    -- then shows the ordinary Load preview; its Load is the only load.
    eq("#7: step 2 waiting", A._shown.title, "Load Everyday: step 2 of 2")
    eq("#7: step 2 has no confirm while waiting", A._shown.confirm, false)
    WoW.tick(1)
    eq("#7: still waiting at 1 s", A._shown.title, "Load Everyday: step 2 of 2")
    WoW.tick(2)
    eq("#7: then the load preview", A._shown.title, "Load Everyday?")
    eq("#7: marked step 2", A._shown.lines[1], A.Commands.STEP2)
    eq("#7: with its Load button", A._shown.confirm, "Load")
    eq("#7: the wait wrote nothing", calls(), "SaveBindings,LoadBindings,SaveBindings")
    eq("#7: no other write at all before Load", #G.calls, 3)
    A._shown.onConfirm()
    eq("#7: loaded with keys", G.keys["2"], "ACTIONBUTTON2")

    -- Step 2 stops when its preview is gone: cancelled, or another opened.
    shown = offer()
    shown.onConfirm()
    A.Preview.Hide()
    WoW.tick(5)
    eq("#7: cancelled during the wait: nothing shown", A._shown, nil)
    shown = offer()
    shown.onConfirm()
    A.Commands.restore("1")
    local other = A._shown
    WoW.tick(5)
    check("#7: another preview opened: left alone", A._shown == other)
    -- Never ready: a timeout message, no load preview.
    shown = offer()
    shown.onConfirm()
    G.spells = {}
    WoW.tick(12)
    check("#7: timeout says what to do", (A._shown.lines[2] or ""):find("Still waiting", 1, true) ~= nil, A._shown.lines[2])
    eq("#7: timeout: no confirm", A._shown.confirm, false)
    eq("#7: timeout: nothing loaded", calls(), "SaveBindings,LoadBindings,SaveBindings")
    -- Replaced, then the deadline passes: the newer preview stays.
    shown = offer()
    shown.onConfirm()
    G.spells = {}
    A.Commands.restore("1")
    other = A._shown
    WoW.tick(12)
    check("#7: replaced: timeout leaves it alone", A._shown == other)
    -- Deleted during the wait: said so, nothing shown.
    shown = offer()
    shown.onConfirm()
    local live = A.Catalog.Get(entry.id)
    A.Catalog.Delete(entry.id, live.version)
    WoW.tick(3)
    eq("#7: deleted: nothing shown", A._shown, nil)
    check("#7: deleted: said so", chat():find("no longer exists", 1, true) ~= nil, chat())
    eq("#7: deleted: nothing loaded", calls(), "SaveBindings,LoadBindings,SaveBindings")
    -- Back on Account during the wait: the wizard ends, nothing loaded.
    shown = offer()
    shown.onConfirm()
    G.bindingSet = 1
    WoW.tick(3)
    eq("#7: back on Account: nothing shown", A._shown, nil)
    check("#7: back on Account: said so", chat():find("aren't on any more", 1, true) ~= nil, chat())
    eq("#7: back on Account: nothing loaded", calls(), "SaveBindings,LoadBindings,SaveBindings")
    -- No C_Timer: the message instead.
    shown = offer()
    local timer = C_Timer
    C_Timer = nil
    shown.onConfirm()
    C_Timer = timer
    check("#7: no timer: says to load", (A._shown.lines[2] or ""):find("/altsync load Everyday", 1, true) ~= nil)

    -- Refusals before any call: nothing written, no guard.
    local function refusedAtClick(label, arrange, want)
        local s = offer()
        arrange()
        s.onConfirm()
        eq("#7: " .. label .. ": no binding call", calls(), "")
        eq("#7: " .. label .. ": no guard", A.char.bindingSwitch, nil)
        check("#7: " .. label .. ": said so", chat():find(want, 1, true) ~= nil, chat())
    end
    refusedAtClick("set Character at the click", function() G.bindingSet = 2 end, "isn't on your account keybindings")
    refusedAtClick("set unreadable at the click", function() G.bindingSet = nil end, "isn't on your account keybindings")
    refusedAtClick("combat", function() G.combat = true end, "combat")
    refusedAtClick("not ready", function() WoW.fire("UPDATE_BINDINGS") end, "Waiting for character data")
    refusedAtClick("bindings unreadable", function() G.bindingFails = true end, "Couldn't read the key bindings")
    refusedAtClick("no binding list", function() G.numBindings = 0 end, "Couldn't read the key bindings")
    refusedAtClick("odd binding count", function() G.numBindings = "x" end, "Couldn't read the key bindings")

    -- A key map reads every key: a third key and commands outside ACTIONBUTTON.
    G.numBindings = nil
    G.keys = { ["A"] = "JUMP", ["B"] = "JUMP", ["C"] = "JUMP", ["D"] = "TOGGLEAUTORUN" }
    local map = A.Game.BindingMap()
    eq("#7: all keys of a command", map and table.concat(map.JUMP, ","), "A,B,C")
    eq("#7: any command", map and map.TOGGLEAUTORUN[1], "D")
    eq("#7: unbound commands left out", map and map.MOVEFORWARD, nil)
    G.emptyCommand = true
    eq("#7: an empty command: unreadable", A.Game.BindingMap(), nil)
    G.emptyCommand, G.keyFails = nil, true
    eq("#7: a failed key read: unreadable", A.Game.BindingMap(), nil)
    G.keyFails = nil

    -- Checked again before each call: combat that starts after the first,
    -- a set that changes, keys that can't be read any more.
    local function between(label, arrange, problem, wantCalls)
        local s = offer()
        local undo = arrange()
        s.onConfirm()
        if undo then undo() end
        eq("#7: " .. label .. ": stopped", calls(), wantCalls)
        check("#7: " .. label .. ": why", chat():find(problem, 1, true) ~= nil, chat())
        check("#7: " .. label .. ": guard kept", A.char.bindingSwitch ~= nil)
    end
    between("combat after the first call", function() G.combatAfter = 1 end, "combat started", "SaveBindings")
    between("set changed after the first call", function()
        local real = SaveBindings
        SaveBindings = function(set) real(set); G.bindingSet = 2 end
        return function() SaveBindings = real end
    end, "the keybinding set changed", "SaveBindings")
    between("keys unreadable after loading", function()
        local real = LoadBindings
        LoadBindings = function(set) real(set); G.bindingFails = true end
        return function() LoadBindings = real end
    end, "couldn't read the keys to check them", "SaveBindings,LoadBindings")

    -- Every call failing every way: stop there, guard kept, never "Nothing
    -- changed"; when keys changed, a retry makes no binding call at all.
    local seq = { "SaveBindings1", "LoadBindings2", "SaveBindings2" }
    local want = { "SaveBindings", "SaveBindings,LoadBindings", "SaveBindings,LoadBindings,SaveBindings" }
    for i, name in ipairs(seq) do
        for _, mode in ipairs({ "error", "false", "change-error", "change-false" }) do
            local label = name .. " " .. mode
            local s = offer()
            G.bindFault = { [name] = mode }
            s.onConfirm()
            eq("#7: " .. label .. ": stopped there", calls(), want[i])
            check("#7: " .. label .. ": guard kept", A.char.bindingSwitch ~= nil and A.char.bindingSwitch.before ~= nil)
            check("#7: " .. label .. ": reported", chat():find("Stopped while", 1, true) ~= nil, chat())
            check("#7: " .. label .. ": never 'nothing changed'", chat():find("Nothing changed", 1, true) == nil)
            eq("#7: " .. label .. ": still Account", G.bindingSet, 1)
            G.bindFault = nil
            G.calls, WoW.chatLines = {}, {}
            ready()
            local ok, why = L.UseCharacterBindings()
            if mode:find("^change") then
                eq("#7: " .. label .. ": retry refused", why, L.SWITCH_GUARDED)
                eq("#7: " .. label .. ": retry makes no call", calls(), "")
                -- Put the key back: the retry runs, against the first baseline.
                G.keys["F12"] = nil
                ok = L.UseCharacterBindings()
                check("#7: " .. label .. ": keys as before: retry runs", ok == true)
            else
                check("#7: " .. label .. ": keys unchanged: retry runs", ok == true, why)
            end
            eq("#7: " .. label .. ": guard cleared on success", A.char.bindingSwitch, nil)
        end
    end

    -- Successful calls, failed verification: an injected Character store that
    -- differs. Character is never saved, and the guard stays.
    local s = offer({ bindingSet = 1, charStore = { ["1"] = "JUMP" } })
    s.onConfirm()
    eq("#7: differing store: no Character save", calls(), "SaveBindings,LoadBindings")
    check("#7: differing store: commands listed", chat():find("ACTIONBUTTON", 1, true) ~= nil, chat())
    check("#7: differing store: retry warned", chat():find("switching again is refused while they differ", 1, true) ~= nil)
    check("#7: differing store: guard kept", A.char.bindingSwitch ~= nil)
    -- Reinitialised (a reload): the guard came from SavedVariables, the keys
    -- still differ, so a retry makes zero binding calls.
    local db, ch = AltStableSyncDB, AltStableSyncChar
    WoW.reset()
    for _, f in ipairs({ "Core.lua", "Categories.lua", "Catalog.lua", "Game.lua", "Backups.lua",
                         "Ready.lua", "Loadout.lua", "Commands.lua" }) do
        assert(loadfile(f))("AltStableSync", {})
    end
    AltStableSyncDB, AltStableSyncChar = db, ch
    WoW.fire("ADDON_LOADED", "AltStableSync")
    A, L = AltStableSync, AltStableSync.Loadout
    A.Preview = { Show = function(o) A._shown = o end, Hide = function() A._shown = nil end,
                  Shown = function() return A._shown end }
    ready()
    check("#7: guard survives a reload", A.char.bindingSwitch ~= nil)
    G.calls = {}
    local ok, why = L.UseCharacterBindings()
    eq("#7: after reload: refused", why, L.SWITCH_GUARDED)
    eq("#7: after reload: zero binding calls", calls(), "")
    WoW.chatLines = {}
    A.SlashHandler("status")
    check("#7: status shows the guard", chat():find("switch to character keybindings stopped", 1, true) ~= nil, chat())
    -- Dormant on Character: a normal Character-binding load leaves it alone,
    -- and it still blocks a later switch from Account with different keys.
    G.bindingSet, G.charStore = 2, A.Catalog.Copy(G.keys)
    local r = L.Load(entry, L.Plan(entry))
    check("#7: Character load works with a guard", r and not r.failed, r and tostring(r.failed))
    check("#7: guard left on Character", A.char.bindingSwitch ~= nil)
    G.bindingSet = 1
    G.calls = {}
    ok, why = L.UseCharacterBindings()
    eq("#7: back on Account, keys differ: refused", why, L.SWITCH_GUARDED)
    eq("#7: no call", calls(), "")
    -- The final set check: calls succeed but Character never turns on.
    s = offer()
    local realSave = SaveBindings
    SaveBindings = function(set) if set == 2 then G.calls[#G.calls + 1] = "SaveBindings" return end return realSave(set) end
    s.onConfirm()
    SaveBindings = realSave
    check("#7: set never Character: reported", chat():find("character keybindings didn't turn on", 1, true) ~= nil, chat())
    check("#7: set never Character: guard kept", A.char.bindingSwitch ~= nil)
    -- bindingsUnsaved: cleared only by a complete switch.
    s = offer()
    A.char.bindingsUnsaved = true
    s.onConfirm()
    eq("#7: success clears the unsaved flag", A.char.bindingsUnsaved, nil)
    s = offer()
    A.char.bindingsUnsaved = true
    G.bindFault = { LoadBindings2 = "error" }
    s.onConfirm()
    eq("#7: failure leaves the unsaved flag", A.char.bindingsUnsaved, true)
end

finish("test_loadout")
