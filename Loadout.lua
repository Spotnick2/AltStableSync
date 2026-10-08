------------------------------------------------------------
-- Loadout.lua - capture, plan, load and exact restore (#4, the vertical slice)
--
-- The agreed slice scope is issue #4's "Agreed slice scope" comment; the rules
-- are docs/DESIGN.md's safety model. In short:
--   - target set: action slots 1-12, the bindings of ACTIONBUTTON1-12, and the
--     character macros those slots need;
--   - Plan only reads; Load and Restore write, and only after the player
--     confirmed a preview of exactly the plan that is applied: the whole plan
--     is compared at confirmation, and any difference refuses;
--   - a guard runs before EVERY protected call (no combat; Character bindings
--     for binding writes), and every client call is pcall'd;
--   - the pre-write snapshot is pinned (Backups.Pin) before the first write;
--     any incomplete outcome leaves it pinned; there is no resume;
--   - a slot is replaced only if its current content can be put back exactly;
--   - every write is read back; no clear-before-import; account macros are
--     never created or edited; no macro is ever deleted; the cursor is never
--     left holding something.
------------------------------------------------------------

AltStableSync = AltStableSync or {}
local ASS = AltStableSync

local Loadout = {}
ASS.Loadout = Loadout

local function G() return ASS.Game end

-- Per-character: bindings were changed in memory and not yet saved. Set
-- before the first SetBinding, cleared by a successful SaveBindings (or a
-- verified rollback); while set, the next load or restore saves even when
-- every key already matches, so nothing unsaved is mistaken for done.
local function Unsaved() return ASS.char and ASS.char.bindingsUnsaved end
local function SetUnsaved(v) if ASS.char then ASS.char.bindingsUnsaved = v or nil end end

-- An authored macro body is at most 254 characters (the server appends a
-- newline; docs/forever-api-notes.md).
local MACRO_MAX = 254

local function PlayerClass()
    local _, class = UnitClass("player")
    return class
end

-- A deterministic text form of a plain table (sorted keys), for comparing a
-- confirmed plan with a fresh one.
local function Serialize(v)
    local t = type(v)
    if t ~= "table" then return t:sub(1, 1) .. tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. Serialize(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
end

------------------------------------------------------------
-- Capture (for Save As): the slots, bindings and character macros
------------------------------------------------------------

-- modules = { actions = {[slot] = ...}, bindings = {[cmd] = {key, ...}}, macros = {[name] = {body, icon}} }
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
        local keys = Game.KeysFor(cmd)
        if not keys then return nil, "Couldn't read the key bindings; try again." end
        bindings[cmd] = keys
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
            if Game.SpellKnown(want.id, book) then return { kind = "spell", id = want.id } end
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
        if not matches then return nil, "macros unreadable" end
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
            local body = Game.Normalize(def.body)
            if #body > MACRO_MAX then return nil, "macro too long" end
            return { kind = "macro", name = want.name, body = body, scope = "char", icon = def.icon }, nil, true
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
--          keysBlocked, skips = {{slot, reason}}, unavailable, noop, fingerprint }
local function Finish(plan)
    plan.noop = #plan.actions == 0 and #plan.creates == 0 and next(plan.keys) == nil and not plan.resave
    plan.fingerprint = Serialize({ v = plan.version, w = plan.which, a = plan.actions, c = plan.creates,
                                   k = plan.keys, kb = plan.keysBlocked or false, s = plan.skips,
                                   r = plan.resave or false,
                                   u = plan.unavailable or {}, b = plan.blocked or false })
    return plan
end

local KEYS_BLOCKED = "Enable character-specific keybindings in WoW settings, then try again."

-- The binding part of a plan: one final key -> command|unbound map. A
-- command the entry has no key for is left alone (an empty entry never
-- erases), and a load that has keys to set is blocked, not partly applied,
-- while Account bindings are active (#7: block and explain, never switch).
local function PlanKeys(plan, wantKeys)
    local Game = G()
    local has = {}
    for cmd, keys in pairs(wantKeys) do
        for i = 1, table.maxn(keys) do
            if type(keys[i]) == "string" and keys[i] ~= "" then has[cmd] = keys end
        end
    end
    if next(has) == nil then return end
    if not Game.CharacterBindings() then plan.blocked = KEYS_BLOCKED return end
    local want = {}
    for cmd, keys in pairs(has) do
        -- By position up to maxn: a missing first key never hides the second.
        for i = 1, table.maxn(keys) do
            local key = keys[i]
            if type(key) == "string" and key ~= "" then
                if want[key] and want[key] ~= cmd then
                    plan.keysBlocked = "This loadout binds " .. key .. " twice."
                    return
                end
                want[key] = cmd
            end
        end
    end
    -- Every key that holds one of these commands now but isn't wanted for it.
    for cmd in pairs(has) do
        local current = Game.KeysFor(cmd)
        if not current then plan.blocked = "Couldn't read the key bindings; try again." return end
        for _, key in ipairs(current) do
            if want[key] == nil then want[key] = false end
        end
    end
    for key, cmd in pairs(want) do
        local from = Game.CommandOf(key)
        if from == nil then plan.blocked = "Couldn't read the key bindings; try again." return end
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
            if target and not Game.Restorable(current) then
                target, why = nil, "slot holds something this slice can't put back"
            end
            if target and not Game.SameAction(current, target) and create and not creating[target.name] then
                if charCount + #plan.creates >= Game.MAX_CHAR_MACROS then
                    target, why = nil, "macro slots full"
                else
                    creating[target.name] = true
                    plan.creates[#plan.creates + 1] = { name = target.name, body = target.body, icon = target.icon }
                end
            end
            if not target then
                plan.skips[#plan.skips + 1] = { slot = slot, reason = why }
            elseif not Game.SameAction(current, target) then
                plan.actions[#plan.actions + 1] = { slot = slot, target = target, current = current }
            end
        end
    end
    if modules.bindings then PlanKeys(plan, modules.bindings) end
    if Unsaved() and Game.CharacterBindings() then plan.resave = true end
    if plan.blocked then plan.actions, plan.creates, plan.keys, plan.resave = {}, {}, {}, nil end
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
        -- A slot read that fails (or reads back something this slice can't
        -- put back) means no backup, so no writes.
        if not Game.Restorable(a) then return nil end
        snap.actions[op.slot] = a or false
    end
    for key in pairs(plan.keys) do
        local cmd = Game.CommandOf(key)
        if cmd == nil then return nil end           -- unreadable: no backup, so no writes
        snap.keys[key] = cmd
    end
    return snap
end

-- Run `plan`; `snap` is its pinned (load) or ring (restore) snapshot.
-- Returns result = { changed, created, keys, failed = reason|nil, at }.
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
        if not Game.CursorEmpty() then
            pcall(ClearCursor)
            if not Game.CursorEmpty() then why = why .. "; the cursor still holds something" end
        end
        return fail(why, at)
    end
    -- A protected client call, guarded first and pcall'd.
    local function call(forBindings, fn, ...)
        local why = Guard(forBindings)
        if why then return false, why end
        local ok, ret = pcall(fn, ...)
        if not ok then return false, "client error: " .. tostring(ret) end
        return true
    end

    -- 1. Character macros, then verify each by name + normalised body.
    for _, c in ipairs(plan.creates) do
        local ok, why = call(false, CreateMacro, c.name, c.icon or "INV_Misc_QuestionMark", c.body, true)
        if not ok then return fail(why, "macro " .. c.name) end
        local matches = Game.MacrosNamed(c.name)
        if not matches or #matches ~= 1 or matches[1].scope ~= "char"
            or Game.Normalize(matches[1].body) ~= Game.Normalize(c.body) then
            return fail("macro not created", "macro " .. c.name)
        end
        snap.createdMacros[#snap.createdMacros + 1] = { index = matches[1].index, name = c.name, body = c.body }
        result.created = result.created + 1
    end

    -- 2. Actions: pick up, check the cursor, place, handle the displaced
    -- action, read back. Macro indices are looked up NOW (creation shifts them).
    for _, op in ipairs(plan.actions) do
        local at = "slot " .. op.slot
        if not Game.CursorEmpty() then return bail("cursor not empty", at) end
        local t = op.target
        local ok, why
        if t then
            if t.kind == "spell" then ok, why = call(false, C_Spell.PickupSpell, t.id)
            elseif t.kind == "item" then ok, why = call(false, C_Item.PickupItem, t.id)
            else
                local m = Game.MacrosNamed(t.name)
                if not m or #m ~= 1 then return bail("macro not unique", at) end
                ok, why = call(false, PickupMacro, m[1].index)
            end
            if not ok then return bail(why, at) end
            if not Game.SameAction(Game.Cursor(), t) then return bail("pickup failed", at) end
            ok, why = call(false, PlaceAction, op.slot)
        else
            -- Restoring an empty slot: lift what is there, then drop it.
            ok, why = call(false, PickupAction, op.slot)
        end
        if not ok then return bail(why, at) end
        -- What the cursor holds now must be exactly the slot's previous
        -- content (already in the snapshot), or nothing. ClearCursor is not a
        -- protected call, so clearing our own displaced payload is allowed even
        -- if combat began this frame.
        local held = Game.Cursor()
        if held and held.kind == "unreadable" then return bail("cursor unreadable", at) end
        if held then
            if t and Game.SameAction(held, t) and not Game.SameAction(Game.ActionAt(op.slot), t) then
                return bail("place failed", at)      -- our pickup never landed
            end
            if not Game.SameAction(held, snap.actions[op.slot] or nil) then
                return bail("unexpected item on cursor", at)
            end
            pcall(ClearCursor)
            if not Game.CursorEmpty() then return bail("cursor stuck", at) end
        end
        if not Game.SameAction(Game.ActionAt(op.slot), t) then return bail("verify failed", at) end
        result.changed = result.changed + 1
    end
    if #plan.actions > 0 and not Game.CursorEmpty() then return bail("cursor not empty after the actions", "actions") end

    -- 3. Bindings: the final map, each key once, guarded each time; read back
    -- whole before saving; on any failure (saving included) rolled back in
    -- memory and the rollback read back too.
    if next(plan.keys) or plan.resave then
        local wasUnsaved = Unsaved()
        local function rollback(why)
            for key in pairs(plan.keys) do
                if Game.CommandOf(key) ~= snap.keys[key] then call(true, SetBinding, key, snap.keys[key] or nil) end
            end
            for key in pairs(plan.keys) do
                if Game.CommandOf(key) ~= snap.keys[key] then
                    return fail(why .. "; some keys couldn't be put back (not saved)", "bindings")
                end
            end
            SetUnsaved(wasUnsaved)
            return fail(why, "bindings")
        end
        if next(plan.keys) then SetUnsaved(true) end
        for key, v in pairs(plan.keys) do
            local ok, why = call(true, SetBinding, key, v.to or nil)
            if not ok then return rollback(why) end
        end
        for key, v in pairs(plan.keys) do
            if Game.CommandOf(key) ~= v.to then return rollback("bindings failed") end
        end
        local saved, why = call(true, SaveBindings, Enum.BindingSet.Character)
        if not saved then return rollback("bindings not saved (" .. tostring(why) .. ")") end
        SetUnsaved(nil)
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
    -- The catalog's CURRENT entry: a sync or another command may have replaced
    -- or deleted it since the preview (its version is in the fingerprint).
    local live = ASS.Catalog.Get(entry.id)
    if not live or live.deleted then return nil, "That loadout was deleted since the preview." end
    entry = live
    local plan = Loadout.Plan(entry)
    if plan.blocked then return nil, plan.blocked end
    if plan.fingerprint ~= shown.fingerprint then return nil, "Something changed since the preview: review it again." end
    local pinned = ASS.Backups.Operation()
    if pinned and not abandon then return nil, "incomplete" end
    local function abandonPinned()
        if pinned then ASS.Backups.Release(); ASS.char.interrupted = nil end
    end
    local function record(result)
        ASS.char.loaded = ASS.char.loaded or {}
        ASS.char.loaded.loadout = { id = entry.id, version = entry.version,
                                    baseline = ASS.Catalog.Copy(entry.modules), result = result }
    end
    if plan.noop then
        abandonPinned()
        record({ noop = true, skips = plan.skips })
        return { noop = true, skips = plan.skips, changed = 0, created = 0, keys = 0 }
    end
    local snap = Snapshot(plan, "load " .. tostring(entry.name))
    if not snap then return nil, "Couldn't read the current setup for the backup; nothing was changed." end
    abandonPinned()               -- only now: nothing above can fail after this
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
    local book = Game.Spellbook()
    local slots = {}
    for slot in pairs(snap.actions or {}) do slots[#slots + 1] = slot end
    table.sort(slots)
    for _, slot in ipairs(slots) do
        local want = snap.actions[slot]
        local current = Game.ActionAt(slot)
        local target, why
        if want == false then
            target = nil
        elseif want.kind == "spell" then
            if Game.SpellKnown(want.id, book) then target = { kind = "spell", id = want.id } else why = "spell no longer known" end
        elseif want.kind == "item" then
            if Game.ItemCount(want.id) > 0 then target = { kind = "item", id = want.id } else why = "item not in bags" end
        elseif want.kind == "macro" then
            local m = Game.MacrosNamed(want.name)
            if m and #m == 1 and m[1].scope == want.scope and Game.Normalize(m[1].body) == Game.Normalize(want.body) then
                target = { kind = "macro", name = want.name, body = m[1].body, scope = want.scope }
            else
                why = "macro gone or changed"
            end
        else
            why = "not restorable"
        end
        if not why and not Game.SameAction(current, target) and not Game.Restorable(current) then
            why = "slot now holds something that couldn't be put back"
        end
        if why then
            plan.unavailable[#plan.unavailable + 1] = { slot = slot, reason = why }
        elseif not Game.SameAction(current, target) then
            plan.actions[#plan.actions + 1] = { slot = slot, target = target, current = current }
        end
    end
    if snap.keys and next(snap.keys) then
        if not Game.CharacterBindings() then
            plan.keysBlocked = KEYS_BLOCKED
        else
            -- Only real differences; unsaved earlier changes are covered by
            -- plan.resave below.
            for key, cmd in pairs(snap.keys) do
                local from = Game.CommandOf(key)
                if from == nil then plan.blocked = "Couldn't read the key bindings; try again." break end
                if from ~= cmd then plan.keys[key] = { to = cmd, from = from } end
            end
        end
    end
    plan.kept = snap.createdMacros or {}
    if Unsaved() and Game.CharacterBindings() then plan.resave = true end
    if plan.blocked then plan.actions, plan.keys, plan.resave = {}, {}, nil end
    return Finish(plan)
end

-- Is everything the snapshot asks for back (nothing unavailable or blocked)?
local function Complete(plan, result)
    return not (result and result.failed) and #plan.unavailable == 0 and not plan.keysBlocked
end

function Loadout.Restore(which, shown)
    local plan = Loadout.PlanRestore(which)
    if plan.blocked then return nil, plan.blocked end
    if plan.fingerprint ~= shown.fingerprint then return nil, "Something changed since the preview: review it again." end
    local result
    if plan.noop then
        result = { noop = true, changed = 0, created = 0, keys = 0 }
    else
        local snap = Snapshot(plan, "restore")
        if not snap then return nil, "Couldn't read the current setup for the backup; nothing was changed." end
        ASS.Backups.PushRing(snap, ASS.Backups.Get(which))
        result = Execute(plan, snap)
    end
    result.unavailable, result.kept = plan.unavailable, plan.kept
    result.keysBlocked = plan.keysBlocked
    result.partial = not Complete(plan, result) or nil
    -- The pinned operation is released only when it is fully restored.
    if which == "op" and Complete(plan, result) then
        ASS.Backups.Release()
        ASS.char.interrupted = nil
    end
    return result
end
