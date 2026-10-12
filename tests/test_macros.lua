------------------------------------------------------------
-- test_macros.lua - #6: character macros travel with a loadout
--
-- A Load updates a single character macro of the loadout's name whose text
-- or icon differs (previewed, backed up, read back); Restore puts it back;
-- "Include character macros" leaves them out. Account macros are never
-- written: the stub's EditMacro raises on an account index. Against the
-- Forever-shaped model in tests/wow_game.lua (macros sorted by name, so a
-- creation shifts indices). EditMacro's client behaviour is measured with
-- /syncprobe macroedit (docs/forever-api-notes.md).
------------------------------------------------------------

dofile("tests/harness.lua")
dofile("tests/wow_stubs.lua")
dofile("tests/wow_game.lua")

local G = WoW.game
local A, L

local function boot()
    WoW.reset()
    for _, f in ipairs({ "Core.lua", "Categories.lua", "Catalog.lua", "Game.lua", "Pet.lua", "Backups.lua",
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

local OLD, NEW = "/cast Heal", "/cast Heal\n/say healing"
local ICON, NEW_ICON = 134400, 135000
local SPELLS = { { id = 2061, name = "Flash Heal" }, { id = 2050, name = "Lesser Heal" } }

local function heal(body) return { kind = "macro", name = "Heal", scope = "char", body = body or NEW } end

-- A loadout over Action Bar 1 only: slot 4 holds Heal (and whatever `extra`
-- adds); `macros` the definitions (default: Heal with the new text and icon).
local function loadout(actions, macros)
    local a = actions or { [4] = heal() }
    return assert(A.Catalog.Create("loadout", { class = "PRIEST", category = "general",
        name = "L" .. tostring(math.random(1, 1e9)) },
        { actions = a, macros = macros or { Heal = { body = NEW, icon = NEW_ICON } }, cover = { { 1, 12 } } }))
end

-- This character: Heal (old text) on slot 4 and on slot 20, outside the
-- loadout's cover; an account macro; a spell on slot 6.
local function char(opts)
    opts = opts or {}
    G.setup{
        class = "PRIEST", guid = "Player-70-ALT", spells = SPELLS,
        macros = opts.macros or { { name = "Heal", body = OLD, char = true, icon = ICON },
                                  { name = "Acct", body = "/say hi" } },
        actions = opts.actions or { [4] = { macro = "Heal" }, [20] = { macro = "Heal" }, [6] = { spell = 2050 } },
        keys = {},
    }
end

local function macro(name)
    local m = A.Game.MacrosNamed(name)
    return m and #m == 1 and m[1] or nil
end
local function calls(name)
    local n = 0
    for _, c in ipairs(G.calls) do if c == name then n = n + 1 end end
    return n
end
local function text(lines) return table.concat(lines, "\n") end
local function has(s, sub) return s:find(sub, 1, true) ~= nil end
local function chat(sub)
    for _, l in ipairs(WoW.chat()) do if has(l, sub) then return true end end
    return false
end

------------------------------------------------------------
-- The update: planned, previewed, applied, read back, backed up
------------------------------------------------------------
do
    boot(); char()
    local e = loadout()
    local plan = L.Plan(e)
    eq("update: not blocked", plan.blocked, nil)
    eq("update: one edit", #plan.edits, 1)
    eq("update: from the old text", plan.edits[1] and plan.edits[1].from.body, OLD)
    eq("update: to the loadout's", plan.edits[1] and plan.edits[1].to.body, NEW)
    eq("update: the loadout's icon", plan.edits[1] and plan.edits[1].to.icon, NEW_ICON)
    eq("update: nothing created", #plan.creates, 0)
    -- Slot 4 already holds Heal: after the update it is the loadout's, so no
    -- action op (only the covered slot 6 is emptied: the loadout has nothing there).
    local slots = {}
    for _, op in ipairs(plan.actions) do slots[#slots + 1] = op.slot end
    eq("update: no op on the slot that holds the macro", table.concat(slots, ","), "6")
    eq("update: planning wrote nothing", #G.calls, 0)

    local t = text(A.Commands.Describe(plan))
    check("preview: counts the update", has(t, "Character macros: 1 macro to update (account macros stay untouched)."), t)
    check("preview: says what changes", has(t, "  Heal: text changes, icon changes"), t)
    check("preview: the first differing line", has(t, "    line 2: (no line) -> /say healing"), t)
    check("preview: every button that uses it", has(t, "An updated macro changes every button that uses it, on any bar."), t)

    local r = L.Load(e, plan)
    check("update: loaded", r and not r.failed, r and r.failed)
    eq("update: counted", r and r.edited, 1)
    eq("update: one EditMacro", calls("EditMacro"), 1)
    eq("update: new text", macro("Heal") and macro("Heal").body, NEW)
    eq("update: new icon", macro("Heal") and macro("Heal").icon, NEW_ICON)
    eq("update: still one Heal", #A.Game.MacrosNamed("Heal"), 1)
    eq("update: slot 4 still Heal", G.actions[4] and G.actions[4].ref.name, "Heal")
    eq("update: uncovered slot 20 shows the new text", A.Game.ActionAt(20).body, NEW)
    eq("update: account macro untouched", A.Game.MacrosNamed("Acct")[1].body, "/say hi")
    eq("update: cursor empty", G.cursor, nil)
    local snap = A.Backups.Get("1")
    eq("update: backup holds the old text", snap.editedMacros and snap.editedMacros[1].before.body, OLD)
    eq("update: and the old icon", snap.editedMacros and snap.editedMacros[1].before.icon, ICON)
    eq("update: and what the load left", snap.editedMacros and snap.editedMacros[1].after.body, NEW)

    -- Loading again: nothing to do (the server newline after a full exit is
    -- not a change, A17).
    WoW.relaunch(); WoW.fire("PLAYER_ENTERING_WORLD", true, false); WoW.clock = WoW.clock + 10
    local again = L.Plan(e)
    check("update: again is a no-op", again.noop, again.fingerprint)
    eq("update: again no edit", #again.edits, 0)

    -- Restore: the macro back as it was, the restore's own backup holds the
    -- reverse, and restoring that puts the load's version back.
    G.calls = {}
    local rp = L.PlanRestore("1")
    eq("restore: one revert", #rp.edits, 1)
    local rslots = {}
    for _, op in ipairs(rp.actions) do rslots[#rslots + 1] = op.slot end
    eq("restore: slot 4 needs no op (the revert puts it back)", table.concat(rslots, ","), "6")
    eq("restore: back to the old text", rp.edits[1] and rp.edits[1].to.body, OLD)
    local rt = text(A.Commands.Describe(rp))
    check("restore preview: put back", has(rt, "Character macros: 1 macro to put back"), rt)
    local rr = L.Restore("1", rp)
    check("restore: done", rr and not rr.failed and not rr.partial, rr and (rr.failed or "partial"))
    eq("restore: counted", rr and rr.edited, 1)
    eq("restore: old text", A.Game.Normalize(macro("Heal").body), OLD)
    eq("restore: old icon", macro("Heal").icon, ICON)
    eq("restore: slot 20 too", A.Game.Normalize(A.Game.ActionAt(20).body), OLD)
    eq("restore: slot 6 back", G.actions[6] and G.actions[6].id, 2050)
    local rsnap = A.Backups.Get("1")
    eq("restore: its backup holds the reverse", rsnap.editedMacros and rsnap.editedMacros[1].after.body, OLD)
    local rp2 = L.PlanRestore("1")
    local rr2 = L.Restore("1", rp2)
    check("restore of the restore: done", rr2 and not rr2.failed and not rr2.partial)
    eq("restore of the restore: the load's text", A.Game.Normalize(macro("Heal").body), NEW)
    eq("restore of the restore: the load's icon", macro("Heal").icon, NEW_ICON)
end

------------------------------------------------------------
-- Report and the full preview path (Commands)
------------------------------------------------------------
do
    boot(); char()
    local e = loadout()
    A.Commands.LoadEntry(e)
    check("command: preview shown", A._shown ~= nil)
    eq("command: the tick box", A._shown and A._shown.check and A._shown.check.text, "Include character macros")
    eq("command: ticked by default", A._shown and A._shown.check and A._shown.check.checked, true)
    A._shown.onConfirm()
    check("report: counts the update", chat("1 macro updated"), table.concat(WoW.chat(), " / "))
end

-- A damaged cover blocks the plan; the preview still shows that refusal,
-- with no tick box and nothing written (Codex on #56).
for _, bad in ipairs({ { "missing", nil }, { "malformed", { { "x" } } }, { "not a table", 7 } }) do
    boot(); char()
    local e = loadout()
    e.modules.cover = bad[2]
    A._shown = nil
    local ok, err = pcall(A.Commands.LoadEntry, e)
    check("damaged cover (" .. bad[1] .. "): no error", ok, err)
    check("damaged cover (" .. bad[1] .. "): preview shown", A._shown ~= nil)
    check("damaged cover (" .. bad[1] .. "): says damaged",
        A._shown and has(text(A._shown.lines), "This loadout is damaged"), A._shown and text(A._shown.lines))
    check("damaged cover (" .. bad[1] .. "): no Load button", A._shown and A._shown.confirm == false)
    check("damaged cover (" .. bad[1] .. "): no tick box", A._shown and A._shown.check == nil)
    eq("damaged cover (" .. bad[1] .. "): no EditMacro", calls("EditMacro"), 0)
end

------------------------------------------------------------
-- Icon only; no icon in the definition; nothing to update
------------------------------------------------------------
do
    boot(); char()
    local e = loadout({ [4] = heal(OLD) }, { Heal = { body = OLD, icon = NEW_ICON } })
    local plan = L.Plan(e)
    eq("icon only: one edit", #plan.edits, 1)
    check("icon only: not a no-op", not plan.noop)
    check("icon only: preview", has(text(A.Commands.Describe(plan)), "  Heal: icon changes"))
    local r = L.Load(e, plan)
    check("icon only: loaded", r and not r.failed, r and r.failed)
    eq("icon only: icon set", macro("Heal").icon, NEW_ICON)
    eq("icon only: text kept", macro("Heal").body, OLD)

    -- No icon in the definition (an older capture): the macro keeps its own,
    -- and the records hold that real icon, so restore compares like with like.
    boot(); char()
    e = loadout(nil, { Heal = { body = NEW } })
    plan = L.Plan(e)
    eq("no icon: one edit", #plan.edits, 1)
    eq("no icon: keeps the current icon", plan.edits[1] and plan.edits[1].to.icon, ICON)
    check("no icon: preview says text only", has(text(A.Commands.Describe(plan)), "  Heal: text changes\n"))
    r = L.Load(e, plan)
    eq("no icon: icon kept", macro("Heal").icon, ICON)
    local rr = L.Restore("1", L.PlanRestore("1"))
    check("no icon: restore done", rr and not rr.failed and not rr.partial)
    eq("no icon: restored text", A.Game.Normalize(macro("Heal").body), OLD)
    rr = L.Restore("1", L.PlanRestore("1"))
    check("no icon: restore of the restore done", rr and not rr.failed and not rr.partial)
    eq("no icon: the load's text again", A.Game.Normalize(macro("Heal").body), NEW)

    -- Same text and icon: reused, no edit.
    boot(); char()
    e = loadout({ [4] = heal(OLD) }, { Heal = { body = OLD .. "\n", icon = ICON } })
    plan = L.Plan(e)
    eq("same: no edit", #plan.edits, 0)
    eq("same: no op on slot 4", (function() for _, op in ipairs(plan.actions) do if op.slot == 4 then return op end end end)(), nil)
end

------------------------------------------------------------
-- The displaced-content check sees the updated text (Codex r1)
------------------------------------------------------------
do
    -- Slot 4 holds Heal and gets a spell; slot 5 gets the updated Heal. The
    -- update runs first, so what slot 4 gives up is Heal with the NEW text.
    boot(); char()
    local e = loadout({ [4] = { kind = "spell", id = 2061, name = "Flash Heal", policy = "highest" }, [5] = heal() })
    local plan = L.Plan(e)
    eq("displaced: one edit", #plan.edits, 1)
    local r = L.Load(e, plan)
    check("displaced: loaded", r and not r.failed, r and (tostring(r.failed) .. " at " .. tostring(r.at)))
    eq("displaced: slot 4 the spell", G.actions[4] and G.actions[4].id, 2061)
    eq("displaced: slot 5 Heal", G.actions[5] and G.actions[5].ref.name, "Heal")
    eq("displaced: cursor empty", G.cursor, nil)
    -- The player swaps them by hand: slot 4 holds Heal again (new text).
    -- Restore puts the old text back; slot 4 then holds what the backup has,
    -- so only slot 5 (and slot 6, emptied by the load) needs an op.
    G.actions[4], G.actions[5] = G.actions[5], G.actions[4]
    local rp = L.PlanRestore("1")
    local rslots = {}
    for _, op in ipairs(rp.actions) do rslots[#rslots + 1] = op.slot end
    eq("displaced restore: no op where the revert is enough", table.concat(rslots, ","), "5,6")
    local rr = L.Restore("1", rp)
    check("displaced restore: done", rr and not rr.failed and not rr.partial, rr and rr.failed)
    eq("displaced restore: slot 4 Heal", G.actions[4] and G.actions[4].ref and G.actions[4].ref.name, "Heal")
    eq("displaced restore: slot 5 empty", G.actions[5], nil)
    eq("displaced restore: old text", A.Game.Normalize(macro("Heal").body), OLD)
end

------------------------------------------------------------
-- Stale, combat, failures
------------------------------------------------------------
do
    -- The macro changes between preview and confirm: refused, nothing written.
    boot(); char()
    local e = loadout()
    local plan = L.Plan(e)
    for _, m in ipairs(G.char) do if m.name == "Heal" then m.body = "/cast Something" end end
    G.calls = {}
    local r, err = L.Load(e, plan)
    check("stale: refused", r == nil and has(tostring(err), "changed"), tostring(err))
    eq("stale: wrote nothing", #G.calls, 0)

    -- Combat after the creation, before the update: stopped at the update,
    -- the backup pinned with the update recorded; restore op completes.
    boot(); char()
    e = loadout({ [4] = heal(), [5] = { kind = "macro", name = "Aaa", scope = "char", body = "/a" } },
        { Heal = { body = NEW, icon = NEW_ICON }, Aaa = { body = "/a", icon = ICON } })
    plan = L.Plan(e)
    eq("combat: one create", #plan.creates, 1)
    eq("combat: one edit", #plan.edits, 1)
    G.combatAfter = 1
    r = L.Load(e, plan)
    eq("combat: stopped at the update", r and r.failed, "combat")
    eq("combat: never in combat", #G.blocked, 0)
    eq("combat: text untouched", macro("Heal").body, OLD)
    local _, op = A.Backups.List()
    check("combat: pinned", op ~= nil)
    eq("combat: update recorded", op and op.snapshot.editedMacros and op.snapshot.editedMacros[1].name, "Heal")
    G.combat = false
    local rp = L.PlanRestore("op")
    eq("combat: nothing to put back (never updated)", #rp.edits, 0)
    eq("combat: nothing unavailable", #rp.unavailable, 0)
    local rr = L.Restore("op", rp)
    check("combat: restore op complete", rr and not rr.failed and not rr.partial, rr and rr.failed)
    check("combat: released", select(2, A.Backups.List()) == nil)

    -- Another macro the plan updates changes during the load (here: while
    -- the first update runs): its own update refuses, untouched.
    boot()
    char({ macros = { { name = "Heal", body = OLD, char = true, icon = ICON },
                      { name = "Shield", body = "/old shield", char = true, icon = ICON } },
           actions = { [4] = { macro = "Heal" }, [5] = { macro = "Shield" } } })
    e = loadout({ [4] = heal(), [5] = { kind = "macro", name = "Shield", scope = "char", body = "/new shield" } },
        { Heal = { body = NEW, icon = NEW_ICON }, Shield = { body = "/new shield", icon = ICON } })
    plan = L.Plan(e)
    G.onEditMacro = function()
        G.onEditMacro = nil
        for _, m in ipairs(G.char) do if m.name == "Shield" then m.body = "/someone else's" end end
    end
    r = L.Load(e, plan)
    eq("mid-load change: refused", r and r.failed, "macro changed since the preview")
    eq("mid-load change: at Shield", r and r.at, "macro Shield")
    eq("mid-load change: Shield untouched", macro("Shield").body, "/someone else's")
    eq("mid-load change: one EditMacro", calls("EditMacro"), 1)

    -- The client refuses the update, or writes something else: stopped,
    -- named, never treated as done.
    for _, fault in ipairs({ "error", "noop", "wrong" }) do
        boot(); char()
        e = loadout()
        plan = L.Plan(e)
        G.macroFault = fault
        r = L.Load(e, plan)
        check(fault .. ": stopped", r and r.failed ~= nil, r and "loaded")
        eq(fault .. ": named", r and r.at, "macro Heal")
        check(fault .. ": pinned", select(2, A.Backups.List()) ~= nil)
    end
end

------------------------------------------------------------
-- Restore: edited again, interrupted, a macro-only conflict in the preview
------------------------------------------------------------
do
    -- Two updates; the player edits one again afterwards. Restore puts the
    -- other back and leaves this one, listed by name (no slot), partial.
    boot()
    char({ macros = { { name = "Heal", body = OLD, char = true, icon = ICON },
                      { name = "Shield", body = "/old shield", char = true, icon = ICON } },
           actions = { [4] = { macro = "Heal" }, [5] = { macro = "Shield" } } })
    local e = loadout({ [4] = heal(), [5] = { kind = "macro", name = "Shield", scope = "char", body = "/new shield" } },
        { Heal = { body = NEW, icon = NEW_ICON }, Shield = { body = "/new shield", icon = ICON } })
    local r = L.Load(e, L.Plan(e))
    check("again: loaded", r and not r.failed, r and r.failed)
    eq("again: two updates", r and r.edited, 2)
    for _, m in ipairs(G.char) do if m.name == "Heal" then m.body = "/cast Heal -- mine now" end end
    G.calls = {}
    local rp = L.PlanRestore("1")
    eq("again: Shield put back", #rp.edits == 1 and rp.edits[1].name, "Shield")
    local named
    for _, u in ipairs(rp.unavailable) do if u.name == "Heal" and not u.slot then named = u.reason end end
    eq("again: Heal left, by name", named, "changed since the load, left as is")
    local ok, t = pcall(function() return text(A.Commands.Describe(rp)) end)
    check("again: preview builds", ok, t)
    check("again: preview names it", ok and has(t, "  macro Heal: changed since the load, left as is"), t)
    local rr = L.Restore("1", rp)
    check("again: partial", rr and rr.partial)
    eq("again: Heal is the player's", macro("Heal").body, "/cast Heal -- mine now")
    eq("again: Shield back", A.Game.Normalize(macro("Shield").body), "/old shield")
    eq("again: one EditMacro (Shield)", calls("EditMacro"), 1)

    -- A load that stopped (pinned); its restore stops right after putting
    -- the macro back; the next restore sees it already back and completes.
    boot(); char()
    e = loadout({ [4] = heal(), [6] = { kind = "spell", id = 2061, name = "Flash Heal", policy = "highest" },
                  [7] = { kind = "spell", id = 2061, name = "Flash Heal", policy = "highest" } })
    local plan = L.Plan(e)
    G.combatAfter = 4                       -- EditMacro, then slot 6's two calls, then combat
    r = L.Load(e, plan)
    check("interrupted: load stopped", r and r.failed ~= nil)
    G.combat = false
    eq("interrupted: macro updated", macro("Heal").body, NEW)
    local rp1 = L.PlanRestore("op")
    eq("interrupted: one revert", #rp1.edits, 1)
    G.combatAfter = 1                       -- the revert, then combat
    local rr1 = L.Restore("op", rp1)
    check("interrupted: restore stopped", rr1 and rr1.failed ~= nil)
    G.combat = false
    eq("interrupted: macro already back", A.Game.Normalize(macro("Heal").body), OLD)
    local rp2 = L.PlanRestore("op")
    eq("interrupted: nothing to put back", #rp2.edits, 0)
    eq("interrupted: nothing unavailable", #rp2.unavailable, 0)
    local rr2 = L.Restore("op", rp2)
    check("interrupted: second restore complete", rr2 and not rr2.failed and not rr2.partial, rr2 and rr2.failed)
    check("interrupted: released", select(2, A.Backups.List()) == nil)
    eq("interrupted: slot 6 back", G.actions[6] and G.actions[6].id, 2050)
end

------------------------------------------------------------
-- The first backup has the update too (Codex r2)
------------------------------------------------------------
do
    boot(); char({ actions = { [4] = { macro = "Heal" } } })
    local e = loadout()
    local plan = L.Plan(e)
    eq("first: an update only", #plan.actions .. "/" .. #plan.edits, "0/1")
    local r = L.Load(e, plan)
    check("first: loaded", r and not r.failed)
    local first = A.Backups.Get("first")
    eq("first: has the update", first and first.editedMacros and first.editedMacros[1].before.body, OLD)
    local rp = L.PlanRestore("first")
    eq("first: puts it back", #rp.edits, 1)
    local rr = L.Restore("first", rp)
    check("first: done", rr and not rr.failed and not rr.partial)
    eq("first: old text", A.Game.Normalize(macro("Heal").body), OLD)
end

------------------------------------------------------------
-- Damaged and unreadable: never an update
------------------------------------------------------------
do
    for label, def in pairs({ ["no body"] = { icon = NEW_ICON }, ["body a number"] = { body = 5, icon = NEW_ICON } }) do
        boot(); char()
        local e = loadout(nil, { Heal = def })
        local plan = L.Plan(e)
        local why
        for _, s in ipairs(plan.skips) do if s.slot == 4 then why = s.reason end end
        eq(label .. ": left alone", why, "macro definition damaged")
        eq(label .. ": no edit", #plan.edits, 0)
        L.Load(e, plan)
        eq(label .. ": no EditMacro", calls("EditMacro"), 0)
        eq(label .. ": text kept", macro("Heal").body, OLD)
    end
    -- An empty string is a real body: an update.
    boot(); char()
    eq("empty body: an update", #L.Plan(loadout(nil, { Heal = { body = "", icon = ICON } })).edits, 1)

    -- This character's macro reads with no body.
    boot(); char()
    for _, m in ipairs(G.char) do if m.name == "Heal" then m.body = nil end end
    local plan = L.Plan(loadout())
    local why
    for _, s in ipairs(plan.skips) do if s.slot == 4 then why = s.reason end end
    eq("unreadable body: left alone", why, "macros unreadable")
    eq("unreadable body: no edit", #plan.edits, 0)

    -- Too long after normalising: never written.
    boot(); char()
    plan = L.Plan(loadout(nil, { Heal = { body = ("x"):rep(255), icon = ICON } }))
    eq("too long: no edit", #plan.edits, 0)
end

------------------------------------------------------------
-- Account macros are never written; two of a name are refused
------------------------------------------------------------
do
    boot()
    char({ macros = { { name = "Heal", body = OLD, icon = ICON }, { name = "Acct", body = "/say hi" } } })
    local e = loadout()
    local plan = L.Plan(e)
    eq("account Heal: no edit", #plan.edits, 0)
    eq("account Heal: nothing created", #plan.creates, 0)
    L.Load(e, plan)
    eq("account Heal: no EditMacro", calls("EditMacro"), 0)
    eq("account Heal: untouched", A.Game.MacrosNamed("Heal")[1].body, OLD)

    boot()
    char({ macros = { { name = "Heal", body = OLD, char = true, icon = ICON },
                      { name = "Heal", body = "/two", char = true, icon = ICON } },
           actions = {} })
    plan = L.Plan(loadout())
    eq("two Heals: no edit", #plan.edits, 0)
end

------------------------------------------------------------
-- A creation shifts the edited macro's index (macros sort by name)
------------------------------------------------------------
do
    boot(); char()
    local before = A.Game.MacrosNamed("Heal")[1].index
    local e = loadout({ [4] = heal(), [5] = { kind = "macro", name = "Aaa", scope = "char", body = "/a" } },
        { Heal = { body = NEW, icon = NEW_ICON }, Aaa = { body = "/a", icon = ICON } })
    local r = L.Load(e, L.Plan(e))
    check("shift: loaded", r and not r.failed, r and r.failed)
    check("shift: Heal moved", A.Game.MacrosNamed("Heal")[1].index ~= before)
    eq("shift: Heal updated", macro("Heal").body, NEW)
    eq("shift: Aaa as created", macro("Aaa").body, "/a")
    eq("shift: account macro untouched", A.Game.MacrosNamed("Acct")[1].body, "/say hi")
end

------------------------------------------------------------
-- Include character macros, unticked
------------------------------------------------------------
do
    boot(); char({ macros = { { name = "Heal", body = OLD, char = true, icon = ICON }, { name = "Acct", body = "/say hi" } },
                   actions = { [4] = { macro = "Heal" }, [6] = { spell = 2050 } } })
    local e = loadout({ [4] = heal(), [5] = { kind = "macro", name = "New", scope = "char", body = "/n" },
                        [7] = { kind = "macro", name = "Acct", scope = "account", body = "/say hi" } },
        { Heal = { body = NEW, icon = NEW_ICON }, New = { body = "/n", icon = ICON } })
    local plan = L.Plan(e, { noCharMacros = true })
    eq("no macros: no edit", #plan.edits, 0)
    eq("no macros: nothing created", #plan.creates, 0)
    local why = {}
    for _, s in ipairs(plan.skips) do why[s.slot] = s.reason end
    eq("no macros: slot 4 left", why[4], "character macros not included")
    eq("no macros: slot 5 left", why[5], "character macros not included")
    local placed
    for _, op in ipairs(plan.actions) do if op.slot == 7 then placed = op.target end end
    eq("no macros: the account macro still placed", placed and placed.name, "Acct")
    check("no macros: differs from the ticked plan", plan.fingerprint ~= L.Plan(e).fingerprint)
    -- Confirming a preview planned without macros applies that plan.
    local r = L.Load(e, plan)
    check("no macros: loaded", r and not r.failed, r and r.failed)
    eq("no macros: no macro written", calls("EditMacro") + calls("CreateMacro"), 0)
    eq("no macros: Heal kept", macro("Heal").body, OLD)
    eq("no macros: recorded as unavailable", A.char.loaded.loadout.unavailable[4], "character macros not included")
    -- Save keeps the loadout's macros (it only widens the cover, #5).
    local m = L.PlanSave()
    eq("no macros: save changes no slot", m and #m.changed, 0)
    eq("no macros: save keeps the loadout's Heal", m and m.modules.macros.Heal.body, NEW)
    eq("no macros: save keeps New", m and m.modules.macros.New and m.modules.macros.New.body, "/n")
    eq("no macros: save keeps slot 4", m and m.modules.actions[4].body, NEW)

    -- The command: "nomacros", the box unticked, and ticking re-plans.
    boot(); char()
    e = loadout()
    A.Commands.load(e.name .. " nomacros")
    check("command nomacros: shown", A._shown ~= nil, table.concat(WoW.chat(), " / "))
    eq("command nomacros: unticked", A._shown and A._shown.check and A._shown.check.checked, false)
    check("command nomacros: no update listed", A._shown and not has(text(A._shown.lines), "to update"))
    A._shown.check.onToggle(true)
    eq("command tick: ticked", A._shown.check.checked, true)
    check("command tick: update listed", has(text(A._shown.lines), "1 macro to update"))
    A._shown.check.onToggle(false)
    A._shown.onConfirm()
    eq("command untick: nothing written to macros", calls("EditMacro"), 0)

    -- No character macro in the loadout: no box.
    boot(); char()
    A.Commands.LoadEntry(loadout({ [4] = { kind = "spell", id = 2061, name = "Flash Heal", policy = "highest" } }, {}))
    eq("no box without character macros", A._shown and A._shown.check, nil)
end

------------------------------------------------------------
-- A04: change a macro on one character, Save, Load on another
------------------------------------------------------------
do
    boot()
    G.setup{ class = "PRIEST", guid = "Player-70-MAIN", spells = SPELLS,
             macros = { { name = "Heal", body = OLD, char = true, icon = ICON } },
             actions = { [4] = { macro = "Heal" } }, keys = {} }
    local m = L.Capture()
    m.cover = { { 1, 12 } }
    local e = assert(A.Catalog.Create("loadout", { class = "PRIEST", category = "general", name = "Everyday" }, m))
    -- The alt loads it: Heal created.
    G.setup{ class = "PRIEST", guid = "Player-70-ALT", spells = SPELLS, macros = {}, actions = {}, keys = {} }
    local r = L.Load(e, L.Plan(e))
    check("A04: alt loaded", r and r.created == 1)
    -- Back on the main: the macro changes, Save.
    G.setup{ class = "PRIEST", guid = "Player-70-MAIN", spells = SPELLS,
             macros = { { name = "Heal", body = OLD, char = true, icon = ICON } },
             actions = { [4] = { macro = "Heal" } }, keys = {} }
    A.char.loaded = nil
    L.Load(e, L.Plan(e))
    for _, x in ipairs(G.char) do if x.name == "Heal" then x.body = NEW end end
    local sp = L.PlanSave()
    check("A04: save sees the change", sp and not sp.noop, sp and "noop")
    local saved = L.Save(sp)
    check("A04: saved", saved ~= nil)
    e = A.Catalog.Get(e.id)
    eq("A04: the entry has the new text", e.modules.macros.Heal.body, NEW)
    -- The alt again: its Heal is updated, not emptied.
    G.setup{ class = "PRIEST", guid = "Player-70-ALT", spells = SPELLS,
             macros = { { name = "Heal", body = OLD, char = true, icon = ICON } },
             actions = { [4] = { macro = "Heal" } }, keys = {} }
    local plan = L.Plan(e)
    eq("A04: an update on the alt", #plan.edits, 1)
    r = L.Load(e, plan)
    check("A04: alt loaded again", r and not r.failed)
    eq("A04: the alt's Heal updated", macro("Heal").body, NEW)
    eq("A04: slot 4 still Heal", G.actions[4] and G.actions[4].ref.name, "Heal")
end

finish("test_macros")
