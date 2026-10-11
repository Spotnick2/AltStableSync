------------------------------------------------------------
-- test_pet.lua - the pet bar layout per pet family (#47 part B)
--
-- Against the pet model in tests/wow_game.lua (the 70338 measurements in
-- docs/forever-api-notes.md "Pet bar"). Capture, plan (ranks, verified
-- absence, ambiguity, locale, frozen slots, tokens, duplicates), execute
-- (read-back, faults with the payload put back or left on the cursor, never
-- cleared), restore (same pet, another pet, partial), Save and Save As.
------------------------------------------------------------

dofile("tests/harness.lua")
dofile("tests/wow_stubs.lua")
dofile("tests/wow_game.lua")

local G = WoW.game
local A, L, P

local function boot()
    WoW.reset()
    for _, f in ipairs({ "Core.lua", "Categories.lua", "Catalog.lua", "Envelope.lua", "Game.lua", "Pet.lua", "Backups.lua",
                         "Ready.lua", "Loadout.lua", "Commands.lua" }) do
        assert(loadfile(f))("AltStableSync", {})
    end
    WoW.fire("ADDON_LOADED", "AltStableSync")
    A, L, P = AltStableSync, AltStableSync.Loadout, AltStableSync.Pet
    A.Preview = { Show = function(o) A._shown = o end, Hide = function() A._shown = nil end,
                  Shown = function() return A._shown end }
end
local function ready()
    WoW.fire("PLAYER_ENTERING_WORLD", true, false)
    WoW.clock = WoW.clock + 10
end

local T = function(t) return { token = t } end
local S = function(id) return { spell = id } end
local ATTACK, FOLLOW, MOVE, STAY = "PET_ACTION_ATTACK", "PET_ACTION_FOLLOW", "PET_ACTION_MOVE_TO", "PET_ACTION_WAIT"
local ASSIST, DEF, PASSIVE = "PET_MODE_ASSIST", "PET_MODE_DEFENSIVEASSIST", "PET_MODE_PASSIVE"

-- Cowruzo's bear: Growl r2, Claw, Bite.
local BEAR_A = {
    name = "Tarthosuk", guid = "Pet-0-A1",
    bar = { [1] = T(ATTACK), [2] = T(FOLLOW), [3] = T(MOVE), [4] = S(14916), [5] = S(16827), [6] = S(17253),
            [8] = T(ASSIST), [9] = T(DEF), [10] = T(PASSIVE) },
    book = { { name = "Aggressive" }, { id = 17253, name = "Bite" }, { id = 16827, name = "Claw" },
             { id = 14916, name = "Growl" }, { id = 4188, name = "Great Stamina", passive = true } },
}
-- Kaleid's bear: Growl r1, Claw r1, Cower; no Bite. Arranged differently.
local function bearB(over)
    local o = {
        name = "Tarthosuk", guid = "Pet-0-B1",
        bar = { [1] = T(FOLLOW), [2] = T(ATTACK), [3] = T(MOVE), [4] = S(1082), [6] = S(2649), [7] = S(1742),
                [8] = T(ASSIST), [9] = T(DEF), [10] = T(PASSIVE) },
        book = { { name = "Aggressive" }, { id = 1082, name = "Claw" }, { id = 1742, name = "Cower" }, { id = 2649, name = "Growl" } },
    }
    for k, v in pairs(over or {}) do o[k] = v end
    return o
end

local function hunter(pet, extra)
    local opts = { class = "HUNTER", guid = "Player-70-HUNT", spells = { { id = 75, name = "Auto Shot" } }, keys = {}, pet = pet }
    for k, v in pairs(extra or {}) do opts[k] = v end
    G.setup(opts)
end

local function bar()
    local out = {}
    for i = 1, 10 do
        local a = G.pet and G.pet.bar[i]
        out[i] = a and (a.token or tostring(a.spell)) or "-"
    end
    return table.concat(out, " ")
end
local function count(name)
    local n = 0
    for _, c in ipairs(G.calls) do if c == name then n = n + 1 end end
    return n
end
local function text(plan) return table.concat(A.Commands.Describe(plan), "\n") end

-- Save As on Cowruzo: the entry the other tests load.
local entry
local function saveBearA()
    boot(); hunter(BEAR_A); ready()
    local p = assert(L.PlanSaveAs())
    entry = assert(L.SaveAs(p, "Bears"))
    return entry
end

------------------------------------------------------------
-- Capture
------------------------------------------------------------
do
    saveBearA()
    local pet = entry.modules.pet
    local layout = pet and pet[4]
    check("capture: keyed by family id", layout ~= nil)
    eq("capture: family name for display", layout.family, "Bear")
    eq("capture: locale", layout.locale, "enUS")
    eq("capture: a command", layout.slots[1].token, ATTACK)
    eq("capture: an ability by id", layout.slots[4].id, 14916)
    eq("capture: and name", layout.slots[4].name, "Growl")
    eq("capture: an empty slot is false", layout.slots[7], false)
    check("capture: valid", P.Valid(layout))
    -- No pet out: nothing captured, not an error.
    boot(); hunter(nil); ready()
    eq("capture: no pet", L.Capture().pet, nil)
    -- A pet whose bar can't be read: no pet capture, never a partial one.
    boot(); hunter(BEAR_A); ready()
    G.petReadFails = true
    eq("capture: unreadable", L.Capture().pet, false)
    local p = assert(L.PlanSaveAs())
    eq("capture: unreadable not stored by Save As", p.modules.pet, nil)
    G.petReadFails = nil
    -- Validation: ten slots, each false or well formed.
    local bad = A.Catalog.Copy(layout)
    bad.slots[10] = nil
    check("valid: nine slots is damaged", not P.Valid(bad))
    bad.slots[10] = { kind = "spell", id = "x" }
    check("valid: a bad slot is damaged", not P.Valid(bad))
    -- An ability needs a positive whole id and a name (Codex on #54).
    for _, s in ipairs({ { kind = "spell", id = 0, name = "Growl" }, { kind = "spell", id = 2649.5, name = "Growl" },
                         { kind = "spell", id = 2649 }, { kind = "spell", id = 2649, name = "" } }) do
        bad.slots[10] = s
        check("valid: damaged spell " .. tostring(s.id) .. "/" .. tostring(s.name), not P.Valid(bad))
    end
end

------------------------------------------------------------
-- Load onto another bear: ranks by name, verified absence, moves
------------------------------------------------------------
do
    saveBearA()
    hunter(bearB())
    local plan = L.Plan(entry)
    local pp = plan.pet
    check("load: pet part planned", pp and pp.layout)
    eq("load: final bar", (function()
        local out = {}
        for i = 1, 10 do local s = pp.final[i]; out[i] = s and (s.token or tostring(s.id)) or "-" end
        return table.concat(out, " ")
    end)(), table.concat({ ATTACK, FOLLOW, MOVE, "2649", "1082", "-", "-", ASSIST, DEF, PASSIVE }, " "))
    eq("load: Bite verified absent", pp.absent[6], "this pet doesn't have it")
    eq("load: no skips", #pp.skips, 0)
    local t = text(plan)
    check("preview: pet heading", t:find("Pet bar (Bear Tarthosuk): 6 slots change. Autocast stays as the game has it.", 1, true) ~= nil, t)
    check("preview: absent named", t:find("pet slot 6: Growl -> empty (Bite: this pet doesn't have it)", 1, true) ~= nil, t)
    check("preview: unwanted ability removed", t:find("pet slot 7: Cower -> empty", 1, true) ~= nil, t)
    G.calls = {}
    local r = assert(L.Load(entry, plan))
    eq("load: not failed", r.failed, nil)
    eq("load: bar", bar(), table.concat({ ATTACK, FOLLOW, MOVE, "2649", "1082", "-", "-", ASSIST, DEF, PASSIVE }, " "))
    eq("load: cursor empty", G.cursor, nil)
    eq("load: one ClearCursor (the removal)", count("ClearCursor"), 1)
    eq("load: nothing blocked", #G.blocked, 0)
    eq("load: pet ops counted", r.pet, #pp.ops)
    local rec = A.char.loaded.loadout
    eq("record: comparison for the bear", rec.after.pet[4].slots[4].id, 2649)
    eq("record: absent slot unavailable", rec.after.pet[4].unavailable[6], "this pet doesn't have it")
    check("record: backup released", A.Backups.Operation() == nil)
    WoW.chatLines = {}
    A.Commands.Report("load", r, nil, plan)
    local said = table.concat(WoW.chat(), "\n")
    check("report: pet slots counted", said:find("6 pet slots", 1, true) ~= nil, said)
    -- Loading again: nothing to do.
    check("load again: no-op", L.Plan(entry).noop)

    -- Restore the backup: Kaleid's bar exactly as it was.
    local rp = L.PlanRestore(1)
    check("restore: pet part", rp.pet and #rp.pet.ops > 0)
    local rr = assert(L.Restore(1, rp))
    eq("restore: bar back", bar(), table.concat({ FOLLOW, ATTACK, MOVE, "1082", "-", "2649", "1742", ASSIST, DEF, PASSIVE }, " "))
    eq("restore: complete", rr.partial, nil)
    -- Another pet out: the pet part is unavailable, the restore partial.
    G.pet.name = "Other"
    rp = L.PlanRestore(1)
    check("restore other pet: missing", rp.pet and rp.pet.missing and rp.pet.missing:find("needs Bear Tarthosuk out", 1, true) ~= nil,
          rp.pet and rp.pet.missing)
    check("restore other pet: preview says so", text(rp):find("Pet bar: not restored (needs Bear Tarthosuk out).", 1, true) ~= nil, text(rp))
    G.pet.bar[7] = nil                        -- something else to restore, so it runs
    rp = L.PlanRestore(1)
    rr = assert(L.Restore(1, rp))
    eq("restore other pet: partial", rr.partial, true)
    eq("restore other pet: bar untouched", bar(), table.concat({ FOLLOW, ATTACK, MOVE, "1082", "-", "2649", "-", ASSIST, DEF, PASSIVE }, " "))
end

------------------------------------------------------------
-- The fingerprint: a resummon or a changed bar refuses the confirm
------------------------------------------------------------
do
    saveBearA()
    hunter(bearB())
    local plan = L.Plan(entry)
    G.pet.guid = "Pet-0-B2"                   -- resummoned between preview and confirm
    G.calls = {}
    local r, err = L.Load(entry, plan)
    check("resummon: refused", r == nil and tostring(err):find("changed since the preview", 1, true) ~= nil, tostring(err))
    eq("resummon: wrote nothing", #G.calls, 0)
    hunter(bearB())
    plan = L.Plan(entry)
    G.pet.bar[7] = nil                        -- the player moved something
    r, err = L.Load(entry, plan)
    check("bar changed: refused", r == nil, tostring(err))
end

------------------------------------------------------------
-- The planner's rules
------------------------------------------------------------
do
    saveBearA()
    -- Place from the book: Claw isn't on the bar, the book has it.
    hunter(bearB({ bar = { [1] = T(ATTACK), [2] = T(FOLLOW), [3] = T(MOVE), [4] = S(2649),
                          [8] = T(ASSIST), [9] = T(DEF), [10] = T(PASSIVE) } }))
    local plan = L.Plan(entry)
    local placed
    for _, op in ipairs(plan.pet.ops) do if op.op == "place" then placed = op end end
    eq("place: into slot 5", placed and placed.to, 5)
    eq("place: Claw r1 from the book", placed and placed.item.id, 1082)
    L.Load(entry, plan)
    eq("place: on the bar", G.pet.bar[5] and G.pet.bar[5].spell, 1082)

    -- A command the loadout doesn't want stays; its slot is skipped.
    hunter(bearB({ bar = { [1] = T(ATTACK), [2] = T(FOLLOW), [3] = T(MOVE), [4] = S(2649), [5] = S(1082), [7] = T(STAY),
                          [8] = T(ASSIST), [9] = T(DEF), [10] = T(PASSIVE) } }))
    plan = L.Plan(entry)
    eq("unwanted command: skipped", plan.pet.skips[1] and plan.pet.skips[1].slot, 7)
    eq("unwanted command: reason", plan.pet.skips[1] and plan.pet.skips[1].reason, "a command stays: an addon can't put one back")
    G.calls = {}
    L.Load(entry, plan)
    eq("unwanted command: still there", G.pet.bar[7] and G.pet.bar[7].token, STAY)

    -- A command the loadout wants that isn't on this bar: skipped.
    hunter(bearB({ bar = { [1] = T(ATTACK), [2] = T(FOLLOW), [4] = S(2649), [5] = S(1082),
                          [8] = T(ASSIST), [9] = T(DEF), [10] = T(PASSIVE) } }))
    plan = L.Plan(entry)
    eq("missing command: slot 3 skipped", plan.pet.skips[1] and plan.pet.skips[1].slot, 3)
    eq("missing command: reason", plan.pet.skips[1] and plan.pet.skips[1].reason, "this command isn't on this pet's bar")

    -- Two book abilities share a name: skipped, never guessed.
    hunter(bearB({ book = { { id = 1082, name = "Claw" }, { id = 2649, name = "Growl" }, { id = 2650, name = "Growl" } } }))
    plan = L.Plan(entry)
    local reasons = {}
    for _, s in ipairs(plan.pet.skips) do reasons[s.slot] = s.reason end
    eq("ambiguous: skipped", reasons[4], "two pet abilities have this name")

    -- Another game language: by id only.
    local de = A.Catalog.Copy(entry.modules)
    de.pet[4].locale = "deDE"
    local eDe = assert(A.Catalog.Create("loadout", { class = "HUNTER", category = "general", name = "German" }, de))
    hunter(bearB())
    plan = L.Plan(eDe)
    reasons = {}
    for _, s in ipairs(plan.pet.skips) do reasons[s.slot] = s.reason end
    eq("locale: Growl by name skipped", reasons[4], "saved in another game language")
    eq("locale: not verified absent", plan.pet.absent[6], nil)
    -- Same id in another language still loads.
    hunter(BEAR_A)
    G.pet.bar[4], G.pet.bar[5] = G.pet.bar[5], G.pet.bar[4]
    plan = L.Plan(eDe)
    eq("locale: by id loads", #plan.pet.skips, 0)

    -- The same ability twice in the loadout: the second slot is skipped.
    local dup = A.Catalog.Copy(entry.modules)
    dup.pet[4].slots[7] = { kind = "spell", id = 14916, name = "Growl" }
    local eDup = assert(A.Catalog.Create("loadout", { class = "HUNTER", category = "general", name = "Dup" }, dup))
    hunter(BEAR_A)
    plan = L.Plan(eDup)
    eq("duplicate: second skipped", plan.pet.skips[1] and plan.pet.skips[1].slot, 7)

    -- Frozen propagation: Growl is wanted in a slot held by an unwanted
    -- command, so Growl stays where it is, and that slot is frozen too.
    local fz = A.Catalog.Copy(entry.modules)
    fz.pet[4].slots[7] = { kind = "spell", id = 14916, name = "Growl" }
    fz.pet[4].slots[4] = false
    local eFz = assert(A.Catalog.Create("loadout", { class = "HUNTER", category = "general", name = "Frozen" }, fz))
    hunter(BEAR_A)
    G.pet.bar[7] = T(STAY)
    plan = L.Plan(eFz)
    reasons = {}
    for _, s in ipairs(plan.pet.skips) do reasons[s.slot] = s.reason end
    eq("frozen: the command's slot", reasons[7], "a command stays: an addon can't put one back")
    eq("frozen: Growl kept where it is", reasons[4], "kept for pet slot 7, which is left unchanged")
    for _, op in ipairs(plan.pet.ops) do
        check("frozen: no op touches 4 or 7", op.from ~= 4 and op.from ~= 7 and op.to ~= 4 and op.to ~= 7)
    end

    -- A wanted ability that sits in a slot left unchanged is never placed a
    -- second time: its target slot is skipped too.
    local onf = A.Catalog.Copy(entry.modules)
    onf.pet[4].slots[7] = { kind = "spell", id = 5555, name = "Dash" }
    local eOnf = assert(A.Catalog.Create("loadout", { class = "HUNTER", category = "general", name = "OnFrozen" }, onf))
    hunter(bearB({ bar = { [1] = T(ATTACK), [2] = T(FOLLOW), [3] = T(MOVE), [5] = S(1082), [7] = S(2649),
                          [8] = T(ASSIST), [9] = T(DEF), [10] = T(PASSIVE) },
                   book = { { id = 1082, name = "Claw" }, { id = 2649, name = "Growl" },
                            { id = 61684, name = "Dash" }, { id = 61685, name = "Dash" } } }))
    plan = L.Plan(eOnf)
    reasons = {}
    for _, s in ipairs(plan.pet.skips) do reasons[s.slot] = s.reason end
    eq("on frozen: slot 7 skipped", reasons[7], "two pet abilities have this name")
    eq("on frozen: Growl's target skipped", reasons[4], "already in pet slot 7, which is left unchanged")
    for _, op in ipairs(plan.pet.ops) do check("on frozen: no second Growl", op.op ~= "place" or op.item.id ~= 2649) end

    -- The pet book can't be read: no pet writes, no comparison recorded.
    hunter(bearB())
    G.petBookFails = true
    plan = L.Plan(entry)
    check("book unreadable: no ops", #plan.pet.ops == 0 and plan.pet.failed)
    check("book unreadable: preview", text(plan):find("Pet bar: not changed (the pet spellbook couldn't be read).", 1, true) ~= nil, text(plan))
    L.Load(entry, plan)
    eq("book unreadable: no pet comparison", A.char.loaded.loadout.after.pet, nil)
    G.petBookFails = nil

    -- No pet out: nothing happens; the preview names what the loadout keeps.
    hunter(nil)
    plan = L.Plan(entry)
    check("no pet: no-op", plan.noop)
    check("no pet: kept for later", text(plan):find("Pet bars kept for other pets: Bear (loaded only with one of them out).", 1, true) ~= nil, text(plan))

    -- An imp out, the loadout has a bear bar only.
    hunter({ family = 23, familyName = "Imp", name = "Geltog", guid = "Pet-0-I1",
             bar = { [1] = T(ATTACK), [4] = S(3110) }, book = { { id = 3110, name = "Firebolt" } } })
    plan = L.Plan(entry)
    eq("other family: nothing to write", #plan.pet.ops, 0)
    check("other family: says so", text(plan):find("no pet bar saved for this pet", 1, true) ~= nil, text(plan))

    -- A damaged layout is never loaded.
    local dmg = A.Catalog.Copy(entry.modules)
    dmg.pet[4].slots[3] = nil
    local eDmg = assert(A.Catalog.Create("loadout", { class = "HUNTER", category = "general", name = "Damaged" }, dmg))
    hunter(bearB())
    plan = L.Plan(eDmg)
    check("damaged: no ops", #plan.pet.ops == 0 and plan.pet.note == "the saved Bear pet bar is damaged")
    -- An ability with id 0 and no name never empties the slot it's in.
    local zero = A.Catalog.Copy(entry.modules)
    zero.pet[4].slots[6] = { kind = "spell", id = 0 }
    local eZero = assert(A.Catalog.Create("loadout", { class = "HUNTER", category = "general", name = "Zero" }, zero))
    hunter(bearB())
    plan = L.Plan(eZero)
    check("id 0: damaged, no ops", #plan.pet.ops == 0 and plan.pet.note == "the saved Bear pet bar is damaged")
    G.calls = {}
    L.Load(eZero, plan)
    eq("id 0: Growl still in slot 6", G.pet.bar[6] and G.pet.bar[6].spell, 2649)
end

------------------------------------------------------------
-- Execute: faults
------------------------------------------------------------
local function cursorPet() return G.cursor and G.cursor.kind == "petaction" end
do
    -- The second call of a swap fails: the payload goes back into the slot
    -- the swap emptied, and the backup stays pinned.
    saveBearA()
    hunter(bearB())
    local plan = L.Plan(entry)
    G.petFault = function(name, n) if name == "PickupPetAction" and n == 2 then return "error" end end
    local r = L.Load(entry, plan)
    check("fault 2nd call: stopped", r and r.failed ~= nil)
    check("fault 2nd call: put back", tostring(r.failed):find("went back to pet slot 2", 1, true) ~= nil, tostring(r.failed))
    eq("fault 2nd call: cursor empty", G.cursor, nil)
    eq("fault 2nd call: bar as before", bar(), table.concat({ FOLLOW, ATTACK, MOVE, "1082", "-", "2649", "1742", ASSIST, DEF, PASSIVE }, " "))
    check("fault 2nd call: backup pinned", A.Backups.Operation() ~= nil)
    eq("fault 2nd call: no ClearCursor", count("ClearCursor"), 0)

    -- A resummon after the first pickup: the guard stops every call, so the
    -- payload stays on the cursor, named, never cleared.
    saveBearA()
    hunter(bearB())
    plan = L.Plan(entry)
    G.calls = {}
    G.onPetCall = function(name, n) if n == 1 then G.pet.guid = "Pet-0-B9" end end
    r = L.Load(entry, plan)
    check("resummon mid-op: stopped", r and r.failed ~= nil)
    check("resummon mid-op: left on the cursor", cursorPet())
    check("resummon mid-op: names the slot", tostring(r.failed):find("drop it into pet slot 2", 1, true) ~= nil, tostring(r.failed))
    eq("resummon mid-op: no ClearCursor", count("ClearCursor"), 0)
    G.onPetCall = nil

    -- Combat after the first pickup: nothing protected runs in combat.
    saveBearA()
    hunter(bearB())
    plan = L.Plan(entry)
    G.combatAfter = 1
    G.calls = {}
    r = L.Load(entry, plan)
    check("combat mid-op: stopped", r and r.failed ~= nil)
    eq("combat mid-op: nothing blocked", #G.blocked, 0)
    check("combat mid-op: left on the cursor", cursorPet())
    eq("combat mid-op: no ClearCursor", count("ClearCursor"), 0)

    -- A drop that does nothing (the client ignored it): read back catches it,
    -- the vacancy takes the payload back.
    saveBearA()
    hunter(bearB())
    plan = L.Plan(entry)
    G.petFault = function(name, n) if name == "PickupPetAction" and n == 2 then return "noop" end end
    r = L.Load(entry, plan)
    check("silent drop: stopped", r and r.failed ~= nil)
    eq("silent drop: cursor empty", G.cursor, nil)
    eq("silent drop: bar as before", G.pet.bar[2] and G.pet.bar[2].token, ATTACK)

    -- A call that acts and then raises: the read-back decides.
    saveBearA()
    hunter(bearB())
    plan = L.Plan(entry)
    G.petFault = function(name, n) if name == "PickupPetAction" and n == 3 then return "after-error" end end
    r = L.Load(entry, plan)
    check("act then raise: stopped", r and r.failed ~= nil)
    eq("act then raise: cursor empty", G.cursor, nil)
    eq("act then raise: no ClearCursor", count("ClearCursor"), 0)

    -- The book pickup fails during a placement: nothing on the cursor.
    saveBearA()
    hunter(bearB({ bar = { [1] = T(ATTACK), [2] = T(FOLLOW), [3] = T(MOVE), [4] = S(2649),
                          [8] = T(ASSIST), [9] = T(DEF), [10] = T(PASSIVE) } }))
    plan = L.Plan(entry)
    G.petFault = function(name) if name == "PickupSpellBookItem" then return "noop" end end
    r = L.Load(entry, plan)
    check("book pickup fails: stopped", r and tostring(r.failed):find("pickup from the pet spellbook failed", 1, true) ~= nil,
          r and tostring(r.failed))
    eq("book pickup fails: cursor empty", G.cursor, nil)

    -- The drop of a placement fails once: the ability goes into its slot
    -- (the vacancy) on the recovery call, never cleared.
    saveBearA()
    hunter(bearB({ bar = { [1] = T(ATTACK), [2] = T(FOLLOW), [3] = T(MOVE), [4] = S(2649),
                          [8] = T(ASSIST), [9] = T(DEF), [10] = T(PASSIVE) } }))
    plan = L.Plan(entry)
    local seen = 0
    G.petFault = function(name) if name == "PickupPetAction" then seen = seen + 1; if seen == 1 then return "error" end end end
    G.calls = {}
    r = L.Load(entry, plan)
    check("place drop fails: stopped", r and r.failed ~= nil)
    eq("place drop fails: cursor empty", G.cursor, nil)
    eq("place drop fails: no ClearCursor", count("ClearCursor"), 0)
    G.petFault = nil

    -- A filled vacancy: the payload can't go back, so it stays on the cursor.
    saveBearA()
    hunter(bearB())
    plan = L.Plan(entry)
    G.onPetCall = function(name, n) if n == 2 then G.pet.bar[2] = T(STAY) end end
    G.petFault = function(name, n) if n == 2 then return "error" end end
    r = L.Load(entry, plan)
    check("filled vacancy: left on the cursor", cursorPet())
    check("filled vacancy: names the slot", tostring(r.failed):find("drop it into pet slot 2", 1, true) ~= nil, tostring(r.failed))
    eq("filled vacancy: the cursor still holds Attack", G.cursor and G.cursor.item.token, ATTACK)
    eq("filled vacancy: slot 2 untouched", G.pet.bar[2] and G.pet.bar[2].token, STAY)
    G.onPetCall, G.petFault = nil, nil

    -- A removal whose pickup does nothing: stopped before any ClearCursor.
    saveBearA()
    hunter(bearB({ bar = { [1] = T(ATTACK), [2] = T(FOLLOW), [3] = T(MOVE), [4] = S(2649), [5] = S(1082), [7] = S(1742),
                          [8] = T(ASSIST), [9] = T(DEF), [10] = T(PASSIVE) } }))
    plan = L.Plan(entry)
    eq("remove only: one op", #plan.pet.ops, 1)
    G.petFault = function(name) if name == "PickupPetAction" then return "noop" end end
    G.calls = {}
    r = L.Load(entry, plan)
    eq("remove fails: stopped there", r and r.at, "pet slot 7")
    eq("remove fails: no ClearCursor", count("ClearCursor"), 0)
    eq("remove fails: Cower still there", G.pet.bar[7] and G.pet.bar[7].spell, 1742)
    G.petFault = nil

    -- Combat begins with the removal's pickup: the planned clear doesn't run,
    -- the ability stays on the cursor, and the load stays interrupted.
    saveBearA()
    hunter(bearB({ bar = { [1] = T(ATTACK), [2] = T(FOLLOW), [3] = T(MOVE), [4] = S(2649), [5] = S(1082), [7] = S(1742),
                          [8] = T(ASSIST), [9] = T(DEF), [10] = T(PASSIVE) } }))
    plan = L.Plan(entry)
    G.combatAfter = 1
    G.calls = {}
    r = L.Load(entry, plan)
    check("combat at removal: stopped", r and r.failed ~= nil)
    eq("combat at removal: no ClearCursor", count("ClearCursor"), 0)
    eq("combat at removal: Cower kept on the cursor", G.cursor and G.cursor.item.spell, 1742)
    check("combat at removal: names the slot", tostring(r and r.failed):find("drop it into pet slot 7", 1, true) ~= nil,
          tostring(r and r.failed))
    check("combat at removal: backup pinned", A.Backups.Operation() ~= nil)
    eq("combat at removal: nothing blocked", #G.blocked, 0)

    -- A client that drops somewhere else: each op is read back, and the run
    -- stops at that op.
    saveBearA()
    hunter(bearB())
    plan = L.Plan(entry)
    G.afterPetCall = function(n) if n == 3 then G.pet.bar[2] = T(STAY) end end
    r = L.Load(entry, plan)
    eq("misplaced: stopped at the first op", r and r.at, "pet slot 1")
    eq("misplaced: no further calls", G.petCalls, 3)
    G.afterPetCall = nil
    -- A slot no op touches changes during the run: the final bar check.
    saveBearA()
    hunter(bearB())
    plan = L.Plan(entry)
    local last = 0
    for _, op in ipairs(plan.pet.ops) do last = last + (op.op == "swap" and 3 or op.op == "remove" and 1 or 2) end
    G.afterPetCall = function(n) if n == last then G.pet.bar[10] = T(STAY) end end
    r = L.Load(entry, plan)
    eq("final bar: checked", r and r.at, "pet slot 10")
    G.afterPetCall = nil
end

------------------------------------------------------------
-- Save: preserve intent, per family
------------------------------------------------------------
local function loadedB()
    saveBearA()
    hunter(bearB())
    assert(not L.Load(entry, L.Plan(entry)).failed)
end
do
    -- An edit on the pet bar is saved; the rest keeps the loadout's.
    loadedB()
    G.pet.bar[7] = S(1742)                    -- Cower into slot 7
    local m = assert(L.PlanSave())
    eq("save: edit saved", m.modules.pet[4].slots[7].id, 1742)
    eq("save: Growl keeps the loadout's rank", m.modules.pet[4].slots[4].id, 14916)
    eq("save: listed", m.pet.changed[1] and m.pet.changed[1].slot, 7)
    A._shown = nil
    A.Commands.save("")
    local t = table.concat(A._shown.lines, "\n")
    check("save preview: pet change", t:find("pet slot 7: empty -> Cower", 1, true) ~= nil, t)
    check("save preview: kept slot", t:find("pet slot 6: Bite (this pet doesn't have it)", 1, true) ~= nil, t)

    -- The gap Bite left: whatever is there now isn't saved over it.
    loadedB()
    G.pet.bar[6] = S(1742)
    m = assert(L.PlanSave())
    eq("gap: Bite kept", m.modules.pet[4].slots[6].id, 17253)
    eq("gap: still unavailable", m.advanced.pet[4].unavailable[6], "this pet doesn't have it")
    -- save drop: the gap goes, compared with what is there from now on.
    m = assert(L.PlanSave(true))
    eq("drop: slot emptied", m.modules.pet[4].slots[6], false)
    eq("drop: no longer unavailable", m.advanced.pet[4].unavailable, nil)

    -- A new rank of the same ability is no change (by name): the loadout's
    -- rank stays.
    loadedB()
    G.pet.book[#G.pet.book + 1] = { id = 14917, name = "Growl" }
    G.pet.bar[4] = S(14917)
    m = assert(L.PlanSave())
    check("rank: no-op", m.noop)
    eq("rank: the loadout's rank", m.modules.pet[4].slots[4].id, 14916)

    -- An entry saved before pet bars: the pet out's bar is added.
    loadedB()
    local rec = A.char.loaded.loadout
    rec.baseline.pet = nil
    m = assert(L.PlanSave())
    eq("old entry: bar added", m.modules.pet[4].slots[4].id, 2649)
    eq("old entry: says so", m.pet.added, "Bear")
    A._shown = nil
    A.Commands.save("")
    check("old entry: preview", table.concat(A._shown.lines, "\n"):find("Adds the Bear pet bar this loadout didn't have yet.", 1, true) ~= nil)

    -- Loaded by a build without pet bars (no comparison): B kept, noted.
    loadedB()
    rec = A.char.loaded.loadout
    rec.after.pet = nil
    G.pet.bar[7] = S(1742)
    m = assert(L.PlanSave())
    eq("no comparison: B kept", m.modules.pet[4].slots[7], false)
    local noted
    for _, n in ipairs(m.notes) do if n:find("load this loadout with a Bear out first", 1, true) then noted = true end end
    check("no comparison: noted", noted)

    -- Saved in another game language: kept as it is.
    loadedB()
    rec = A.char.loaded.loadout
    rec.baseline.pet[4].locale = "deDE"
    G.pet.bar[7] = S(1742)
    m = assert(L.PlanSave())
    eq("other language: kept", m.modules.pet[4].slots[7], false)

    -- The pet bar can't be read at Save: B kept, noted.
    loadedB()
    G.pet.bar[7] = S(1742)
    G.petReadFails = true
    m = assert(L.PlanSave())
    eq("unreadable: kept", m.modules.pet[4].slots[7], false)
    check("unreadable: noted", m.notes[#m.notes]:find("Couldn't read the pet bar", 1, true) ~= nil, m.notes[#m.notes])
    G.petReadFails = nil

    -- Another family out: the bear bar stays; the imp's is added.
    loadedB()
    G.pet = nil
    hunter({ family = 23, familyName = "Imp", name = "Geltog", guid = "Pet-0-I1",
             bar = { [1] = T(ATTACK), [4] = S(3110) }, book = { { id = 3110, name = "Firebolt" } } })
    m = assert(L.PlanSave())
    eq("imp: bear kept", m.modules.pet[4].slots[4].id, 14916)
    eq("imp: imp added", m.modules.pet[23].slots[4].id, 3110)
    -- No pet out at Save: nothing about pets changes.
    loadedB()
    G.pet = nil
    m = assert(L.PlanSave())
    check("no pet at save: no-op", m.noop)

    -- Save As from the loaded record keeps the bear bar's inherited intent.
    loadedB()
    G.pet.bar[6] = S(1742)
    local p = assert(L.PlanSaveAs())
    eq("save as: Bite kept", p.modules.pet[4].slots[6].id, 17253)
end

------------------------------------------------------------
-- Wire and schema
------------------------------------------------------------
do
    saveBearA()
    local enc = assert(A.Envelope.Encode(entry))
    local back = assert(A.Envelope.Decode(enc))
    eq("wire: the pet bar survives", back.modules.pet[4].slots[4].id, 14916)
    eq("wire: an empty slot stays false", back.modules.pet[4].slots[7], false)
    eq("schema 7", A.SCHEMA, 7)
end

finish("test_pet")
