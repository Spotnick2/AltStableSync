------------------------------------------------------------
-- test_roundtrip.lua - audit #95: the preview equals the apply, the
-- restore equals the state before
--
-- Deterministic round trips over the Forever-shaped stubs (wow_game.lua,
-- wow_ui.lua). Every row states its expected outcome BY HAND, never from
-- the plan: the state after the operation, item by item, and the state
-- after the restore against the one before, with the declared exceptions
-- (docs/AUDIT.md section 3) listed and nothing else. `observe()` is every
-- observable the addon can touch; `diff()` names each difference. The
-- mutation witnesses that keep these rows honest are in docs/AUDIT.md
-- section 4.
------------------------------------------------------------

dofile("tests/harness.lua")
dofile("tests/wow_stubs.lua")
dofile("tests/wow_game.lua")
dofile("tests/wow_ui.lua")

local G, UI = WoW.game, WoW.ui
local A, L, S, B

local function boot()
    WoW.reset()
    for _, f in ipairs({ "Core.lua", "Categories.lua", "Catalog.lua", "Game.lua", "Pet.lua", "Backups.lua",
                         "Ready.lua", "Loadout.lua", "DamageMeter.lua", "UISetup.lua", "Commands.lua" }) do
        assert(loadfile(f))("AltStableSync", {})
    end
    WoW.fire("ADDON_LOADED", "AltStableSync")
    A, L, S, B = AltStableSync, AltStableSync.Loadout, AltStableSync.UISetup, AltStableSync.Backups
    A.Preview = { Show = function(o) A._shown = o end, Hide = function() A._shown = nil end,
                  Shown = function() return A._shown end }
end
local function ready() WoW.fire("PLAYER_ENTERING_WORLD", true, false); WoW.clock = WoW.clock + 10 end

------------------------------------------------------------
-- Observing and comparing
------------------------------------------------------------

local function norm(b) return (tostring(b or ""):gsub("[\r\n]+$", "")) end

