------------------------------------------------------------
-- Loadout.lua - capture, plan, load and exact restore (#4, the vertical slice)
--
-- The agreed slice scope is issue #4's "Agreed slice scope" comment; the rules
-- are docs/DESIGN.md's safety model. In short:
--   - target set: action slots 1-12, the bindings of ACTIONBUTTON1-12, and the
--     character macros those slots need;
--   - Plan only reads; Load and Restore write, and only after the player
--     confirmed a preview of exactly the plan that is applied (stale = refuse);
--   - one guard before every write (no combat, the cursor as expected,
--     Character bindings for binding writes);
--   - the pre-write snapshot is pinned (Backups.Pin) before the first write;
--     any incomplete outcome leaves it pinned; there is no resume;
--   - every write is read back; no clear-before-import; account macros are
--     never created or edited; no macro is ever deleted.
------------------------------------------------------------

AltStableSync = AltStableSync or {}
local ASS = AltStableSync

local Loadout = {}
ASS.Loadout = Loadout

local function G() return ASS.Game end

local function PlayerClass()
    local _, class = UnitClass("player")
    return class
end

------------------------------------------------------------
-- Capture (for Save As): the slots, bindings and character macros
------------------------------------------------------------

-- modules = { actions = {[slot] = ...}, bindings = {[cmd] = {k1, k2}}, macros = {[name] = {body, icon}} }
function Loadout.Capture()
    local Game = G()
    local book = Game.Spellbook()
    local actions, macros = {}, {}
    for slot = Game.SLOTS.first, Game.SLOTS.last do
        local a = Game.ActionAt(slot)
        if a and a.kind == "spell" then
            local s = book.byId[a.id]
            local name = (s and s.name) or (C_Spell.GetSpellName and C_Spell.GetSpellName(a.id))
            -- A deliberate downrank: a low rank placed while the top rank is known.
            local exact = s and s.low and name and book.top[name] ~= nil
            actions[slot] = { kind = "spell", id = a.id, name = name, policy = exact and "exact" or "highest" }
        elseif a and a.kind == "item" then
            actions[slot] = { kind = "item", id = a.id }
        elseif a and a.kind == "macro" then
            actions[slot] = { kind = "macro", name = a.name, body = a.body, scope = a.scope }
            if a.scope == "char" then macros[a.name] = { body = a.body, icon = a.icon } end
        elseif a then
            actions[slot] = { kind = "unsupported", what = a.what }
        end
    end
    local bindings = {}
    for _, cmd in ipairs(Game.COMMANDS) do
        local k1, k2 = Game.KeysFor(cmd)
        bindings[cmd] = { k1, k2 }
    end
    return { actions = actions, bindings = bindings, macros = macros }
end

------------------------------------------------------------
-- Plan
------------------------------------------------------------

-- What blocks any write right now, or nil.
function Loadout.Blocked()
    if InCombatLockdown() then return "Paused in combat. Try again when combat ends." end
    local ready, why = ASS.Ready.IsReady()
    if not ready then return "Waiting for character data (" .. tostring(why) .. ")." end
    if not G().CursorEmpty() then return "Finish placing the item or spell on your cursor, then try again." end
    return nil
end

-- Resolve one wanted action against this character. Returns the target
-- action, or nil plus a skip reason; `create` marks a macro to create.
local function Resolve(want, modules, book)
    local Game = G()
    if want.kind == "spell" then
        if want.policy == "exact" then
            if Game.SpellKnown(want.id) then return { kind = "spell", id = want.id } end
            return nil, "rank not known"
        end
        local id = want.name and book.top[want.name]
        if id then return { kind = "spell", id = id } end
        return nil, "not learned"
    elseif want.kind == "item" then
        if Game.ItemCount(want.id) > 0 then return { kind = "item", id = want.id } end
        return nil, "not in bags"
    elseif want.kind == "macro" then
        local matches = Game.MacrosNamed(want.name)
        if want.scope == "account" then
            local m = matches[1]
            if #matches == 1 and m.scope == "account" and Game.Normalize(m.body) == Game.Normalize(want.body) then
                return { kind = "macro", name = m.name, body = m.body, scope = "account" }
            end
            return nil, "account macro missing"
        end
        local def = modules.macros and modules.macros[want.name]
        if not def then return nil, "macro definition missing" end
        if #matches == 0 then
            return { kind = "macro", name = want.name, body = def.body, scope = "char", icon = def.icon }, nil, true
        end
        local m = matches[1]
        if #matches == 1 and m.scope == "char" and Game.Normalize(m.body) == Game.Normalize(def.body) then
            return { kind = "macro", name = m.name, body = m.body, scope = "char" }
        end
        return nil, "macro name conflict"
    end
    return nil, "not supported yet"
end

-- plan = { kind = "load"|"restore", blocked, actions = {{slot, target, current}},
--          creates = {{name, body, icon}}, keys = {[key] = {to = cmd|false, from}},
--          keysBlocked, skips = {{slot, reason}}, noop, signature }
local function Signature(plan)
    local parts = {}
    for _, op in ipairs(plan.actions) do
        local t = op.target
        parts[#parts + 1] = ("%d>%s:%s:%s"):format(op.slot, t and t.kind or "clear",
            tostring(t and (t.id or t.name) or ""), tostring(op.current and (op.current.id or op.current.name) or ""))
    end
    for _, c in ipairs(plan.creates) do parts[#parts + 1] = "+" .. c.name end
    local keys = {}
    for k, v in pairs(plan.keys) do keys[#keys + 1] = k .. "=" .. tostring(v.to) .. "<" .. tostring(v.from) end
    table.sort(keys)
    for _, k in ipairs(keys) do parts[#parts + 1] = k end
    return table.concat(parts, "|")
end

local function Finish(plan)
    plan.noop = #plan.actions == 0 and #plan.creates == 0 and next(plan.keys) == nil
    plan.signature = Signature(plan)
    return plan
end

-- The binding part of a plan: one final key -> command|unbound map.
local function PlanKeys(plan, wantKeys)
    local Game = G()
    if not Game.CharacterBindings() then
        plan.keysBlocked = "Enable character-specific keybindings in WoW settings, then try again."
        return
    end
    local want = {}
    for cmd, keys in pairs(wantKeys) do
        for _, key in ipairs({ keys[1], keys[2] }) do
            if key then
                if want[key] and want[key] ~= cmd then
                    plan.keysBlocked = "This loadout binds " .. key .. " twice."
                    return
                end
                want[key] = cmd
            end
        end
    end
    -- Keys that hold one of these commands now but aren't wanted for it.
    for cmd in pairs(wantKeys) do
        local k1, k2 = Game.KeysFor(cmd)
        for _, key in ipairs({ k1, k2 }) do
            if key and want[key] == nil then want[key] = false end
        end
    end
    for key, cmd in pairs(want) do
        local from = Game.CommandOf(key)
        if from ~= cmd then plan.keys[key] = { to = cmd, from = from } end
    end
end

function Loadout.Plan(entry)
    local Game = G()
    local plan = { kind = "load", entryId = entry.id, version = entry.version, name = entry.name,
                   actions = {}, creates = {}, keys = {}, skips = {} }
    if entry.kind ~= "loadout" then plan.blocked = "Not a loadout." return Finish(plan) end
    if entry.class ~= PlayerClass() then
        plan.blocked = "This loadout is for another class." return Finish(plan)
    end
    plan.blocked = Loadout.Blocked()
    if plan.blocked then return Finish(plan) end
    local modules = entry.modules or {}
    local book = Game.Spellbook()
    local creating, charCount = {}, Game.CharMacroCount()
    for slot = Game.SLOTS.first, Game.SLOTS.last do
        local want = modules.actions and modules.actions[slot]
        if want then
            local target, why, create = Resolve(want, modules, book)
            local current = Game.ActionAt(slot)
            if target and create and not creating[target.name] then
                if charCount + #plan.creates >= Game.MAX_CHAR_MACROS then
                    target, why = nil, "macro slots full"
                else
                    creating[target.name] = true
                    plan.creates[#plan.creates + 1] = { name = target.name, body = target.body, icon = target.icon }
                end
            end
            if target and current and current.kind == "unsupported" then
                target, why = nil, "slot holds something this slice can't restore"
            end
            if not target then
                plan.skips[#plan.skips + 1] = { slot = slot, reason = why }
            elseif not Game.SameAction(current, target) then
                plan.actions[#plan.actions + 1] = { slot = slot, target = target, current = current }
            end
        end
    end
    if modules.bindings then PlanKeys(plan, modules.bindings) end
    return Finish(plan)
end

------------------------------------------------------------
-- Execute (shared by load and restore)
------------------------------------------------------------

local function Guard(forBindings)
    if InCombatLockdown() then return "combat" end
    if forBindings and not G().CharacterBindings() then return "binding set changed" end
    return nil
end

-- The exact pre-write snapshot of everything `plan` touches.
local function Snapshot(plan, reason)
    local Game = G()
    local snap = { reason = reason, actions = {}, keys = {}, createdMacros = {},
                   characterBindings = Game.CharacterBindings() }
    for _, op in ipairs(plan.actions) do
        local a = Game.ActionAt(op.slot)
        snap.actions[op.slot] = a or false
    end
    for key in pairs(plan.keys) do snap.keys[key] = Game.CommandOf(key) end
    return snap
end

-- Run `plan`; `snap` is its pinned (load) or ring (restore) snapshot.
-- Returns result = { done = {...}, failed = reason|nil, at = what }.
local function Execute(plan, snap)
    local Game = G()
    local result = { changed = 0, created = 0, keys = 0 }
    local function fail(why, at) result.failed, result.at = why, at; return result end
    -- An action-phase failure. The cursor was empty when the operation began
    -- (Blocked refuses otherwise) and it runs within one frame, so anything on
    -- it now came from this operation: our own pickup, or a slot's displaced
    -- content, which the snapshot already holds. Drop it rather than leave a
    -- stray action on the player's cursor; restoring `op` puts it back.
    local function bail(why, at)
        if not Game.CursorEmpty() then pcall(ClearCursor) end
        return fail(why, at)
    end

    -- 1. Character macros, then verify each by name + normalised body.
    for _, c in ipairs(plan.creates) do
        local why = Guard(); if why then return fail(why, "macro " .. c.name) end
        local ok = pcall(CreateMacro, c.name, c.icon or "INV_Misc_QuestionMark", c.body, true)
        local matches = Game.MacrosNamed(c.name)
        if not ok or #matches ~= 1 or matches[1].scope ~= "char"
            or Game.Normalize(matches[1].body) ~= Game.Normalize(c.body) then
            return fail("macro not created", "macro " .. c.name)
        end
        snap.createdMacros[#snap.createdMacros + 1] = { name = c.name, body = c.body }
        result.created = result.created + 1
    end

    -- 2. Actions: pick up, check the cursor, place, handle the displaced
    -- action, read back. Macro indices are looked up NOW (creation shifts them).
    for _, op in ipairs(plan.actions) do
        local why = Guard(); if why then return fail(why, "slot " .. op.slot) end
        if not Game.CursorEmpty() then return bail("cursor not empty", "slot " .. op.slot) end
        local t = op.target
        if t then
            if t.kind == "spell" then C_Spell.PickupSpell(t.id)
            elseif t.kind == "item" then C_Item.PickupItem(t.id)
            elseif t.kind == "macro" then
                local m = Game.MacrosNamed(t.name)
                if #m ~= 1 then return bail("macro not unique", "slot " .. op.slot) end
                PickupMacro(m[1].index)
            end
            if not Game.SameAction(Game.Cursor(), t) then return bail("pickup failed", "slot " .. op.slot) end
            PlaceAction(op.slot)
        else
            -- Restoring an empty slot: lift what is there, then drop it.
            PickupAction(op.slot)
        end
        -- What the cursor holds now must be exactly the slot's previous
        -- content (already in the snapshot), or nothing. ClearCursor is not
        -- a protected write; clearing our own displaced payload is allowed
        -- even if combat began this frame.
        local held = Game.Cursor()
        if held then
            if t and Game.SameAction(held, t) and not Game.SameAction(Game.ActionAt(op.slot), t) then
                return bail("place failed", "slot " .. op.slot)      -- our pickup never landed
            end
            if not Game.SameAction(held, snap.actions[op.slot] or nil) then
                return bail("unexpected item on cursor", "slot " .. op.slot)
            end
            pcall(ClearCursor)
        end
        if not Game.SameAction(Game.ActionAt(op.slot), t) then return bail("verify failed", "slot " .. op.slot) end
        result.changed = result.changed + 1
    end

    -- 3. Bindings: the final map, each key once, read back whole before saving.
    if next(plan.keys) then
        local why = Guard(true); if why then return fail(why, "bindings") end
        for key, v in pairs(plan.keys) do pcall(SetBinding, key, v.to or nil) end
        local ok = true
        for key, v in pairs(plan.keys) do
            if Game.CommandOf(key) ~= v.to then ok = false end
        end
        why = Guard(true)
        if not ok or why then
            for key in pairs(plan.keys) do pcall(SetBinding, key, snap.keys[key] or nil) end
            return fail(why or "bindings failed", "bindings")
        end
        local saved = pcall(SaveBindings, Enum.BindingSet.Character)
        for key, v in pairs(plan.keys) do
            if Game.CommandOf(key) ~= v.to then saved = false end
        end
        if not saved then return fail("bindings not saved", "bindings") end
        for _ in pairs(plan.keys) do result.keys = result.keys + 1 end
    end
    return result
end

------------------------------------------------------------
-- Load
------------------------------------------------------------

-- Apply the plan the player confirmed. `shown` is that plan; `abandon` is
-- the player's answer to "Abandon the incomplete load of X?".
function Loadout.Load(entry, shown, abandon)
    local plan = Loadout.Plan(entry)
    if plan.blocked then return nil, plan.blocked end
    if plan.signature ~= shown.signature then return nil, "Something changed since the preview: review it again." end
    local pinned = ASS.Backups.Operation()
    if pinned then
        if not abandon then return nil, "incomplete" end
        ASS.Backups.Release()
    end
    local function record(result)
        ASS.char.loaded = ASS.char.loaded or {}
        ASS.char.loaded.loadout = { id = entry.id, version = entry.version,
                                    requested = ASS.Catalog.Copy(entry.modules), result = result }
    end
    if plan.noop then
        record({ noop = true })
        return { noop = true, skips = plan.skips }
    end
    local snap = Snapshot(plan, "load " .. tostring(entry.name))
    local ok, err = ASS.Backups.Pin(snap, { kind = "load", id = entry.id, version = entry.version, name = entry.name })
    if not ok then return nil, err end
    local result = Execute(plan, snap)
    result.skips = plan.skips
    record(result)
    if result.failed then
        ASS.char.interrupted = { id = entry.id, version = entry.version, why = result.failed, at = result.at }
        return result
    end
    ASS.char.interrupted = nil
    ASS.Backups.Release()
    return result
end

------------------------------------------------------------
-- Restore (exact)
------------------------------------------------------------

function Loadout.PlanRestore(which)
    local Game = G()
    local snap = ASS.Backups.Get(which)
    local plan = { kind = "restore", which = which, actions = {}, creates = {}, keys = {}, skips = {}, unavailable = {} }
    if not snap then plan.blocked = "No such backup." return Finish(plan) end
    plan.blocked = Loadout.Blocked()
    if plan.blocked then return Finish(plan) end
    for slot, want in pairs(snap.actions or {}) do
        local current = Game.ActionAt(slot)
        local target, why
        if want == false then
            target = nil
        elseif want.kind == "spell" then
            if Game.SpellKnown(want.id) then target = { kind = "spell", id = want.id } else why = "spell no longer known" end
        elseif want.kind == "item" then
            if Game.ItemCount(want.id) > 0 then target = { kind = "item", id = want.id } else why = "item not in bags" end
        elseif want.kind == "macro" then
            local m = Game.MacrosNamed(want.name)
            if #m == 1 and m[1].scope == want.scope and Game.Normalize(m[1].body) == Game.Normalize(want.body) then
                target = { kind = "macro", name = want.name, body = m[1].body, scope = want.scope }
            else
                why = "macro gone or changed"
            end
        else
            why = "not restorable"
        end
        if why then
            plan.unavailable[#plan.unavailable + 1] = { slot = slot, reason = why }
        elseif current and current.kind == "unsupported" then
            plan.unavailable[#plan.unavailable + 1] = { slot = slot, reason = "slot now holds something this slice can't restore" }
        elseif not Game.SameAction(current, target) then
            plan.actions[#plan.actions + 1] = { slot = slot, target = target, current = current }
        end
    end
    table.sort(plan.actions, function(a, b) return a.slot < b.slot end)
    if snap.keys and next(snap.keys) then
        if not Game.CharacterBindings() then
            plan.keysBlocked = "Enable character-specific keybindings in WoW settings, then try again."
        else
            for key, cmd in pairs(snap.keys) do
                local from = Game.CommandOf(key)
                if from ~= cmd then plan.keys[key] = { to = cmd, from = from } end
            end
        end
    end
    plan.kept = snap.createdMacros or {}
    return Finish(plan)
end

function Loadout.Restore(which, shown)
    local plan = Loadout.PlanRestore(which)
    if plan.blocked then return nil, plan.blocked end
    if plan.signature ~= shown.signature then return nil, "Something changed since the preview: review it again." end
    if plan.noop then
        if which == "op" then ASS.Backups.Release() end
        return { noop = true, unavailable = plan.unavailable, kept = plan.kept }
    end
    local snap = Snapshot(plan, "restore")
    ASS.Backups.PushRing(snap)
    local result = Execute(plan, snap)
    result.unavailable, result.kept = plan.unavailable, plan.kept
    result.partial = (#plan.unavailable > 0) or nil
    if not result.failed and which == "op" then
        ASS.Backups.Release()
        ASS.char.interrupted = nil
    end
    return result
end
