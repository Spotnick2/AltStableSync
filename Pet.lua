------------------------------------------------------------
-- Pet.lua - the pet bar layout per pet family (#47 part B)
--
-- A loadout keeps one pet bar per pet family (modules.pet[familyId]); a
-- Load changes only the bar of the pet that is out, and nothing happens
-- on summon. The measured client (docs/forever-api-notes.md "Pet bar",
-- 70338): PickupPetAction moves and swaps slots, a book ability is placed
-- with PickupSpellBookItem(i, Pet) + PickupPetAction, and a remove plus a
-- re-place keeps autocast, which an addon can't set. Commands and stances
-- (tokens) are never removed: an addon can't put them back.
--
-- Plan only reads. The executor checks the cursor between calls, reads back
-- every op, and never clears a pet payload on failure: it is dropped back
-- into the slot its op emptied, or left on the cursor with the slot named.
------------------------------------------------------------

AltStableSync = AltStableSync or {}
local ASS = AltStableSync

local Pet = {}
ASS.Pet = Pet

local function G() return ASS.Game end
local function Copy(v) return ASS.Catalog.Copy(v) end

local SLOTS = 10

------------------------------------------------------------
-- Shape
------------------------------------------------------------

local function GoodSlot(s)
    if s == false then return true end
    if type(s) ~= "table" then return false end
    if s.kind == "token" then return type(s.token) == "string" and s.token ~= "" end
    if s.kind == "spell" then
        return type(s.id) == "number" and (s.name == nil or type(s.name) == "string")
    end
    return false
end

-- A family layout is usable only with all ten slots present and well
-- formed; anything else is damaged, never read as empty.
function Pet.Valid(layout)
    if type(layout) ~= "table" or type(layout.slots) ~= "table" then return false end
    for i = 1, SLOTS do
        local s = layout.slots[i]
        if s == nil or not GoodSlot(s) then return false end
    end
    return true
end

local function Locale()
    local ok, l = pcall(GetLocale)
    return ok and type(l) == "string" and l or nil
end

-- A slot as stored: the token, or the spell's id and name.
local function Stored(s)
    if not s then return false end
    if s.kind == "token" then return { kind = "token", token = s.token } end
    return { kind = "spell", id = s.id, name = s.name }
end

-- The pet that is out: { [familyId] = layout }, plus the pet; nil when no
-- pet with a bar is out; false when it can't be read (never partial).
function Pet.Capture()
    local pet = G().Pet()
    if pet == nil then return nil end
    if not pet then return false end
    local bar = G().PetBar()
    if not bar then return false end
    local slots = {}
    for i = 1, SLOTS do slots[i] = Stored(bar[i]) end
    return { [pet.family] = { family = pet.familyName, locale = Locale(), slots = slots } }, pet
end

-- Family names of the layouts in `mod`, other than `except`, sorted.
local function Others(mod, except)
    local names = {}
    for fam, layout in pairs(mod or {}) do
        if fam ~= except then names[#names + 1] = type(layout) == "table" and tostring(layout.family or fam) or tostring(fam) end
    end
    table.sort(names)
    return names
end

------------------------------------------------------------
-- Plan
------------------------------------------------------------

local function Key(x)
    if not x then return nil end
    if x.kind == "token" then return "t:" .. tostring(x.token) end
    return "s:" .. tostring(x.id)
end

-- The final ten slots from the current bar and the targets, and the ops
-- that get there with measured moves only. `targets[i]`: an item, false
-- (empty), or nil (skipped: `reasons[i]`). `book`: the pet book (an
-- ability is removed only when the book has it, so it can be placed back).
-- Returns { ops, final, skips = {{slot, reason}} }.
function Pet.Simulate(cur, targets, reasons, book)
    local frozen, why = {}, {}
    local changed
    local function freeze(i, reason)
        if frozen[i] then return end
        frozen[i], why[i], changed = true, reason, true
    end
    for i = 1, SLOTS do
        if targets[i] == nil then freeze(i, reasons[i] or "left unchanged") end
    end
    -- The same item twice in the target: the first slot keeps it.
    local seen = {}
    for i = 1, SLOTS do
        local k = not frozen[i] and Key(targets[i])
        if k then
            if seen[k] then freeze(i, "the loadout has it in another pet slot too") else seen[k] = i end
        end
    end
    -- Frozen slots are never a source, a destination or removed. Freezing
    -- one can make another unreachable, so this runs to a fixed point.
    repeat
        changed = false
        local wantAt, wantFrozen, at, onFrozen = {}, {}, {}, {}
        for j = 1, SLOTS do
            local k = Key(targets[j])
            if k then
                if frozen[j] then wantFrozen[k] = j else wantAt[k] = j end
            end
        end
        for i = 1, SLOTS do
            local k = Key(cur[i])
            if k then
                if frozen[i] then onFrozen[k] = i elseif not at[k] then at[k] = i end
            end
        end
        for i = 1, SLOTS do
            local x = cur[i]
            if x and not frozen[i] then
                local k = Key(x)
                if wantAt[k] and at[k] == i then
                    -- moves to its target
                elseif wantFrozen[k] and not wantAt[k] then
                    freeze(i, ("kept for pet slot %d, which is left unchanged"):format(wantFrozen[k]))
                elseif x.kind == "token" then
                    freeze(i, "a command stays: an addon can't put one back")
                elseif not book.byId[x.id] then
                    freeze(i, "holds something that couldn't be put back")
                end
            end
        end
        for j = 1, SLOTS do
            local t = targets[j]
            if t and not frozen[j] and not at[Key(t)] then
                if onFrozen[Key(t)] then
                    freeze(j, ("already in pet slot %d, which is left unchanged"):format(onFrozen[Key(t)]))
                elseif t.kind == "token" then
                    freeze(j, "this command isn't on this pet's bar")
                end
            end
        end
    until not changed

    -- The ops, on a simulated bar: (1) move what is wanted into place, (2)
    -- remove what nobody wants, (3) place the book abilities.
    local S, ops, done = {}, {}, {}
    for i = 1, SLOTS do S[i] = cur[i] or false end
    for j = 1, SLOTS do
        local t = targets[j]
        if t and not frozen[j] then
            local from
            if Key(S[j]) == Key(t) then from = j end
            for i = 1, SLOTS do
                if not from and not frozen[i] and not done[i] and Key(S[i]) == Key(t) then from = i end
            end
            if from and from ~= j then
                if S[j] then
                    ops[#ops + 1] = { op = "swap", from = from, to = j, item = Copy(S[from]), other = Copy(S[j]) }
                    S[from], S[j] = S[j], S[from]
                else
                    ops[#ops + 1] = { op = "move", from = from, to = j, item = Copy(S[from]) }
                    S[from], S[j] = false, S[from]
                end
            end
            if from then done[j] = true end
        end
    end
    for i = 1, SLOTS do
        if not frozen[i] and not done[i] and S[i] then
            ops[#ops + 1] = { op = "remove", from = i, item = Copy(S[i]) }
            S[i] = false
        end
    end
    for j = 1, SLOTS do
        local t = targets[j]
        if t and not frozen[j] and not done[j] then
            local b = t.kind == "spell" and book.byId[t.id]
            if b and not S[j] then
                ops[#ops + 1] = { op = "place", to = j, index = b.index, item = { kind = "spell", id = t.id, name = t.name or b.name } }
                S[j], done[j] = ops[#ops].item, true
            else
                why[j] = why[j] or "couldn't be reached"
                frozen[j] = true
            end
        end
    end
    local skips = {}
    for i = 1, SLOTS do
        -- A frozen slot is a skip when it doesn't already hold its target.
        if frozen[i] and (targets[i] == nil or Key(cur[i]) ~= Key(targets[i])) then
            skips[#skips + 1] = { slot = i, reason = why[i] }
        end
    end
    return { ops = ops, final = S, skips = skips }
end

-- A saved slot resolved for this pet. Returns the item, false (empty), or
-- nil plus a reason (skipped); a third value marks a verified absence.
local function ResolveLoad(want, book, sameLocale)
    if want == false then return false end
    if want.kind == "token" then return { kind = "token", token = want.token } end
    local b = book.byId[want.id]
    if b then return { kind = "spell", id = want.id, name = b.name } end
    if not sameLocale then return nil, "saved in another game language" end
    local list = type(want.name) == "string" and book.byName[want.name]
    if list and #list > 1 then return nil, "two pet abilities have this name" end
    if list and #list == 1 then return { kind = "spell", id = list[1].id, name = want.name } end
    return false, "this pet doesn't have it", true
end

-- Restore: exact, spells by id only.
local function ResolveExact(want, book)
    if want == false then return false end
    if want.kind == "token" then return { kind = "token", token = want.token } end
    if book.byId[want.id] then return { kind = "spell", id = want.id, name = want.name } end
    return nil, "this pet no longer has this rank"
end

-- The common part: the pet, its bar and book, and the simulation.
local function Build(pet, layoutSlots, resolve)
    local Game = G()
    local book = Game.PetBook()
    if not book.complete then return nil, "the pet spellbook couldn't be read" end
    local bar = Game.PetBar()
    if not bar then return nil, "the pet bar couldn't be read" end
    local targets, reasons, absent, wanted = {}, {}, {}, {}
    for i = 1, SLOTS do
        local t, why, gone = resolve(layoutSlots[i], book)
        targets[i], reasons[i] = t, why
        if gone then absent[i], wanted[i] = why, Pet.Describe(layoutSlots[i]) end
    end
    local sim = Pet.Simulate(bar, targets, reasons, book)
    return { guid = pet.guid, family = pet.family, familyName = pet.familyName, petName = pet.name,
             current = bar, ops = sim.ops, final = sim.final, skips = sim.skips, absent = absent, wanted = wanted }
end

-- The pet part of a Load plan, or nil when the entry has no pet bars. Its
-- `note` explains why nothing is written; `others` names the layouts kept
-- for other pets.
function Pet.PlanLoad(mod)
    if type(mod) ~= "table" or next(mod) == nil then return nil end
    local pet = G().Pet()
    if pet == nil then return { ops = {}, skips = {}, others = Others(mod), note = "no pet out" } end
    if not pet then return { ops = {}, skips = {}, others = Others(mod), note = "the pet couldn't be read", failed = true } end
    local others = Others(mod, pet.family)
    local layout = mod[pet.family]
    if layout == nil then
        return { ops = {}, skips = {}, others = others, familyName = pet.familyName, note = "no pet bar saved for this pet" }
    end
    if not Pet.Valid(layout) then
        return { ops = {}, skips = {}, others = others, familyName = pet.familyName, failed = true,
                 note = "the saved " .. pet.familyName .. " pet bar is damaged" }
    end
    local same = layout.locale ~= nil and layout.locale == Locale()
    local p, err = Build(pet, layout.slots, function(want, book) return ResolveLoad(want, book, same) end)
    if not p then
        return { ops = {}, skips = {}, others = others, familyName = pet.familyName, failed = true, note = err }
    end
    p.others, p.layout = others, true
    return p
end

-- The pet part of a restore from `snapPet`, or nil when the backup has none.
-- `missing`: the backup's pet isn't the one out (family and name).
function Pet.PlanRestore(snapPet)
    if type(snapPet) ~= "table" then return nil end
    local label = ("%s %s"):format(tostring(snapPet.familyName), tostring(snapPet.name))
    local pet = G().Pet()
    if not pet or pet.family ~= snapPet.family or pet.name ~= snapPet.name then
        return { ops = {}, skips = {}, missing = ("needs %s out"):format(label), label = label }
    end
    local p, err = Build(pet, snapPet.slots, ResolveExact)
    if not p then return { ops = {}, skips = {}, missing = err, label = label } end
    p.label = label
    return p
end

-- What a backup holds of the pet part of `pp`; nil when it can't be read
-- (then nothing is written).
function Pet.Snapshot(pp)
    local Game = G()
    local pet = Game.Pet()
    if not pet or pet.guid ~= pp.guid then return nil end
    local bar = Game.PetBar()
    if not bar then return nil end
    local slots = {}
    for i = 1, SLOTS do slots[i] = Stored(bar[i]) end
    return { family = pet.family, familyName = pet.familyName, guid = pet.guid, name = pet.name, slots = slots }
end

------------------------------------------------------------
-- Execute
------------------------------------------------------------

-- Run the pet ops of `pp`. Returns the number of ops done, or nil plus the
-- failure and where it happened.
function Pet.Execute(pp)
    local Game = G()
    local function guard()
        if InCombatLockdown() then return "combat" end
        local pet = Game.Pet()
        if not pet or pet.guid ~= pp.guid then return "the pet changed" end
        return nil
    end
    local function call(fn, ...)
        local why = guard()
        if why then return false, why end
        local ok, err = pcall(fn, ...)
        if not ok then return false, "client error: " .. tostring(err) end
        return true
    end
    local function holds() return (Game.CursorRaw()) == "petaction" end
    local function empty() return (Game.CursorRaw()) == nil end
    -- A failure inside an op. Whatever is on the cursor came from this op;
    -- it goes back into the slot the op emptied (`vacancy`) when that slot
    -- is still empty, else it stays on the cursor. Never cleared.
    local function stop(why, slot, vacancy)
        local at = "pet slot " .. tostring(slot)
        if empty() then return nil, why, at end
        if vacancy and holds() and not guard() and Game.PetSlot(vacancy) == nil then
            local ok = call(PickupPetAction, vacancy)
            if ok and empty() then
                return nil, ("%s; what was on the cursor went back to pet slot %d"):format(why, vacancy), at
            end
        end
        return nil, ("%s; the cursor holds a pet action: drop it into pet slot %d"):format(why, vacancy or slot), at
    end
    local function is(i, item) return Game.SamePetSlot(Game.PetSlot(i), item or nil) end
    local n = 0
    for _, op in ipairs(pp.ops) do
        if not empty() then return nil, "cursor not empty", "pet bar" end
        if op.op == "move" or op.op == "swap" then
            local i, j = op.from, op.to
            local ok, why = call(PickupPetAction, i)
            if not ok then return stop(why, i, i) end
            if not holds() or not is(i, nil) then return stop("pickup failed", i, i) end
            ok, why = call(PickupPetAction, j)
            if not ok then return stop(why, j, i) end
            if op.op == "move" then
                if not empty() then return stop("move failed", j, i) end
            else
                if not holds() or not is(j, op.item) then return stop("swap failed", j, i) end
                ok, why = call(PickupPetAction, i)
                if not ok then return stop(why, i, i) end
                if not empty() then return stop("swap failed", i, i) end
            end
            if not (is(j, op.item) and is(i, op.op == "swap" and op.other or nil)) then
                return stop("verify failed", j, i)
            end
        elseif op.op == "remove" then
            local i = op.from
            local ok, why = call(PickupPetAction, i)
            if not ok then return stop(why, i, i) end
            local kind, id = Game.CursorRaw()
            if kind ~= "petaction" or id ~= op.item.id or not is(i, nil) then return stop("pickup failed", i, i) end
            -- The one ClearCursor of a pet payload: an ability the pet's book
            -- has, taken off on purpose (it can be placed back).
            pcall(ClearCursor)
            if not empty() then return stop("cursor stuck", i, i) end
        elseif op.op == "place" then
            local j = op.to
            local ok, why = call(C_SpellBook.PickupSpellBookItem, op.index, Game.PET_BANK)
            if not ok then return stop(why, j, j) end
            if not holds() then return stop("pickup from the pet spellbook failed", j, j) end
            ok, why = call(PickupPetAction, j)
            if not ok then return stop(why, j, j) end
            if not empty() then return stop("place failed", j, j) end
            if not is(j, op.item) then return stop("verify failed", j, j) end
        end
        n = n + 1
    end
    for i = 1, SLOTS do
        if not is(i, pp.final[i]) then return nil, "verify failed", "pet slot " .. i end
    end
    return n
end

------------------------------------------------------------
-- Save: preserve intent, per family
------------------------------------------------------------

-- C unchanged since A: tokens by token, spells by id or by name (another
-- rank of the same ability, in the same game language).
local function SameSince(c, a)
    if not c or not a then return not c and not a end
    if c.kind ~= a.kind then return false end
    if c.kind == "token" then return c.token == a.token end
    if c.id == a.id then return true end
    return type(c.name) == "string" and c.name ~= "" and c.name == a.name
end

local function SameStored(x, y)
    if not x or not y then return not x and not y end
    return Key(x) == Key(y)
end

-- The pet part of a Save (pure). `bPet`: the entry's; `aPet`: the loaded
-- record's comparison; `cPet`: this capture (nil: no pet out; false:
-- unreadable). Returns the entry's pet module, the new comparison, and
-- { changed = {{slot, was, now}}, kept, dropped, added, notes, family }.
function Pet.Merge(bPet, aPet, cPet, drop)
    local out, adv = Copy(bPet), Copy(aPet)
    local info = { changed = {}, kept = {}, dropped = {}, notes = {} }
    if cPet == false then
        info.notes[#info.notes + 1] = "Couldn't read the pet bar, so pet bar changes aren't saved."
        return out, adv, info
    end
    if type(cPet) ~= "table" then return out, adv, info end
    local fam, c = next(cPet)
    local b, a = bPet and bPet[fam], aPet and aPet[fam]
    info.family = c.family
    adv = adv or {}
    if b == nil then
        out = out or {}
        out[fam] = Copy(c)
        adv[fam] = Copy(c)
        info.added = c.family
        return out, adv, info
    end
    if not Pet.Valid(b) then
        info.notes[#info.notes + 1] = ("The saved %s pet bar is damaged; it isn't changed."):format(c.family)
        return out, adv, info
    end
    if b.locale ~= c.locale then
        info.notes[#info.notes + 1] = ("The %s pet bar was saved in another game language; it isn't changed."):format(c.family)
        return out, adv, info
    end
    if not Pet.Valid(a) then
        adv[fam] = nil
        local differs = false
        for i = 1, SLOTS do if not SameSince(c.slots[i], b.slots[i]) then differs = true end end
        if differs then
            info.notes[#info.notes + 1] = ("Pet bar changes aren't saved: load this loadout with a %s out first."):format(c.family)
        end
        return out, adv, info
    end
    local slots, advSlots, unavailable = {}, {}, {}
    local was = a.unavailable or {}
    for i = 1, SLOTS do
        local bs, as, cs = b.slots[i], a.slots[i], c.slots[i]
        if was[i] and drop then
            slots[i], advSlots[i] = false, Copy(cs)
            if bs then info.dropped[#info.dropped + 1] = { slot = i, want = Copy(bs), reason = was[i] } end
        elseif was[i] then
            -- A gap the load couldn't fill: whatever is there now isn't
            -- saved over the loadout's slot.
            slots[i], advSlots[i], unavailable[i] = Copy(bs), Copy(as), was[i]
            if bs then info.kept[#info.kept + 1] = { slot = i, want = Copy(bs), reason = was[i] } end
        elseif SameSince(cs, as) then
            slots[i], advSlots[i] = Copy(bs), Copy(cs)
        else
            slots[i], advSlots[i] = Copy(cs), Copy(cs)
        end
        if not SameStored(slots[i], bs) then
            info.changed[#info.changed + 1] = { slot = i, was = Copy(bs), now = Copy(slots[i]) }
        end
    end
    out[fam] = { family = b.family, locale = b.locale, slots = slots }
    adv[fam] = { family = c.family, locale = c.locale, slots = advSlots,
                 unavailable = next(unavailable) and unavailable or nil }
    return out, adv, info
end

-- The slots a plan's pet part changes: { {slot, from, to} }.
function Pet.Changes(pp)
    local out = {}
    if not (pp and pp.final and pp.current) then return out end
    for i = 1, SLOTS do
        if Key(pp.current[i]) ~= Key(pp.final[i]) then
            out[#out + 1] = { slot = i, from = pp.current[i], to = pp.final[i] }
        end
    end
    return out
end

-- A pet slot as text.
function Pet.Describe(s)
    if not s then return "empty" end
    if s.kind == "token" then
        local names = { PET_ACTION_ATTACK = "Attack", PET_ACTION_FOLLOW = "Follow", PET_ACTION_MOVE_TO = "Move To",
                        PET_ACTION_WAIT = "Stay", PET_MODE_ASSIST = "Assist", PET_MODE_DEFENSIVEASSIST = "Defensive",
                        PET_MODE_PASSIVE = "Passive", PET_MODE_AGGRESSIVE = "Aggressive", PET_MODE_DEFENSIVE = "Defensive" }
        return names[s.token] or s.token
    end
    return tostring(s.name or ("spell " .. tostring(s.id)))
end
