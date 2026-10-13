------------------------------------------------------------
-- test_backup_now.lua - Back up now (#61): the whole setup into a new
-- backup, in the snapshot shape restores already read. It writes only the
-- backups store; a full ring is previewed first.
------------------------------------------------------------

dofile("tests/harness.lua")
dofile("tests/wow_stubs.lua")
dofile("tests/wow_game.lua")

local G = WoW.game
local A, L, B

local function boot(opts)
    WoW.reset()
    for _, f in ipairs({ "Core.lua", "Categories.lua", "Catalog.lua", "Game.lua", "Pet.lua", "Backups.lua",
                         "Ready.lua", "Loadout.lua", "Commands.lua" }) do
        assert(loadfile(f))("AltStableSync", {})
    end
    WoW.fire("ADDON_LOADED", "AltStableSync")
    A, L, B = AltStableSync, AltStableSync.Loadout, AltStableSync.Backups
    A.Preview = { Show = function(o) A._shown = o end, Hide = function() A._shown = nil end,
                  Shown = function() return A._shown end }
    opts = opts or {}
    G.setup{
        class = opts.class or "PRIEST", guid = "Player-70-MAIN", pet = opts.pet, bindingSet = opts.bindingSet,
        spells = { { id = 9472, name = "Flash Heal" }, { id = 2050, name = "Lesser Heal" }, { id = 2060, name = "Greater Heal" } },
        items = { [5512] = 2 },
        macros = { { name = "Shield", body = "/cast Power Word: Shield", char = true } },
        actions = { [1] = { spell = 9472 }, [2] = { spell = 2050 }, [3] = { item = 5512 }, [4] = { macro = "Shield" },
                    [6] = { flyout = 1 } },
        keys = { ["1"] = "ACTIONBUTTON1", ["2"] = "ACTIONBUTTON2", ["SHIFT-2"] = "ACTIONBUTTON2" },
    }
    WoW.fire("PLAYER_ENTERING_WORLD", true, false)
    WoW.clock = WoW.clock + 10
end

local function said(s) return table.concat(WoW.chat(), "\n"):find(s, 1, true) ~= nil end
local function ring() return (B.List()) end
local function ser(v)
    if type(v) ~= "table" then return type(v):sub(1, 1) .. tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. "=" .. ser(v[k]) end
    return "{" .. table.concat(out, ",") .. "}"
end

-- The snapshot: every supported slot, the managed keys; nothing written to the game.
do
    boot()
    local catalog, char = ser(AltStableSyncDB.presets), ser(AltStableSyncChar)
    G.calls = {}
    WoW.chatLines = {}
    A.Commands.backup()
    local r = ring()
    eq("one backup", #r, 1)
    local s = r[1]
    eq("its reason", s.reason, "Manual")
    check("timed", type(s.at) == "number")
    eq("slot 1: the spell", s.actions[1] and s.actions[1].id, 9472)
    eq("slot 3: the item", s.actions[3] and s.actions[3].id, 5512)
    eq("slot 4: the macro, by name", s.actions[4] and s.actions[4].name, "Shield")
    eq("an empty slot is false", s.actions[5], false)
    eq("the flyout is left out", s.actions[6], nil)
    local n = 0
    for _ in pairs(s.actions) do n = n + 1 end
    eq("every other supported slot recorded", n, #A.Game.SLOT_LIST - 1)
    eq("key 1", s.keys["1"], "ACTIONBUTTON1")
    eq("key SHIFT-2", s.keys["SHIFT-2"], "ACTIONBUTTON2")
    eq("no macro will be deleted by restoring it", next(s.createdMacros), nil)
    eq("no pet out: no pet bar", s.pet, nil)
    check("says what it took", said("Backed up: 4 slots with an action, 3 keys."), table.concat(WoW.chat(), " | "))
    check("says what it left out", said("Left out (restoring leaves it as it is):"), table.concat(WoW.chat(), " | "))
    check("names the slot by bar and button", said("button 6: flyout"), table.concat(WoW.chat(), " | "))
    eq("no game write", #G.calls, 0)
    eq("catalog unchanged", ser(AltStableSyncDB.presets), catalog)
    eq("character data unchanged", ser(AltStableSyncChar), char)
    check("firstSeen set by the first backup, as for any", B.List and select(3, B.List()) ~= nil)
    eq("no preview for a ring that isn't full", A._shown, nil)

    -- Nothing changed: no second copy.
    WoW.chatLines = {}
    A.Commands.backup()
    eq("unchanged: still one", #ring(), 1)
    check("unchanged: said, before any write is tried", said("nothing new to back up"))
    -- The engine refuses a duplicate itself, whoever calls it.
    local p = assert(L.PlanBackup())
    check("engine: plan says it matches", p.matches)
    local r, why = L.Backup(p)
    check("engine: duplicate refused", r == nil and tostring(why):find("already matches", 1, true) ~= nil, tostring(why))
    eq("engine: still one", #ring(), 1)
    -- A change: a new one.
    G.actions[7] = { kind = "spell", id = 2060 }
    A.Commands.backup()
    eq("changed: a second backup", #ring(), 2)
    eq("newest first", ring()[1].actions[7] and ring()[1].actions[7].id, 2060)
end

-- With a pet out, its bar is in it.
do
    boot({ class = "HUNTER", pet = { name = "Tarthosuk", guid = "Pet-0-A1",
        bar = { [1] = { token = "PET_ACTION_ATTACK" }, [4] = { spell = 14916 } },
        book = { { id = 14916, name = "Growl" } } } })
    A.Commands.backup()
    local s = ring()[1]
    check("pet bar recorded", s and s.pet and s.pet.name == "Tarthosuk" and s.pet.slots ~= nil)
    check("says the pet bar", said("the pet bar"))
end

-- Refused: combat, not ready, the cursor, an unreadable slot or key.
do
    boot()
    G.combat = true
    WoW.chatLines = {}
    A.Commands.backup()
    eq("combat: none", #ring(), 0)
    check("combat: said", said("Not backed up"))
    G.combat = false
    G.cursor = { kind = "item", id = 5512 }
    A.Commands.backup()
    eq("cursor: none", #ring(), 0)
    G.cursor = nil
    local info = GetActionInfo
    GetActionInfo = function(slot) if slot == 9 then error("boom") end return info(slot) end
    WoW.chatLines = {}
    A.Commands.backup()
    GetActionInfo = info
    eq("unreadable slot: none", #ring(), 0)
    check("unreadable slot: try again", said("Couldn't read your action bars"))
    local gbk = GetBindingKey
    GetBindingKey = function() error("boom") end
    A.Commands.backup()
    GetBindingKey = gbk
    eq("unreadable keys: none", #ring(), 0)

    boot()
    WoW.clock = WoW.clock - 10                               -- back before readiness
    WoW.fire("PLAYER_ENTERING_WORLD", true, false)
    A.Commands.backup()
    eq("not ready: none", #ring(), 0)
end

-- A full ring: previewed; Cancel keeps it; Confirm drops exactly the oldest.
do
    boot()
    for i = 1, B.RING do B.PushRing({ reason = "old " .. i, actions = {}, keys = {}, createdMacros = {}, at = i }) end
    local oldest = ring()[#ring()]
    eq("ring full", #ring(), B.RING)
    local first, op = select(3, B.List()), B.Operation()
    A.Commands.backup()
    check("full: previewed", A._shown and A._shown.title == "Back up now?")
    check("full: names the oldest", A._shown and table.concat(A._shown.lines, "\n"):find("drops the oldest: old 1", 1, true) ~= nil,
          A._shown and table.concat(A._shown.lines, " | "))
    eq("full: nothing before the confirm", ring()[1].reason, "old " .. B.RING)
    A._shown = nil                                           -- cancelled
    eq("cancel: unchanged", #ring(), B.RING)
    check("cancel: the oldest kept", ring()[#ring()] == oldest)
    A.Commands.backup()
    A._shown.onConfirm()
    eq("confirm: still full", #ring(), B.RING)
    eq("confirm: newest is the manual one", ring()[1].reason, "Manual")
    check("confirm: the oldest dropped", ring()[#ring()] ~= oldest and ring()[#ring()].reason == "old 2")
    check("confirm: firstSeen untouched", select(3, B.List()) == first)
    eq("confirm: no pinned operation made", B.Operation(), op)

    -- Stale: the ring changed between the preview and the confirm.
    G.actions[8] = { kind = "spell", id = 2060 }
    A.Commands.backup()
    local shown = A._shown
    B.PushRing({ reason = "sneaked in", actions = {}, keys = {}, createdMacros = {} })
    local before = ser(ring())
    WoW.chatLines = {}
    shown.onConfirm()
    eq("stale: nothing pushed", ser(ring()), before)
    check("stale: said", said("review it again"))
end

-- Restore of a manual backup puts each recorded slot and key back exactly,
-- and leaves a left-out slot as it is.
do
    boot()
    A.Commands.backup()
    G.actions[1] = { kind = "spell", id = 2060 }             -- changed
    G.actions[3] = nil                                       -- emptied
    G.actions[5] = { kind = "item", id = 5512 }              -- filled
    G.actions[6] = { kind = "flyout", id = 2 }               -- the left-out slot, changed too
    G.keys["1"] = "ACTIONBUTTON3"                            -- rebound
    local plan = L.PlanRestore("1")
    check("restore: not blocked", not plan.blocked, plan.blocked)
    local r, err = L.Restore("1", plan)
    check("restore: done", r ~= nil and not r.failed, tostring(err) .. " " .. tostring(r and r.failed))
    eq("slot 1 back", G.actions[1] and G.actions[1].id, 9472)
    eq("slot 3 back", G.actions[3] and G.actions[3].id, 5512)
    eq("slot 5 emptied again", G.actions[5], nil)
    eq("the left-out slot left as it is", G.actions[6] and G.actions[6].id, 2)
    eq("key 1 back", G.keys["1"], "ACTIONBUTTON1")
    eq("macro slot kept", G.actions[4] and G.actions[4].kind, "macro")
end

------------------------------------------------------------
-- Codex on the #61 plan, round 1
------------------------------------------------------------

-- Account keybindings: no keys in the backup (restores write the Character
-- set only), and it says so; restoring it writes no key.
do
    boot({ bindingSet = 1 })
    WoW.chatLines = {}
    A.Commands.backup()
    local s = ring()[1]
    check("account set: a backup", s ~= nil)
    eq("account set: no keys", s and next(s.keys), nil)
    eq("account set: recorded as such", s and s.characterBindings, false)
    check("account set: said", said("Keys aren't backed up while you use your account keybindings"))
    G.actions[1] = { kind = "spell", id = 2060 }
    G.calls = {}
    local plan = L.PlanRestore("1")
    local r = L.Restore("1", plan)
    check("account set: restore done", r and not r.failed)
    local keyWrites = 0
    for _, c in ipairs(G.calls) do if c == "SetBinding" then keyWrites = keyWrites + 1 end end
    eq("account set: restore wrote no key", keyWrites, 0)
end

-- A backup taken on Character keybindings, restored while on Account ones:
-- its keys are blocked, never written into the Account set.
do
    boot()
    A.Commands.backup()
    G.bindingSet = 1
    local plan = L.PlanRestore("1")
    check("character backup on account set: keys blocked", plan.keysBlocked ~= nil)
end

-- The pet: no pet is fine; a pet that can't be read refuses the backup.
do
    boot({ class = "HUNTER", pet = { name = "Tarthosuk", guid = "Pet-0-A1", bar = { [1] = { token = "PET_ACTION_ATTACK" } },
        book = {} } })
    local gpai = GetPetActionInfo
    GetPetActionInfo = function() error("boom") end
    WoW.chatLines = {}
    A.Commands.backup()
    GetPetActionInfo = gpai
    eq("unreadable pet bar: no backup", #ring(), 0)
    check("unreadable pet bar: said", said("Couldn't read your pet's bar"))
    local ue = UnitExists
    UnitExists = function(unit) if unit == "pet" then error("boom") end return ue(unit) end
    A.Commands.backup()
    UnitExists = ue
    eq("unreadable pet: no backup", #ring(), 0)
end

-- "Nothing new" only against a backup that restores the same way.
do
    boot()
    A.Commands.backup()
    local manual = ring()[1]
    -- A load's backup with the same slots and keys but a macro edit to undo:
    -- not the same, so Back up now takes one.
    local auto = A.Catalog.Copy(manual)
    auto.reason, auto.editedMacros = "load X", { { name = "Shield", before = { body = "/a" }, after = { body = "/b" } } }
    B.PushRing(auto)
    A.Commands.backup()
    eq("macro-edit backup is not a match", ring()[1].reason, "Manual")
    eq("so a new one was taken", #ring(), 3)
end

-- Restore of a manual backup: a displaced key comes back, and the restore's
-- own backup has what it displaced; a key bound later stays; a slot captured
-- empty that now holds something unsupported is left alone; a macro whose
-- text changed is left as is, and no macro is edited.
do
    boot()
    A.Commands.backup()
    G.keys["1"] = "MOVEFORWARD"                             -- displaced onto an unrelated command
    G.keys["3"] = "ACTIONBUTTON1"                           -- a key bound later
    G.actions[5] = { kind = "flyout", id = 9 }               -- captured empty, now unsupported
    local m = A.Game.MacrosNamed("Shield")[1]
    EditMacro(m.index, "Shield", nil, "/cast Something Else")
    G.calls = {}
    local plan = L.PlanRestore("1")
    local r = L.Restore("1", plan)
    check("restore ran", r ~= nil)
    eq("displaced key back", G.keys["1"], "ACTIONBUTTON1")
    eq("the restore's own backup has what it displaced", ring()[1].keys["1"], "MOVEFORWARD")
    eq("key bound later stays", G.keys["3"], "ACTIONBUTTON1")
    eq("unsupported content left alone", G.actions[5] and G.actions[5].kind, "flyout")
    check("partial: says what it couldn't put back", #(plan.unavailable or {}) >= 1)
    local edits = 0
    for _, c in ipairs(G.calls) do if c == "EditMacro" or c == "CreateMacro" or c == "DeleteMacro" then edits = edits + 1 end end
    eq("no macro created, edited or deleted", edits, 0)
end

-- A fresh store: the first backup also becomes the first-seen one (as for any).
do
    boot()
    eq("fresh: no first backup yet", select(3, B.List()), nil)
    A.Commands.backup()
    check("fresh: first backup set", select(3, B.List()) ~= nil)
end

------------------------------------------------------------
-- Codex on the #61 plan, round 2
------------------------------------------------------------

-- The cross-set case: captured on Account keybindings, then the character
-- switches to its own and customises them; restoring the backup leaves them.
do
    boot({ bindingSet = 1 })
    A.Commands.backup()
    G.bindingSet = 2
    G.keys["1"] = "ACTIONBUTTON5"
    G.charStore = A.Catalog.Copy(G.keys)
    G.actions[1] = { kind = "spell", id = 2060 }
    local plan = L.PlanRestore("1")
    local r = L.Restore("1", plan)
    check("cross-set: restore done", r and not r.failed)
    eq("cross-set: the character's own key kept", G.keys["1"], "ACTIONBUTTON5")
    eq("cross-set: the slot restored", G.actions[1] and G.actions[1].id, 9472)
end

-- An unreadable binding set counts as Account: no keys.
do
    boot()
    local gcbs = GetCurrentBindingSet
    GetCurrentBindingSet = function() error("boom") end
    A.Commands.backup()
    GetCurrentBindingSet = gcbs
    local s = ring()[1]
    check("unreadable set: a backup", s ~= nil)
    eq("unreadable set: no keys", s and next(s.keys), nil)
end

-- The full-ring confirm refuses when what it showed changed: the content,
-- only what is left out, or the backup it would drop (changed in place).
do
    local function full()
        boot()
        for i = 1, B.RING do B.PushRing({ reason = "old " .. i, actions = {}, keys = {}, createdMacros = {}, at = i }) end
    end
    local function stale(name, change)
        full()
        A.Commands.backup()
        local shown = A._shown
        check(name .. ": previewed", shown ~= nil)
        change()
        local before = ser(ring())
        WoW.chatLines = {}
        shown.onConfirm()
        eq(name .. ": nothing pushed", ser(ring()), before)
        check(name .. ": said", said("review it again"))
    end
    stale("content changed", function() G.actions[9] = { kind = "spell", id = 2060 } end)
    -- Slot 6 still left out, but for another reason: the content is the same.
    stale("only what is left out changed", function() G.actions[6] = { kind = "item", id = 9999 } end)
    stale("the backup it would drop changed in place", function() local r = ring(); r[#r].reason = "renamed" end)
end

-- A pinned interrupted load, and the character's record of it, are kept.
do
    boot()
    local pin = { reason = "load X", actions = {}, keys = {}, createdMacros = {}, at = 5 }
    assert(B.Pin(pin, { kind = "load", id = "x", version = "v", name = "X" }))
    A.char.interrupted = { id = "x", version = "v", why = "combat", at = 1 }
    local interrupted = ser(A.char.interrupted)
    A.Commands.backup()
    eq("pin: a manual backup taken", ring()[1] and ring()[1].reason, "Manual")
    check("pin: the pinned operation untouched", B.Operation() and B.Operation().snapshot == pin)
    eq("pin: the interrupted record untouched", ser(A.char.interrupted), interrupted)
end

-- Round 3: a failed read is never an omission; the success report states the coverage.
do
    boot()
    WoW.chatLines = {}
    A.Commands.backup()
    check("report states the coverage", said("Restoring it leaves keys you bind later"), table.concat(WoW.chat(), " | "))
    local before = ser(ring())
    G.actions[9] = { kind = "spell", id = 2060 }             -- something new to back up
    local gic = C_Item.GetItemCount
    C_Item.GetItemCount = function() error("boom") end
    WoW.chatLines = {}
    A.Commands.backup()
    C_Item.GetItemCount = gic
    eq("unreadable bags: nothing stored", ser(ring()), before)
    check("unreadable bags: said", said("Couldn't read your bags"))
    local gat = GetActionText
    GetActionText = function() error("boom") end
    A.Commands.backup()
    GetActionText = gat
    eq("unreadable macro name: nothing stored", ser(ring()), before)
    local mn = A.Game.MacrosNamed
    local calls = 0
    A.Game.MacrosNamed = function(name) calls = calls + 1; if calls > 1 then return nil end return mn(name) end
    WoW.chatLines = {}
    A.Commands.backup()
    A.Game.MacrosNamed = mn
    eq("unreadable macro list: nothing stored", ser(ring()), before)
    check("unreadable macro list: said", said("Couldn't read your macros"))
end

-- Round 4: a spell outside the class spellbook whose by-id read fails, and
-- that failure at a full ring's confirm: nothing stored, nothing dropped.
do
    boot()
    G.extra = { [3908] = "Tailoring" }                       -- known, not in the class book
    G.actions[10] = { kind = "spell", id = 3908 }
    A.Commands.backup()
    eq("profession spell: recorded when readable", ring()[1] and ring()[1].actions[10] and ring()[1].actions[10].id, 3908)
    local before = ser(ring())
    G.actions[9] = { kind = "spell", id = 2060 }
    local sk = A.Game.SpellKnownById
    A.Game.SpellKnownById = function(id) if id == 3908 then return nil end return sk(id) end
    WoW.chatLines = {}
    A.Commands.backup()
    eq("by-id read failed: nothing stored", ser(ring()), before)
    check("by-id read failed: said", said("Couldn't read your spells"))
    A.Game.SpellKnownById = sk
    -- At a full ring: the preview, then the read fails before the confirm.
    for i = #ring() + 1, B.RING do B.PushRing({ reason = "pad " .. i, actions = {}, keys = {}, createdMacros = {}, at = i }) end
    A.Commands.backup()
    local shown = A._shown
    check("full ring: previewed", shown ~= nil)
    before = ser(ring())
    A.Game.SpellKnownById = function(id) if id == 3908 then return nil end return sk(id) end
    shown.onConfirm()
    A.Game.SpellKnownById = sk
    eq("full ring, read fails at the confirm: nothing dropped or stored", ser(ring()), before)
end

-- Round 5: a partly read spellbook, a spell missing from it and a "no" by
-- id: unreadable, not absent. Nothing stored, and at a full ring nothing dropped.
do
    boot()
    G.actions[10] = { kind = "spell", id = 3908 }            -- not in the book, not known by id
    A.Commands.backup()
    check("complete book, known nowhere: left out", ring()[1] and ring()[1].actions[10] == nil)
    local before = ser(ring())
    G.actions[9] = { kind = "spell", id = 2060 }
    local sb = A.Game.Spellbook
    A.Game.Spellbook = function() local b = sb(); b.complete = false; return b end
    WoW.chatLines = {}
    A.Commands.backup()
    eq("partial book: nothing stored", ser(ring()), before)
    check("partial book: said", said("Couldn't read your spells"))
    A.Game.Spellbook = sb
    for i = #ring() + 1, B.RING do B.PushRing({ reason = "pad " .. i, actions = {}, keys = {}, createdMacros = {}, at = i }) end
    A.Commands.backup()
    local shown = A._shown
    check("partial book, full ring: previewed", shown ~= nil)
    before = ser(ring())
    A.Game.Spellbook = function() local b = sb(); b.complete = false; return b end
    shown.onConfirm()
    A.Game.Spellbook = sb
    eq("partial book at the confirm: nothing dropped or stored", ser(ring()), before)
end

------------------------------------------------------------
-- Codex on PR #72
------------------------------------------------------------

-- The pet's spellbook: unreadable, or missing an ability on the bar, refuses
-- the backup (a restore couldn't put that ability back); the ring is unchanged.
do
    local function hunter(book)
        boot({ class = "HUNTER", pet = { name = "Tarthosuk", guid = "Pet-0-A1",
            bar = { [1] = { token = "PET_ACTION_ATTACK" }, [4] = { spell = 14916 } }, book = book } })
        WoW.chatLines = {}
    end
    hunter({ { id = 14916, name = "Growl" } })
    local hps = C_SpellBook.HasPetSpells
    C_SpellBook.HasPetSpells = function() error("boom") end
    A.Commands.backup()
    C_SpellBook.HasPetSpells = hps
    eq("unreadable pet book: no backup", #ring(), 0)
    check("unreadable pet book: said", said("Couldn't read your pet's spellbook"), table.concat(WoW.chat(), " | "))

    hunter({ { id = 14917, name = "Growl" } })
    A.Commands.backup()
    eq("ability not in the pet book: no backup", #ring(), 0)
    check("ability not in the pet book: names the slot", said("Pet slot 4"), table.concat(WoW.chat(), " | "))

    -- At a full ring's confirm, nothing is dropped.
    hunter({ { id = 14916, name = "Growl" } })
    for i = 1, B.RING do B.PushRing({ reason = "old " .. i, actions = {}, keys = {}, createdMacros = {}, at = i }) end
    A.Commands.backup()
    local shown = A._shown
    check("pet book at confirm: previewed", shown ~= nil)
    G.pet.book = { { id = 14917, name = "Growl" } }
    local before = ser(ring())
    shown.onConfirm()
    eq("pet book at confirm: nothing dropped", ser(ring()), before)
end

-- The same pet resummoned (a new GUID), with the same bar: nothing new.
do
    boot({ class = "HUNTER", pet = { name = "Tarthosuk", guid = "Pet-0-A1",
        bar = { [1] = { token = "PET_ACTION_ATTACK" }, [4] = { spell = 14916 } },
        book = { { id = 14916, name = "Growl" } } } })
    A.Commands.backup()
    eq("resummon: one backup", #ring(), 1)
    G.pet.guid = "Pet-0-B2"
    WoW.chatLines = {}
    A.Commands.backup()
    eq("resummon: still one backup", #ring(), 1)
    check("resummon: nothing new", said("nothing new"), table.concat(WoW.chat(), " | "))
    -- Another pet with the same bar is new.
    G.pet.name = "Other"
    A.Commands.backup()
    eq("another pet: a second backup", #ring(), 2)
end

finish("test_backup_now")
