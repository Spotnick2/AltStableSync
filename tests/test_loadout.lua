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
    A.Preview = { Show = function(o) A._shown = o end, Hide = function() end }
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
            [2] = { spell = 2050 },                 -- Lesser Heal r1 while r2 known -> exact (downrank)
            [3] = { item = 5512 },                  -- Healthstone
            [4] = { macro = "Shield" },             -- character macro
            [5] = { macro = "Acct" },               -- account macro
            [6] = { flyout = 1 },                   -- unsupported
            [7] = { macro = "Dup" },                -- ambiguous name -> unsupported
            [8] = { spell = 2060 },                 -- Greater Heal (an alt won't know it)
        },
        keys = { ["1"] = "ACTIONBUTTON1", ["2"] = "ACTIONBUTTON2", ["SHIFT-2"] = "ACTIONBUTTON2" },
    }
end

local function state()
    local parts = {}
    for slot = 1, 12 do
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
    local why = {}
    for _, s in ipairs(plan.skips) do why[s.slot] = s.reason end
    eq("A07: future spell skipped", why[8], "not learned")
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
    eq("A07: food untouched where the future spell goes", G.actions[8].id, 4540)
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
    for _, s in ipairs(plan.skips) do why[s.slot] = s.reason end
    eq("conflict: skipped", why[4], "macro name conflict")
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
    for _, s in ipairs(plan.skips) do why[s.slot] = s.reason end
    eq("A18: macro slots full", why[4], "macro slots full")
    G.calls = {}
    L.Load(entry, plan)
    for _, c in ipairs(G.calls) do check("A18: no CreateMacro", c ~= "CreateMacro") end

    -- Account macro missing: never created.
    boot(); ready(); save()
    alt({ macros = { { name = "Zed", body = "/z", char = true } } })
    plan = L.Plan(entry)
    why = {}
    for _, s in ipairs(plan.skips) do why[s.slot] = s.reason end
    eq("account macro missing: skipped", why[5], "account macro missing")

    -- A20: account bindings -> bindings blocked, actions still load.
    boot(); ready(); save()
    alt({ bindingSet = 1 })
    plan = L.Plan(entry)
    check("A20: bindings blocked with the instruction", (plan.keysBlocked or ""):find("character%-specific") ~= nil)
    G.calls = {}
    local r = L.Load(entry, plan)
    check("A20: actions loaded", r and r.changed > 0)
    for _, c in ipairs(G.calls) do check("A20: no binding write", c ~= "SetBinding" and c ~= "SaveBindings") end
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
    if wantWhy then eq(label .. ": why", r and r.failed, wantWhy) end
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

finish("test_loadout")