-- Every observable, flat: "slot N", "macro NAME (scope)", "key K", "saved K"
-- (the persisted set), "pet N", "autocast N", "layout", "bars", "cvar X",
-- "chat N", "meter N". Macro indices and the trailing newline are
-- representation and left out on purpose.
local function observe()
    local o = {}
    for _, slot in ipairs(A.Game.SLOT_LIST) do
        local a = G.actions[slot]
        if a then o["slot " .. slot] = a.kind == "macro" and ("macro " .. a.ref.name) or (a.kind .. " " .. tostring(a.id)) end
    end
    for _, list in ipairs({ { G.account, "account" }, { G.char, "char" } }) do
        for _, m in ipairs(list[1]) do
            o["macro " .. m.name .. " (" .. list[2] .. ")"] = norm(m.body) .. " | icon " .. tostring(m.icon)
        end
    end
    for k, c in pairs(G.keys) do o["key " .. k] = c end
    for k, c in pairs(G.savedKeys or {}) do o["saved " .. k] = c end
    if G.pet then
        for i = 1, 10 do
            local a = G.pet.bar[i]
            if a then
                o["pet " .. i] = a.token or ("spell " .. tostring(a.spell))
                if a.spell then o["autocast " .. i] = tostring(a.autocast or false) end
            end
        end
    end
    o["layout"] = tostring(UI.active)
    local bars = {}
    for i = 1, 7 do bars[i] = UI.bars[i] and "1" or "0" end
    o["bars"] = table.concat(bars)
    for k, v in pairs(UI.cvars or {}) do o["cvar " .. k] = v end
    for i = 1, 10 do
        local w = UI.windows[i]
        if w and (w.shown or w.docked) then
            local g = {}
            for _, x in ipairs(w.groups) do g[#g + 1] = x end
            table.sort(g)
            o["chat " .. i] = w.name .. ": " .. table.concat(g, ",")
        end
    end
    if UI.meter then
        for i = 1, 3 do
            local d = UI.meter[i]
            local w = d and d.sessionWindow
            if w then
                o["meter " .. i] = ("%s type %s session %s %s %d,%d %dx%d"):format(w.shown and "shown" or "hidden",
                    tostring(d.damageMeterType), tostring(d.sessionType), w.locked and "locked" or "unlocked",
                    w.x, w.y, w.width, w.height)
            end
        end
    end
    return o
end

local function diff(before, after)
    local keys, seen, out = {}, {}, {}
    for k in pairs(before) do seen[k] = true; keys[#keys + 1] = k end
    for k in pairs(after) do if not seen[k] then keys[#keys + 1] = k end end
    table.sort(keys)
    for _, k in ipairs(keys) do
        if before[k] ~= after[k] then out[#out + 1] = k .. ": " .. tostring(before[k]) .. " -> " .. tostring(after[k]) end
    end
    return out
end

-- The differences must be exactly `expected` (order-free).
local function exactly(name, expected, got)
    local e, g = {}, {}
    for _, x in ipairs(expected) do e[#e + 1] = x end
    for _, x in ipairs(got) do g[#g + 1] = x end
    table.sort(e); table.sort(g)
    eq(name, table.concat(g, "\n"), table.concat(e, "\n"))
end

local function text(lines) return table.concat(lines, "\n") end

-- Secondary check: every planned write has a preview line. It catches an
-- omission; it does not prove the planner right (the rows do that).
local function previewCovers(name, plan, lines)
    local t = text(lines)
    for _, op in ipairs(plan.actions) do
        local bar, button = A.Game.SlotLabel(op.slot)
        check(name .. ": slot " .. op.slot .. " in the preview",
              t:find(bar, 1, true) ~= nil and t:find(("button %d: "):format(button), 1, true) ~= nil, t)
    end
    for key in pairs(plan.keys) do check(name .. ": key " .. key .. " in the preview", t:find(key .. ": ", 1, true) ~= nil, t) end
    if #plan.creates > 0 then check(name .. ": creates in the preview", t:find("to create", 1, true) ~= nil, t) end
    if #(plan.edits or {}) > 0 then
        check(name .. ": edits in the preview", (t:find("to update", 1, true) or t:find("to put back", 1, true)) ~= nil, t)
    end
    for _, s in ipairs(plan.skips) do
        local _, button = A.Game.SlotLabel(s.slot)
        check(name .. ": skip " .. s.slot .. " in the preview", t:find(("button %d: left unchanged"):format(button), 1, true) ~= nil, t)
    end
    if #(plan.waiting or {}) > 0 then check(name .. ": waiting in the preview", t:find("Stays empty until", 1, true) ~= nil, t) end
    if next(plan.keys) or plan.resave then
        check(name .. ": the key save in the preview", t:find("keybindings are saved as they are now", 1, true) ~= nil, t)
    end
end

------------------------------------------------------------
-- The loadout rows: a priest alt and the loadout L
------------------------------------------------------------

local OLD, NEW = "/cast Heal", "/cast Heal\n/say healing"
local ICON, NEW_ICON = 134400, 135000
local QM = "INV_Misc_QuestionMark"
local SPELLS = {
    { id = 2061, name = "Flash Heal", sub = "Rank 1" },
    { id = 2050, name = "Lesser Heal", low = true, sub = "Rank 1" }, { id = 2052, name = "Lesser Heal", sub = "Rank 2" },
}

-- The alt: Heal (old text) in two covered slots and one outside the cover;
-- spells where L empties or overwrites; a flyout where L is empty; a
-- two-key command; a key on an unmanaged command.
local function alt(opts)
    opts = opts or {}
    G.setup{
        class = "PRIEST", guid = "Player-70-ALT", bindingSet = opts.bindingSet,
        spells = SPELLS,
        items = { [4540] = 5, [5512] = 0 },
        macros = { { name = "Heal", body = OLD, char = true, icon = ICON }, { name = "Acct", body = "/say hi" },
                   { name = "Zed", body = "/z", char = true } },
        actions = { [2] = { macro = "Heal" }, [5] = { macro = "Heal" }, [30] = { macro = "Heal" },
                    [6] = { spell = 2050 }, [7] = { spell = 2052 }, [8] = { spell = 2050 }, [10] = { flyout = 7 },
                    [16] = { spell = 2052 } },
        keys = { ["1"] = "ACTIONBUTTON2", ["2"] = "ACTIONBUTTON1", ["SHIFT-2"] = "ACTIONBUTTON1", ["Q"] = "JUMP" },
    }
    UI.setup(); UI.meter = nil
end

local function spell(id, name, policy, class) return { kind = "spell", id = id, name = name, policy = policy or "highest", class = class } end
local function cmacro(name) return { kind = "macro", name = name, scope = "char" } end

-- Loadout L, covering Action Bar 1's two pages and stance page 1.
local function loadout()
    return assert(A.Catalog.Create("loadout", { class = "PRIEST", category = "general", name = "L" }, {
        actions = {
            [1] = spell(9472, "Flash Heal", "highest", true),   -- the alt knows rank 1 only: places 2061
            [2] = cmacro("Heal"), [5] = cmacro("Heal"),         -- updated text and icon; also changes slot 30
            [3] = cmacro("Aegis"), [4] = cmacro("Bless"),       -- created; they sort before Heal and shift its index
            [6] = { kind = "item", id = 4540 },                  -- over a spell: an occupied slot overwritten
            -- [7] empty: the alt's spell there is emptied
            [8] = { kind = "item", id = 5512 },                  -- not in bags: the alt's spell there is emptied
            [9] = spell(2060, "Greater Heal", "highest", true),  -- not learned: stays empty
            -- [10] empty: the alt's flyout stays, listed
            [11] = { kind = "macro", name = "Acct", body = "/say hi", scope = "account" },
            [12] = spell(2050, "Lesser Heal", "exact"),
            [15] = spell(2052, "Lesser Heal", "exact"),          -- page 2
            [75] = spell(2050, "Lesser Heal", "exact"),          -- stance page 1
        },
        macros = { Heal = { body = NEW, icon = NEW_ICON }, Aegis = { body = "/cast Power Word: Shield" },
                   Bless = { body = "/cast Power Word: Fortitude" } },
        bindings = { ACTIONBUTTON1 = { "1" }, ACTIONBUTTON2 = { "2" }, ACTIONBUTTON3 = { "Q" } },
        cover = { { 1, 24 }, { 73, 84 } },
    }))
end

-- What the load changes, stated by hand.
local LOAD_DIFF = {
    "slot 1: nil -> spell 2061", "slot 3: nil -> macro Aegis", "slot 4: nil -> macro Bless",
    "slot 6: spell 2050 -> item 4540", "slot 7: spell 2052 -> nil", "slot 8: spell 2050 -> nil",
    "slot 11: nil -> macro Acct", "slot 12: nil -> spell 2050", "slot 15: nil -> spell 2052",
    "slot 16: spell 2052 -> nil", "slot 75: nil -> spell 2050",
    "macro Aegis (char): nil -> /cast Power Word: Shield | icon " .. QM,
    "macro Bless (char): nil -> /cast Power Word: Fortitude | icon " .. QM,
    "macro Heal (char): " .. OLD .. " | icon " .. ICON .. " -> " .. NEW .. " | icon " .. NEW_ICON,
    "key 1: ACTIONBUTTON2 -> ACTIONBUTTON1", "key 2: ACTIONBUTTON1 -> ACTIONBUTTON2",
    "key Q: JUMP -> ACTIONBUTTON3", "key SHIFT-2: ACTIONBUTTON1 -> nil",
    "saved 1: ACTIONBUTTON2 -> ACTIONBUTTON1", "saved 2: ACTIONBUTTON1 -> ACTIONBUTTON2",
    "saved Q: JUMP -> ACTIONBUTTON3", "saved SHIFT-2: ACTIONBUTTON1 -> nil",
}
-- What a restore knowingly leaves: the macros the load created (safety rule 5).
local KEPT = {
    "macro Aegis (char): nil -> /cast Power Word: Shield | icon " .. QM,
    "macro Bless (char): nil -> /cast Power Word: Fortitude | icon " .. QM,
}

-- R1: the main row. Load on a Character-bindings alt, then Restore 1.
do
    boot(); ready(); alt()
    local S0 = observe()
    local e = loadout()
    local plan = L.Plan(e)
    eq("R1: not blocked", plan.blocked, nil)
    eq("R1: 11 slots change", #plan.actions, 11)
    eq("R1: 4 keys change", (function() local n = 0 for _ in pairs(plan.keys) do n = n + 1 end return n end)(), 4)
    eq("R1: 2 creates", #plan.creates, 2)
    eq("R1: 1 update", #plan.edits, 1)
    eq("R1: the flyout slot listed", plan.skips[1] and plan.skips[1].slot, 10)
    eq("R1: the unlearned spell waits", plan.waiting[1] and plan.waiting[1].slot, 9)
    local lines = A.Commands.Describe(plan)
    previewCovers("R1 preview", plan, lines)
    check("R1 preview: slot 7 emptied is shown as -> empty", text(lines):find("button 7: Lesser Heal -> empty", 1, true) ~= nil, text(lines))
    check("R1 preview: slot 8 names the loadout's item and why", text(lines):find("(item 5512: not in bags)", 1, true) ~= nil, text(lines))
    check("R1 preview: the update names the macro", text(lines):find("Heal: text changes, icon changes", 1, true) ~= nil, text(lines))
    eq("R1 preview: wrote nothing", #G.calls, 0)

    local r = L.Load(e, plan)
    check("R1: loaded", r and not r.failed, r and r.failed)
    eq("R1: counted", (r.changed or 0) .. "/" .. (r.created or 0) .. "/" .. (r.edited or 0) .. "/" .. (r.keys or 0), "11/2/1/4")
    exactly("R1: the load changed exactly what the row says", LOAD_DIFF, diff(S0, observe()))
    eq("R1: cursor empty", G.cursor, nil)
    eq("R1: nothing attempted in combat", #G.blocked, 0)
    eq("R1: slot 30 (outside the cover) shows the updated macro too", norm(G.actions[30].ref.body), norm(NEW))
    local S1 = observe()

    local rp = L.PlanRestore(1)
    local rl = text(A.Commands.Describe(rp))
    check("R1 restore preview: kept macros named", rl:find("Kept: 2 macros that load created (not deleted): Aegis, Bless.", 1, true) ~= nil, rl)
    check("R1 restore preview: puts the macro back", rl:find("1 macro to put back", 1, true) ~= nil, rl)
    previewCovers("R1 restore preview", rp, A.Commands.Describe(rp))
    local rr = L.Restore(1, rp)
    check("R1: restored, complete", rr and not rr.failed and not rr.partial, rr and (rr.failed or "partial"))
    exactly("R1: back to before, except the kept macros", KEPT, diff(S0, observe()))
    eq("R1: Save has no comparison after a restore", A.char.loaded.loadout.after, nil)
    eq("R1: the restore's own backup is ring 1", #(select(1, B.List())), 2)

    -- Undo the restore: back to the loaded state.
    local r2 = L.Restore(1, L.PlanRestore(1))
    check("R1: restore of the restore completes", r2 and not r2.failed and not r2.partial)
    exactly("R1: back to the loaded state", {}, diff(S1, observe()))
end

-- R2: the same load from Account bindings is blocked as a whole: zero
-- writes, the #7 switch offered, no backup.
do
    boot(); ready(); alt({ bindingSet = 1 })
    local S0 = observe()
    local e = loadout()
    local plan = L.Plan(e)
    check("R2: blocked", plan.blocked ~= nil and plan.blocked:find("character-specific keybindings", 1, true) ~= nil, plan.blocked)
    check("R2: the switch is offered", plan.needsCharacterBindings == true)
    eq("R2: no actions planned", #plan.actions, 0)
    local r, err = L.Load(e, plan)
    eq("R2: refused", r, nil)
    exactly("R2: nothing changed", {}, diff(S0, observe()))
    eq("R2: no writes", #G.calls, 0)
    eq("R2: no backup", #(select(1, B.List())), 0)
end

-- R3: a backup made under Character bindings, restored under Account: the
-- actions come back, the key part is blocked and said, the result is
-- partial, and no key (in memory or saved) changes.
do
    boot(); ready(); alt()
    local S0 = observe()
    local e = loadout()
    L.Load(e, L.Plan(e))
    local S1 = observe()
    G.bindingSet = 1
    local plan = L.PlanRestore(1)
    check("R3: keys blocked", plan.keysBlocked ~= nil)
    check("R3: said", text(A.Commands.Describe(plan)):find("Bindings: not changed.", 1, true) ~= nil)
    local r = L.Restore(1, plan)
    check("R3: partial", r and not r.failed and r.partial == true, r and r.failed)
    local expected = {}
    for _, d in ipairs(LOAD_DIFF) do
        if not d:find("^key ") and not d:find("^saved ") and not d:find("^macro Aegis") and not d:find("^macro Bless") then
            -- the load's change, reversed
            local k, a, b = d:match("^(.-): (.-) %-> (.*)$")
            expected[#expected + 1] = k .. ": " .. b .. " -> " .. a
        end
    end
    exactly("R3: actions and the macro back, keys untouched", expected, diff(S1, observe()))
end

-- R4: another addon set a key with SetBinding and never saved it. Our save
-- persists it too (declared, D3): the preview says so, the saved set holds
-- it afterwards, and the backup can't undo it.
do
    boot(); ready(); alt()
    G.keys["F"] = "JUMP"                               -- in memory, not in G.savedKeys
    local S0 = observe()
    local e = loadout()
    local plan = L.Plan(e)
    check("R4: the preview says every change in memory is saved",
          text(A.Commands.Describe(plan)):find("including any changes not saved yet", 1, true) ~= nil)
    L.Load(e, plan)
    eq("R4: the other addon's key is now saved", G.savedKeys["F"], "JUMP")
    eq("R4: the backup holds only the planned keys", B.Get(1).keys["F"], nil)
    L.Restore(1, L.PlanRestore(1))
    local expected = { "saved F: nil -> JUMP" }
    for _, k in ipairs(KEPT) do expected[#expected + 1] = k end
    exactly("R4: back to before, except the kept macros and the now-saved key", expected, diff(S0, observe()))
end

-- R5: faults during the load. Combat after the k-th mutating call, for
-- every k: the load stops, nothing is attempted in combat, and "restore op"
-- returns to the state before except the macros created so far (named as
-- kept). Then the macro faults and a refused SaveBindings.
do
    boot(); ready(); alt()
    L.Load(loadout(), L.Plan(A.Catalog.ListAll("loadout", "PRIEST")[1]))
    local N = #G.calls
    check("R5: a full load makes more than 20 calls", N > 20, N)
    local stopped = 0
    for k = 1, N - 1 do
        boot(); ready(); alt()
        local S0 = observe()
        local e = loadout()
        G.combatAfter = k
        local r = L.Load(e, L.Plan(e))
        G.combat, G.combatAfter = false, nil
        if r and r.failed then
            stopped = stopped + 1
            local tag = ("R5 k=%d"):format(k)
            eq(tag .. ": nothing attempted in combat", #G.blocked, 0)
            eq(tag .. ": cursor empty", G.cursor, nil)
            check(tag .. ": pinned", B.Operation() ~= nil)
            local created, n = {}, 0
            for _, c in ipairs(G.calls) do if c == "CreateMacro" then n = n + 1 end end
            if n >= 1 then created[#created + 1] = KEPT[1] end
            if n >= 2 then created[#created + 1] = KEPT[2] end
            local plan = L.PlanRestore("op")
            eq(tag .. ": the kept list matches the creations", #plan.kept, n)
            local rr = L.Restore("op", plan)
            check(tag .. ": restore op complete", rr and not rr.failed and not rr.partial, rr and (rr.failed or "partial"))
            exactly(tag .. ": back to before, except the kept macros", created, diff(S0, observe()))
            check(tag .. ": pin released", B.Operation() == nil and A.char.interrupted == nil)
        end
    end
    check("R5: the sweep stopped loads", stopped >= N - 2, stopped)

    -- CreateMacro writes another body: the load stops, the macro is kept
    -- and named, everything else comes back.
    boot(); ready(); alt()
    local S0 = observe()
    local e = loadout()
    G.createFault = "wrong"
    local r = L.Load(e, L.Plan(e))
    eq("R5 create wrong: stopped", r and r.failed, "macro created with other text")
    local plan = L.PlanRestore("op")
    check("R5 create wrong: named as kept", text(A.Commands.Describe(plan)):find("(not deleted): Aegis.", 1, true) ~= nil)
    local rr = L.Restore("op", plan)
    check("R5 create wrong: restore op complete", rr and not rr.failed and not rr.partial)
    exactly("R5 create wrong: back to before, except that macro", { "macro Aegis (char): nil -> /cast Power Word: Shield -- something else | icon " .. QM }, diff(S0, observe()))

    -- EditMacro writes another body: the load stops; the macro matches
    -- neither before nor after, so the restore leaves it, says so, and
    -- stays partial with the pin kept.
    boot(); ready(); alt()
    S0 = observe()
    e = loadout()
    G.macroFault = "wrong"
    r = L.Load(e, L.Plan(e))
    eq("R5 edit wrong: stopped", r and r.failed, "macro not updated")
    plan = L.PlanRestore("op")
    check("R5 edit wrong: the macro is named as left", text(A.Commands.Describe(plan)):find("macro Heal: changed since the load, left as is", 1, true) ~= nil, text(A.Commands.Describe(plan)))
    rr = L.Restore("op", plan)
    check("R5 edit wrong: partial, pin kept", rr and rr.partial and B.Operation() ~= nil)
    exactly("R5 edit wrong: back to before, except the two created and the odd macro", {
        KEPT[1], KEPT[2],
        "macro Heal (char): " .. OLD .. " | icon " .. ICON .. " -> " .. NEW .. " -- something else | icon " .. NEW_ICON,
    }, diff(S0, observe()))

    -- SaveBindings refuses: the planned keys roll back in memory, the saved
    -- set is untouched, restore op returns everything else.
    boot(); ready(); alt()
    S0 = observe()
    e = loadout()
    G.bindFault = { SaveBindings2 = "false" }
    r = L.Load(e, L.Plan(e))
    G.bindFault = nil
    check("R5 save refused: stopped at the bindings", r and r.failed and r.at == "bindings", r and r.failed)
    for _, k in ipairs({ "1", "2", "SHIFT-2", "Q" }) do eq("R5 save refused: key " .. k .. " back in memory", G.keys[k], S0["key " .. k]) end
    rr = L.Restore("op", L.PlanRestore("op"))
    check("R5 save refused: restore op complete", rr and not rr.failed and not rr.partial)
    exactly("R5 save refused: back to before, except the kept macros", KEPT, diff(S0, observe()))
end

-- R6: a fault during the restore itself. Its own backup is ring 1, and
-- restoring that returns to the loaded state.
do
    boot(); ready(); alt()
    local e = loadout()
    L.Load(e, L.Plan(e))
    local S1 = observe()
    G.combatAfter = 4
    local r = L.Restore(1, L.PlanRestore(1))
    G.combat, G.combatAfter = false, nil
    check("R6: the restore stopped", r and r.failed ~= nil)
    eq("R6: nothing attempted in combat", #G.blocked, 0)
    eq("R6: cursor empty", G.cursor, nil)
    check("R6: no pin (a restore never pins)", B.Operation() == nil)
    local rr = L.Restore(1, L.PlanRestore(1))
    check("R6: undoing the stopped restore completes", rr and not rr.failed and not rr.partial)
    exactly("R6: back to the loaded state", {}, diff(S1, observe()))
end

-- R7: the pet bar. A bear's layout saved on one hunter, loaded on another
-- hunter's bear, restored exactly; autocast never written.
do
    local T = function(t) return { token = t } end
    local SP = function(id, auto) return { spell = id, autocast = auto } end
    boot()
    G.setup{ class = "HUNTER", guid = "Player-70-HUNT", spells = { { id = 75, name = "Auto Shot" } }, keys = {},
             pet = { name = "Tarthosuk", guid = "Pet-0-A1",
                     bar = { [1] = T("PET_ACTION_ATTACK"), [2] = T("PET_ACTION_FOLLOW"), [3] = T("PET_ACTION_MOVE_TO"),
                             [4] = SP(14916), [5] = SP(16827), [6] = SP(17253),
                             [8] = T("PET_MODE_ASSIST"), [9] = T("PET_MODE_DEFENSIVEASSIST"), [10] = T("PET_MODE_PASSIVE") },
                     book = { { name = "Aggressive" }, { id = 17253, name = "Bite" }, { id = 16827, name = "Claw" },
                              { id = 14916, name = "Growl" } } } }
    UI.setup(); UI.meter = nil
    ready()
    local e = assert(L.SaveAs(assert(L.PlanSaveAs()), "Bears"))
    G.setup{ class = "HUNTER", guid = "Player-70-HUNT2", spells = { { id = 75, name = "Auto Shot" } }, keys = {},
             pet = { name = "Tarthosuk", guid = "Pet-0-B1",
                     bar = { [1] = T("PET_ACTION_FOLLOW"), [2] = T("PET_ACTION_ATTACK"), [3] = T("PET_ACTION_MOVE_TO"),
                             [4] = SP(1082, true), [6] = SP(2649, false), [7] = SP(1742, true),
                             [8] = T("PET_MODE_ASSIST"), [9] = T("PET_MODE_DEFENSIVEASSIST"), [10] = T("PET_MODE_PASSIVE") },
                     book = { { name = "Aggressive" }, { id = 1082, name = "Claw" }, { id = 1742, name = "Cower" }, { id = 2649, name = "Growl" } } } }
    UI.setup(); UI.meter = nil
    local S0 = observe()
    local plan = L.Plan(e)
    eq("R7: not blocked", plan.blocked, nil)
    check("R7: pet ops planned", plan.pet and #plan.pet.ops > 0)
    local r = L.Load(e, plan)
    check("R7: loaded", r and not r.failed, r and r.failed)
    -- Stated by hand: Attack and Follow swap back to A's order; Claw and
    -- Growl move to A's slots (4: Growl, 5: Claw); Cower (not in A) is
    -- removed; Bite isn't in B's book, so slot 6 stays empty.
    exactly("R7: the pet bar changed exactly so", {
        "pet 1: PET_ACTION_FOLLOW -> PET_ACTION_ATTACK", "pet 2: PET_ACTION_ATTACK -> PET_ACTION_FOLLOW",
        "pet 4: spell 1082 -> spell 2649", "autocast 4: true -> false",
        "pet 5: nil -> spell 1082", "autocast 5: nil -> true",
        "pet 6: spell 2649 -> nil", "autocast 6: false -> nil",
        "pet 7: spell 1742 -> nil", "autocast 7: true -> nil",
    }, (function()
        local d = diff(S0, observe())
        -- autocast travels with its ability in the stub, as in the client
        -- (measured: the spellbook keeps it); it is never written by us.
        return d
    end)())
    eq("R7: no autocast call", (function() for _, c in ipairs(G.calls) do if c:find("Autocast") then return c end end return "none" end)(), "none")
    local rr = L.Restore(1, L.PlanRestore(1))
    check("R7: restored, complete", rr and not rr.failed and not rr.partial, rr and (rr.failed or "partial"))
    exactly("R7: the bar is back exactly", {}, diff(S0, observe()))
end

-- R8: a UI setup. Layout, bars, an account CVar, a group added to General,
-- a new tab, the meter: window 1 changed and window 2 created. Then the
-- restore, on a Mainline-shaped client and on Forever's surface.
local function templateUI()
    UI.setup{
        active = 4, bars = { true, true, true, true, false, false, false },
        cvars = { damageMeterEnabled = "1", damageMeterResetOnNewInstance = "1", raidFramesDisplayClassColor = "1",
                  raidFramesDisplayPowerBars = "1", raidFramesHealthBarColorBG = "ff141414", enableMouseoverCast = "1" },
        cvarInfo = { damageMeterEnabled = { account = true } },
        windows = {
            [1] = { name = "General", shown = true, docked = true, uninteractable = false,
                    groups = { "SAY", "EMOTE", "YELL", "GUILD", "PARTY", "WHISPER", "BN_WHISPER", "SYSTEM", "CHANNEL", "COMBAT_XP_GAIN" } },
            [4] = { name = "Whispers", shown = false, docked = true, uninteractable = false, groups = { "WHISPER", "BN_WHISPER" } },
        },
    }
end
local function uiRow(forever)
    boot()
    G.setup{ class = "MAGE", guid = "Player-70-TEMPLATE", spells = { { id = 133, name = "Fireball" } } }
    templateUI()
    UI.meterSetup{ forever = forever, [1] = { damageMeterType = 0, sessionType = 1, locked = true },
                   [2] = { damageMeterType = 2, sessionType = 1, locked = true } }
    UI.meter[2].sessionWindow.x, UI.meter[2].sessionWindow.y = 300, 400
    ready()
    local p = S.PlanSaveAs()
    local e = assert(S.SaveAs(p, "Base"))
    -- The new character: default UI, meter window 1 only.
    G.setup{ class = "MAGE", guid = "Player-70-NEW", spells = { { id = 133, name = "Fireball" } } }
    UI.setup{ cvarInfo = { damageMeterEnabled = { account = true } } }
    UI.meterSetup{ forever = forever }
    return e
end
do
    local e = uiRow(false)
    local S0 = observe()
    local plan = S.Plan(e)
    eq("R8: not blocked", plan.blocked, nil)
    local lines = text(S.Describe(plan))
    check("R8 preview: the account CVar says so", lines:find("Damage meter: off -> on (affects this WoW account)", 1, true) ~= nil, lines)
    check("R8 preview: the new tab", lines:find('New chat tab "Whispers": WHISPER, BN_WHISPER', 1, true) ~= nil, lines)
    check("R8 preview: the meter window 2", lines:find("Show/configure window 2", 1, true) ~= nil, lines)
    check("R8 preview: no undo warning on a client with the placement flag", lines:find("can't be hidden again", 1, true) == nil, lines)
    eq("R8 preview: wrote nothing", #UI.calls, 0)
    local r = S.Apply(e, plan)
    check("R8: applied", r and not r.failed, r and r.failed)
    exactly("R8: the apply changed exactly what the row says", {
        "layout: 1 -> 4", "bars: 0000000 -> 1111000",
        "cvar damageMeterEnabled: 0 -> 1", "cvar damageMeterResetOnNewInstance: 0 -> 1", "cvar raidFramesDisplayClassColor: 0 -> 1",
        "cvar raidFramesDisplayPowerBars: 0 -> 1", "cvar raidFramesHealthBarColorBG: ff333333 -> ff141414",
        "chat 1: General: BN_WHISPER,CHANNEL,EMOTE,GUILD,PARTY,SAY,SYSTEM,WHISPER,YELL -> General: BN_WHISPER,CHANNEL,COMBAT_XP_GAIN,EMOTE,GUILD,PARTY,SAY,SYSTEM,WHISPER,YELL",
        "chat 4: nil -> Whispers: BN_WHISPER,WHISPER",
        "meter 1: shown type 0 session 0 unlocked 100,500 400x200 -> shown type 0 session 1 locked 100,500 400x200",
        "meter 2: nil -> shown type 2 session 1 locked 300,400 400x200",
    }, diff(S0, observe()))
    eq("R8: nothing attempted in combat", #G.blocked, 0)
    local S1 = observe()
    local rp = S.PlanRestore(1)
    local rl = text(S.Describe(rp))
    check("R8 restore preview: the tab is kept", rl:find('Chat tab "Whispers" is kept', 1, true) ~= nil, rl)
    check("R8 restore preview: removes the group", rl:find("Main chat window: remove COMBAT_XP_GAIN", 1, true) ~= nil, rl)
    local rr = S.Restore(1, rp)
    check("R8: restored, complete", rr and not rr.failed and not rr.partial, rr and (rr.failed or "partial"))
    exactly("R8: back to before, except the kept tab and the (hidden) window 2 frame", {
        "chat 4: nil -> Whispers: BN_WHISPER,WHISPER",
        "meter 2: nil -> hidden type 2 session 1 locked 300,400 400x200",
    }, diff(S0, observe()))
    check("R8: Save refused after the restore", AltStableSyncChar.loaded.ui.restored == true)
    local r2 = S.Restore(1, S.PlanRestore(1))
    check("R8: undo of the restore completes", r2 and not r2.failed and not r2.partial, r2 and (r2.failed or "partial"))
    exactly("R8: back to the applied state", {}, diff(S1, observe()))

    -- A layout deleted between preview and confirm: refused, nothing written.
    e = uiRow(false)
    S0 = observe()
    plan = S.Plan(e)
    UI.layouts = {}
    local r3, err = S.Apply(e, plan)
    eq("R8 layout gone: refused", r3, nil)
    check("R8 layout gone: said", tostring(err):find("changed since the preview", 1, true) ~= nil, err)
    exactly("R8 layout gone: nothing changed", {}, diff(S0, observe()))

    -- Forever's surface (no IsUserPlaced): the apply says the meter can't be
    -- undone; the restore leaves the whole meter part as applied (D6).
    e = uiRow(true)
    S0 = observe()
    plan = S.Plan(e)
    check("R8 forever preview: says the restore leaves the meter as set", text(S.Describe(plan)):find("can't be hidden again", 1, true) ~= nil)
    r = S.Apply(e, plan)
    check("R8 forever: applied", r and not r.failed, r and r.failed)
    rp = S.PlanRestore(1)
    check("R8 forever restore preview: the meter can't be restored", text(S.Describe(rp)):find("Damage meter: window placement flag cannot be backed up for undo", 1, true) ~= nil, text(S.Describe(rp)))
    rr = S.Restore(1, rp)
    check("R8 forever: partial", rr and not rr.failed and rr.partial == true)
    exactly("R8 forever: back to before, except the kept tab and the whole meter part", {
        "chat 4: nil -> Whispers: BN_WHISPER,WHISPER",
        "meter 1: shown type 0 session 0 unlocked 100,500 400x200 -> shown type 0 session 1 locked 100,500 400x200",
        "meter 2: nil -> shown type 2 session 1 locked 300,400 400x200",
    }, diff(S0, observe()))
end

-- R9: the store through SavedVariables (identity lost, contents kept): the
-- journals survive, "first" and "1" both restore and name the kept macros.
local function ser(v)
    local t = type(v)
    if t == "string" then return ("%q"):format(v) end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t ~= "table" then return "nil" end
    local keys = {}
    for k in pairs(v) do if type(v[k]) ~= "function" then keys[#keys + 1] = k end end
    table.sort(keys, function(a, b) if type(a) ~= type(b) then return type(a) < type(b) end return a < b end)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = "[" .. ser(k) .. "]=" .. ser(v[k]) end
    return "{" .. table.concat(out, ",") .. "}"
end
do
    boot(); ready(); alt()
    local S0 = observe()
    local e = loadout()
    L.Load(e, L.Plan(e))
    local reloaded = assert(loadstring("return " .. ser(AltStableSyncDB)))()
    A.db, AltStableSyncDB = reloaded, reloaded
    for _, which in ipairs({ "first", 1 }) do
        local plan = L.PlanRestore(which)
        eq("R9 " .. tostring(which) .. ": kept macros survive the reload", #plan.kept, 2)
        check("R9 " .. tostring(which) .. ": named", text(A.Commands.Describe(plan)):find("Aegis, Bless", 1, true) ~= nil)
    end
    local rr = L.Restore("first", L.PlanRestore("first"))
    check("R9: restore first completes", rr and not rr.failed and not rr.partial, rr and (rr.failed or "partial"))
    exactly("R9: back to before, except the kept macros", KEPT, diff(S0, observe()))
end

finish("test_roundtrip")
