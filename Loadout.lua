------------------------------------------------------------
-- Loadout.lua - capture, plan, load and exact restore (#4, the vertical slice)
--
-- The agreed slice scope is issue #4's "Agreed slice scope" comment; the rules
-- are docs/DESIGN.md's safety model. In short:
--   - target set: the measured action slots (Game.SLOT_RANGES, #5), the
--     bindings of ACTIONBUTTON1-12 and the pet bar's BONUSACTIONBUTTON1-10, and the character macros those slots need;
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

-- modules = { actions = {[slot] = ...}, bindings = {[cmd] = {key, ...}}, macros = {[name] = {body, icon}},
--             cover = the slot ranges captured (#5), pet = {[familyId] = layout} (#47, Pet.lua) }
function Loadout.Capture()
    local Game = G()
    local book = Game.Spellbook()
    local actions, macros = {}, {}
    -- Rank policy (#42). Caster bars keep an old rank after training (hunter
    -- bars update), so one low rank alone is stale, not a choice: "highest".
    -- A spell on the bars at several ranks is a healer's mana ladder: the
    -- highest of them follows the trainer, the lower ones stay "exact".
    -- Rank order is book order; the measured low-rank flag wins, so the
    -- known top rank always ranks highest. A ladder needs both ranks on
    -- screen together (#5): Action Bar 1's pages and the stance/form pages
    -- replace one another, so a rank left under a stance page (or on the
    -- other page) never makes one on another page "exact".
    local function rank(s) return s.low and s.order or math.huge end
    local seen, pageTop, anyTop = {}, {}, {}
    for _, slot in ipairs(Game.SLOT_LIST) do
        local a = Game.ActionAt(slot)
        seen[slot] = a
        local s = a and a.kind == "spell" and book.byId[a.id]
        if s then
            local page = Game.MainPage(slot) or 0
            pageTop[page] = pageTop[page] or {}
            if (pageTop[page][s.name] or 0) < rank(s) then pageTop[page][s.name] = rank(s) end
            if (anyTop[s.name] or 0) < rank(s) then anyTop[s.name] = rank(s) end
        end
    end
    -- The highest rank of `name` that can be on screen with `slot`.
    local function ladderTop(slot, name)
        local page = Game.MainPage(slot)
        if not page then return anyTop[name] end
        return math.max((pageTop[page] or {})[name] or 0, (pageTop[0] or {})[name] or 0)
    end
    for _, slot in ipairs(Game.SLOT_LIST) do
        local a = seen[slot]
        if a and a.kind == "spell" then
            local s = book.byId[a.id]
            local name = (s and s.name) or (C_Spell.GetSpellName and C_Spell.GetSpellName(a.id))
            local exact = s and rank(s) < ladderTop(slot, s.name)
            actions[slot] = { kind = "spell", id = a.id, name = name, policy = exact and "exact" or "highest" }
            -- From a class tab (not General, not a profession): a Load may
            -- empty its slot on a character that hasn't learned it (#46).
            if s and s.line and s.line > 1 then actions[slot].class = true end
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
    -- The pet bar of the pet that is out (#47): nil when none is, false when
    -- it can't be read.
    local pet = ASS.Pet.Capture()
    return { actions = actions, bindings = bindings, macros = macros, cover = ASS.Catalog.Copy(Game.SLOT_RANGES),
             pet = pet }
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
-- action, or nil plus a skip reason; then `create` marks a macro to create,
-- or `edit` = { from = { body, icon }, to = { body, icon } } a character
-- macro of that name to update (#6). `opts.noCharMacros`: the player left
-- character macros out, so their slots are left as they are.
local function Resolve(want, modules, book, opts)
    local Game = G()
    if want.kind == "spell" then
        -- Absent only when the whole book read and the client says no by id
        -- too: profession spells may not be in the class skill lines.
        local function absent(reason)
            local k = Game.SpellKnownById(want.id)
            if k then return { kind = "spell", id = want.id } end
            if k ~= false or not book.complete then return nil, "spellbook unreadable" end
            -- Forever lists no unlearned spells: only a spell captured from a
            -- class tab is one this character can still learn. A racial, a
            -- profession or an unmarked (older) entry leaves the slot alone.
            if want.class ~= true then return nil, "not marked as a class spell" end
            return nil, reason
        end
        if want.policy == "exact" then
            if book.byId[want.id] then return { kind = "spell", id = want.id } end
            return absent("rank not known")
        end
        if type(want.name) ~= "string" then return nil, "spell name unknown" end
        local id = book.top[want.name]
        if id then return { kind = "spell", id = id } end
        -- "Highest" needs a verified top rank: with an incomplete scan a known
        -- id may be a lower rank (Codex on #48), so nothing is placed.
        if not book.complete then return nil, "spellbook unreadable" end
        return absent("not learned")
    elseif want.kind == "item" then
        local n = Game.ItemCountRead(want.id)
        if n == nil then return nil, "items unreadable" end
        if n > 0 then return { kind = "item", id = want.id } end
        return nil, "not in bags"
    elseif want.kind == "macro" then
        local matches = Game.MacrosNamed(want.name)
        if not matches then return nil, "macros unreadable" end
        if want.scope == "account" then
            local m = matches[1]
            if #matches == 1 and m.scope == "account" and Game.Normalize(m.body) == Game.Normalize(want.body) then
                return { kind = "macro", name = m.name, body = m.body, scope = "account" }
            end
            -- Only a name nobody uses is "missing" (#46 empties that slot);
            -- a different macro of that name is left alone.
            return nil, #matches == 0 and "account macro missing" or "account macro differs"
        end
        if opts and opts.noCharMacros then return nil, "character macros not included" end
        local def = modules.macros and modules.macros[want.name]
        if not def then return nil, "macro definition missing" end
        -- A body that isn't text is damage, never an instruction to blank a
        -- macro (an empty string is a real, empty body).
        if type(def.body) ~= "string" then return nil, "macro definition damaged" end
        local body = Game.Normalize(def.body)
        if #matches == 0 then
            if #body > MACRO_MAX then return nil, "macro too long" end
            return { kind = "macro", name = want.name, body = body, scope = "char", icon = def.icon }, nil, true
        end
        local m = matches[1]
        if #matches == 1 and m.scope == "char" then
            if type(m.body) ~= "string" then return nil, "macros unreadable" end
            -- No icon in the definition keeps this macro's own.
            local icon = def.icon
            if icon == nil then icon = m.icon end
            if Game.Normalize(m.body) == body and icon == m.icon then
                return { kind = "macro", name = m.name, body = m.body, scope = "char" }
            end
            -- One character macro of that name, with other text or icon:
            -- updated to the loadout's (#6), previewed and backed up.
            if #body > MACRO_MAX then return nil, "macro too long" end
            return { kind = "macro", name = m.name, body = body, scope = "char" }, nil, nil,
                { from = { body = m.body, icon = m.icon }, to = { body = body, icon = icon } }
        end
        -- An account macro of that name, or several: never written.
        return nil, "macro name conflict"
    end
    return nil, "not supported yet"
end

-- plan = { kind = "load"|"restore", blocked, actions = {{slot, target, current, why}},
--          creates = {{name, body, icon}}, edits = {{name, from = {body, icon}, to = {body, icon}}} (#6),
--          noCharMacros, keys = {[key] = {to = cmd|false, from}},
--          keysBlocked, skips = {{slot, reason}}, waiting = {{slot, reason}} (load),
--          unavailable (restore), noop, fingerprint }
-- An action with no target empties its slot; `why` is the loadout's reason
-- when it held something this character can't use (#46). `skips` are left
-- untouched; `waiting` are already empty and stay so until the character
-- can use what the loadout has there.
local function Finish(plan)
    plan.edits = plan.edits or {}
    plan.noop = #plan.actions == 0 and #plan.creates == 0 and #plan.edits == 0 and next(plan.keys) == nil
        and not plan.resave and not (plan.pet and #plan.pet.ops > 0)
    -- The pet part holds the pet GUID, its bar now, the ops, the final bar
    -- and the skips: another pet, or a changed bar, refuses the confirm.
    plan.fingerprint = Serialize({ v = plan.version, w = plan.which, a = plan.actions, c = plan.creates,
                                   e = plan.edits,
                                   k = plan.keys, kb = plan.keysBlocked or false, s = plan.skips,
                                   wt = plan.waiting or {}, r = plan.resave or false,
                                   u = plan.unavailable or {}, b = plan.blocked or false, p = plan.pet or false })
    return plan
end

-- What this character verifiably can't use: Load empties the slot (#46).
-- Every other reason (a failed read, a damaged or unsupported entry, an
-- unknown reason) leaves the slot as it is.
local EMPTIES = { ["not learned"] = true, ["rank not known"] = true, ["not in bags"] = true,
                  ["account macro missing"] = true, ["macro name conflict"] = true,
                  ["macro slots full"] = true }
Loadout.EMPTIES = EMPTIES

local KEYS_BLOCKED = "Enable character-specific keybindings in WoW settings, then try again."

-- The binding part of a plan: one final key -> command|unbound map. A
-- command the entry has no key for is left alone (an empty entry never
-- erases), and a load that has keys to set is blocked, not partly applied,
-- while Account bindings are active. The preview then offers the switch
-- (#7, Loadout.UseCharacterBindings), and the load is planned afresh after it.
local function PlanKeys(plan, wantKeys)
    local Game = G()
    local has = {}
    -- Only the commands Capture records (#71): a loadout from a pasted string
    -- or another account never binds anything else.
    local managed = {}
    for _, cmd in ipairs(Game.COMMANDS) do managed[cmd] = true end
    for cmd, keys in pairs(wantKeys) do
        if not managed[cmd] or type(keys) ~= "table" then keys = {} end
        for i = 1, table.maxn(keys) do
            if type(keys[i]) == "string" and keys[i] ~= "" then has[cmd] = keys end
        end
    end
    if next(has) == nil then return end
    if not Game.CharacterBindings() then
        plan.blocked = KEYS_BLOCKED
        -- Offered only on a successful read of Account: a failed read is not
        -- a set to switch from.
        local BS = Enum and Enum.BindingSet
        if BS and Game.BindingSet() == BS.Account then plan.needsCharacterBindings = true end
        return
    end
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

-- `opts.noCharMacros`: "Include character macros" unticked (#6).
function Loadout.Plan(entry, opts)
    local Game = G()
    local plan = { kind = "load", entryId = entry.id, version = entry.version, name = entry.name,
                   actions = {}, creates = {}, edits = {}, keys = {}, skips = {}, waiting = {},
                   noCharMacros = (opts and opts.noCharMacros) and true or nil }
    if entry.kind ~= "loadout" then plan.blocked = "Not a loadout." return Finish(plan) end
    if entry.class ~= PlayerClass() then
        plan.blocked = "This loadout is for another class." return Finish(plan)
    end
    -- Without its cover a later Save can't use what this load records, so
    -- "load it again" would never help (#5).
    if not ASS.Cover.Ok(entry.modules) then
        plan.blocked = "This loadout is damaged (no list of covered slots); it can't be loaded."
        return Finish(plan)
    end
    plan.blocked = Loadout.Blocked()
    if plan.blocked then return Finish(plan) end
    local modules = entry.modules or {}
    local book = Game.Spellbook()
    local creating, charCount = {}, Game.CharMacroCount()
    -- The bars as they will be after the planned updates (#6): a slot that
    -- holds a character macro being updated already shows its new text.
    local editing = {}
    local function View(a)
        local e = a and a.kind == "macro" and a.scope == "char" and editing[a.name]
        if not e then return a end
        local v = ASS.Catalog.Copy(a)
        v.body, v.icon = e.to.body, e.to.icon
        return v
    end
    -- Slots this build doesn't read or write are listed, never applied.
    local outside = {}
    for slot in pairs(modules.actions or {}) do
        if type(slot) == "number" and not Game.IS_SLOT[slot] then outside[#outside + 1] = slot end
    end
    table.sort(outside)
    for _, slot in ipairs(outside) do
        plan.skips[#plan.skips + 1] = { slot = slot, reason = "not supported on this build" }
    end
    -- Every covered slot ends up as the loadout has it (#46): placed where
    -- this character can, empty where the loadout is empty or holds what this
    -- character verifiably can't use. Uncovered slots were never captured:
    -- untouched. So is anything the backup couldn't put back.
    for _, slot in ipairs(Game.SLOT_LIST) do
        if ASS.Cover.Has(modules.cover, slot) then
            local want = modules.actions and modules.actions[slot]
            local current = Game.ActionAt(slot)
            local target, why, create, edit
            if want then target, why, create, edit = Resolve(want, modules, book, plan) end
            -- One update per macro name, planned by the first slot that will
            -- hold it (the slot's content can be put back).
            if target and edit and not editing[target.name] and Game.Restorable(current, book) then
                editing[target.name] = edit
                plan.edits[#plan.edits + 1] = { name = target.name, from = edit.from, to = edit.to }
            end
            local same = Game.SameAction(View(current), target)
            if target and not same and create and not creating[target.name] and Game.Restorable(current, book) then
                if charCount == nil then
                    target, why = nil, "macros unreadable"
                elseif charCount + #plan.creates >= Game.MAX_CHAR_MACROS then
                    target, why = nil, "macro slots full"
                else
                    creating[target.name] = true
                    plan.creates[#plan.creates + 1] = { name = target.name, body = target.body, icon = target.icon }
                end
                same = Game.SameAction(current, target)
            end
            if want and not target and not EMPTIES[why] then
                plan.skips[#plan.skips + 1] = { slot = slot, reason = why }
            elseif same then
                if want and not target then plan.waiting[#plan.waiting + 1] = { slot = slot, reason = why, want = want } end
            elseif not Game.Restorable(current, book) then
                -- Only the loadout's own slots are listed (and so recorded as
                -- unavailable): a loadout-empty slot holding a mount is
                -- simply not this load's business.
                if want then
                    plan.skips[#plan.skips + 1] = { slot = slot, reason = "slot holds something this slice can't put back" }
                end
            else
                local unusable = want ~= nil and target == nil
                plan.actions[#plan.actions + 1] = { slot = slot, target = target, current = current,
                                                    why = unusable and why or nil, want = unusable and want or nil }
            end
        end
    end
    if modules.bindings then PlanKeys(plan, modules.bindings) end
    -- The pet bar of the pet that is out, from its family's layout (#47).
    plan.pet = ASS.Pet.PlanLoad(modules.pet)
    if Unsaved() and Game.CharacterBindings() then plan.resave = true end
    if plan.blocked then
        plan.actions, plan.creates, plan.edits, plan.keys, plan.resave, plan.pet = {}, {}, {}, {}, nil, nil
    end
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
    local book = Game.Spellbook()
    for _, op in ipairs(plan.actions) do
        local a = Game.ActionAt(op.slot)
        -- A slot read that fails (or reads back something this slice can't
        -- put back) means no backup, so no writes.
        if not Game.Restorable(a, book) then return nil end
        snap.actions[op.slot] = a or false
    end
    for key in pairs(plan.keys) do
        local cmd = Game.CommandOf(key)
        if cmd == nil then return nil end           -- unreadable: no backup, so no writes
        snap.keys[key] = cmd
    end
    if plan.pet and #plan.pet.ops > 0 then
        snap.pet = ASS.Pet.Snapshot(plan.pet)
        if not snap.pet then return nil end
    end
    -- The character macros the plan updates, as they are and as they will
    -- be (#6). Written here, before Pin or PushRing copy the snapshot, so the
    -- first-seen copy has them too; an update recorded but never made is
    -- harmless (Restore finds the macro already as it was).
    if #(plan.edits or {}) > 0 then
        snap.editedMacros = {}
        for _, e in ipairs(plan.edits) do
            snap.editedMacros[#snap.editedMacros + 1] = { name = e.name, before = ASS.Catalog.Copy(e.from),
                                                          after = ASS.Catalog.Copy(e.to) }
        end
    end
    return snap
end

-- Run `plan`; `snap` is its pinned (load) or ring (restore) snapshot.
-- Returns result = { changed, created, keys, failed = reason|nil, at }.
local function Execute(plan, snap)
    local Game = G()
    local result = { changed = 0, created = 0, keys = 0, pet = 0 }
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

    -- 1b. Character macro updates (#6): each still exactly as the preview
    -- saw it, looked up by name NOW (creation shifts indices), then read back.
    local edited = {}
    result.edited = 0
    local function single(name)
        local m = Game.MacrosNamed(name)
        if not m or #m ~= 1 or m[1].scope ~= "char" or type(m[1].body) ~= "string" then return nil end
        return m[1]
    end
    for _, e in ipairs(plan.edits or {}) do
        local at = "macro " .. e.name
        local m = single(e.name)
        if not m or Game.Normalize(m.body) ~= Game.Normalize(e.from.body) or m.icon ~= e.from.icon then
            return fail("macro changed since the preview", at)
        end
        local ok, why = call(false, EditMacro, m.index, e.name, e.to.icon, e.to.body)
        if not ok then return fail(why, at) end
        m = single(e.name)
        if not m or Game.Normalize(m.body) ~= Game.Normalize(e.to.body) or m.icon ~= e.to.icon then
            return fail("macro not updated", at)
        end
        edited[e.name] = e.to
        result.edited = result.edited + 1
    end
    -- What a slot's snapshot content is now: a character macro updated above
    -- shows its new text (the snapshot itself keeps the old, for restore).
    local function expected(a)
        local to = a and a.kind == "macro" and a.scope == "char" and edited[a.name]
        if not to then return a end
        local v = ASS.Catalog.Copy(a)
        v.body, v.icon = to.body, to.icon
        return v
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
            if not Game.SameAction(held, expected(snap.actions[op.slot] or nil)) then
                return bail("unexpected item on cursor", at)
            end
            pcall(ClearCursor)
            if not Game.CursorEmpty() then return bail("cursor stuck", at) end
        end
        if not Game.SameAction(Game.ActionAt(op.slot), t) then return bail("verify failed", at) end
        result.changed = result.changed + 1
    end
    if #plan.actions > 0 and not Game.CursorEmpty() then return bail("cursor not empty after the actions", "actions") end

    -- 2b. The pet bar (#47). Its own executor: a pet payload is never
    -- cleared on failure (bail() would); it goes back, or stays and is named.
    if plan.pet and #plan.pet.ops > 0 then
        local n, why, at = ASS.Pet.Execute(plan.pet)
        if not n then return fail(why, at) end
        result.pet = n
    end

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
        -- Read back again after saving: something may have changed a key on
        -- the way. The pending flag stays set and the backup stays pinned.
        for key, v in pairs(plan.keys) do
            if Game.CommandOf(key) ~= v.to then return fail("bindings changed while saving", "bindings") end
        end
        SetUnsaved(nil)
        for _ in pairs(plan.keys) do result.keys = result.keys + 1 end
    end
    return result
end

------------------------------------------------------------
-- Character keybindings (#7): the one set switch, Account -> Character, on
-- the player's OK. Blizzard's own sequence (the Settings checkbox):
-- SaveBindings(Account); LoadBindings(Character); SaveBindings(Character).
-- Measured on 70291: the active set still reads Account until the last
-- call, and the keys stay identical throughout. The first call saves the
-- keys in memory as the account ones (disclosed in the preview), so it runs
-- only while Account is active: on a Character set it would overwrite the
-- account keys with this character's.
--
-- AltStableSyncChar.bindingSwitch = { before, at, when } is written before
-- the first call and removed only after a verified success. While it is
-- there, a new attempt runs only if the keys are exactly `before` again:
-- after a failure the keys in memory may differ, and saving those as the
-- account set would lose the account keys. Never Character -> Account,
-- never a set deletion: going back is the player's action in Settings.
------------------------------------------------------------

local SWITCH_STEPS = { "saving your account keybindings", "loading character keybindings",
                       "saving character keybindings" }

local function SetName(set)
    local BS = Enum and Enum.BindingSet or {}
    if set ~= nil and set == BS.Account then return "your account keybindings are active"
    elseif set ~= nil and set == BS.Character then return "character keybindings are active" end
    return "the active keybinding set couldn't be read"
end

-- Up to three commands whose keys differ between two maps, as text.
local function Differ(a, b)
    local names, seen = {}, {}
    for _, m in ipairs({ a, b }) do
        for cmd in pairs(m) do
            if not seen[cmd] and Serialize(a[cmd]) ~= Serialize(b[cmd]) then names[#names + 1] = cmd end
            seen[cmd] = true
        end
    end
    -- Commands first, then keys read by key ("@" .. key).
    table.sort(names, function(x, y)
        local kx, ky = x:sub(1, 1) == "@", y:sub(1, 1) == "@"
        if kx ~= ky then return ky end
        return x < y
    end)
    for i, name in ipairs(names) do
        if name:sub(1, 1) == "@" then names[i] = "key " .. name:sub(2) end
    end
    local n = #names
    while #names > 3 do names[#names] = nil end
    return table.concat(names, ", ") .. (n > 3 and (" and " .. (n - 3) .. " more") or "")
end

Loadout.SWITCH_GUARDED = "An earlier switch to character keybindings stopped, and your keys differ from before it. "
    .. "Check your keybindings: switching now could save these keys as your account keybindings."

-- The guard's state for a preview: nil (none, or the keys are as before),
-- false when unreadable, or the commands and keys that differ now (text)
-- plus the keys read (the map an OK may accept).
function Loadout.SwitchGuard()
    local guard = ASS.char and ASS.char.bindingSwitch
    if not guard then return nil end
    local live = G().BindingMap()
    if not live then return false end
    if Serialize(live) == Serialize(guard.before) then return nil end
    return Differ(guard.before, live), live
end

-- true, or nil plus the text to show. `accept`: the keys a confirmed
-- preview showed as differing from before a stopped switch, which the player
-- chose to make the account keys (Loadout.SwitchGuard). Accepted only while
-- the keys are exactly those.
function Loadout.UseCharacterBindings(accept)
    local Game = G()
    local BS = Enum and Enum.BindingSet
    if not BS then return nil, "Couldn't read the keybinding sets. Nothing changed." end
    local Account, Character = BS.Account, BS.Character
    local blocked = Loadout.Blocked()
    if blocked then return nil, blocked end
    if Game.BindingSet() ~= Account then
        return nil, "This character isn't on your account keybindings now. Nothing changed."
    end
    local live = Game.BindingMap()
    if not live then return nil, "Couldn't read the key bindings. Nothing changed." end
    local char = ASS.char
    local guard = char.bindingSwitch
    if guard and Serialize(live) ~= Serialize(guard.before) then
        if not accept or Serialize(live) ~= Serialize(accept) then return nil, Loadout.SWITCH_GUARDED end
        guard.before = ASS.Catalog.Copy(live)       -- the player's explicit choice, previewed
    end
    if not guard then
        guard = { before = ASS.Catalog.Copy(live), when = time and time() or nil }
        char.bindingSwitch = guard
    end
    local before = guard.before
    local accountSaved = false

    local function stop(i, problem, now)
        -- `now`: the map just read, false when that read failed, nil to read it here.
        if now == nil then now = Game.BindingMap() end
        local reloaded
        -- The account keys were just saved as `before`; if the keys in memory
        -- are no longer those while Account is still active, anything that
        -- saves the current set (Blizzard's Keybindings window, another
        -- addon) would save them over the account keys. Reload the saved
        -- account keys: the same set, not a switch.
        local inCombat
        if accountSaved and (not now or Serialize(now) ~= Serialize(before)) and Game.BindingSet() == Account then
            -- Out of combat only, like every write.
            if InCombatLockdown() then
                inCombat = true
            else
                local ok, ret = pcall(LoadBindings, Account)
                now = Game.BindingMap()
                reloaded = ok and ret ~= false and now and Serialize(now) == Serialize(before)
            end
        end
        local text = ("Stopped while %s: %s. WoW reports that %s. The loadout wasn't loaded."):format(
            SWITCH_STEPS[i], problem, SetName(Game.BindingSet()))
        if inCombat then
            text = text .. " Combat started, so your saved account keybindings weren't reloaded."
        end
        if reloaded then
            text = text .. " Your saved account keybindings were reloaded, so your keys are as before."
        elseif not now then
            text = text .. " Your keys couldn't be read, so it isn't known whether they are as before."
        elseif Serialize(now) ~= Serialize(before) then
            text = text .. " Your keys differ from before: " .. Differ(before, now) .. ". "
                .. "Check them before trying again; switching again asks first while they differ."
        end
        return nil, text
    end

    local calls = { { SaveBindings, Account }, { LoadBindings, Character }, { SaveBindings, Character } }
    for i, c in ipairs(calls) do
        if InCombatLockdown() then return stop(i, "combat started") end
        if Game.BindingSet() ~= Account then return stop(i, "the keybinding set changed") end
        guard.at = SWITCH_STEPS[i]
        local ok, ret = pcall(c[1], c[2])
        if not ok then return stop(i, "the client refused (" .. tostring(ret) .. ")") end
        if ret == false then return stop(i, "the client refused") end
        -- Checked before the next call, so changed keys are never saved.
        local now = Game.BindingMap()
        if not now then return stop(i, "couldn't read the keys to check them", false) end
        if Serialize(now) ~= Serialize(before) then return stop(i, "the keys changed", now) end
        if i == 1 then accountSaved = true end
    end
    if Game.BindingSet() ~= Character then return stop(3, "character keybindings didn't turn on") end
    char.bindingSwitch = nil
    SetUnsaved(nil)          -- the keys in memory are saved, as the character set
    return true
end

------------------------------------------------------------
-- Load
------------------------------------------------------------

local function Copy(v) return ASS.Catalog.Copy(v) end

-- This character's one loaded-loadout record (docs/DESIGN.md data model),
-- written by Load, Save and Save As. `unavailable` only goes with `after`.
local function Record(e, modules, after, unavailable, result)
    ASS.char.loaded = ASS.char.loaded or {}
    ASS.char.loaded.loadout = { id = e.id, version = e.version, baseline = Copy(modules),
                                after = after, unavailable = after and (unavailable or {}) or nil, result = result }
end

-- Apply the plan the player confirmed. `shown` is that plan; `abandon` is
-- the player's answer to "Abandon the incomplete load of X?".
function Loadout.Load(entry, shown, abandon)
    -- The catalog's CURRENT entry: a sync or another command may have replaced
    -- or deleted it since the preview (its version is in the fingerprint).
    local live = ASS.Catalog.Get(entry.id)
    if not live or live.deleted then return nil, "That loadout was deleted since the preview." end
    entry = live
    local plan = Loadout.Plan(entry, { noCharMacros = shown and shown.noCharMacros })
    if plan.blocked then return nil, plan.blocked end
    if plan.fingerprint ~= shown.fingerprint then return nil, "Something changed since the preview: review it again." end
    local pinned = ASS.Backups.Operation()
    if pinned and not abandon then return nil, "incomplete" end
    local function abandonPinned()
        if pinned then ASS.Backups.Release(); ASS.char.interrupted = nil end
    end
    -- One record per kind (docs/DESIGN.md "Preserve intent on Save"). Only a
    -- COMPLETED load also records `after` (what the slots and keys hold now,
    -- for Save to compare against) and `unavailable` (the entries this
    -- character couldn't use). A failed load replaces the whole record, so an
    -- older `after` never outlives a newer failed load.
    local function record(result, complete)
        local after = complete and Loadout.Capture() or nil
        local unavailable
        if after then
            -- Keys are compared only against Character keys: under Account
            -- bindings this character's own keys aren't what we read.
            if not G().CharacterBindings() then after.bindings = nil end
            -- The pet bar's comparison, for the family out only, with the
            -- slots this load couldn't fill (#47). None when the pet part
            -- couldn't be planned: Save then asks for another load.
            local pp = plan.pet
            if type(after.pet) ~= "table" or (pp and pp.failed) then
                after.pet = nil
            elseif pp and pp.layout then
                local fam, layout = next(after.pet)
                if fam == pp.family then
                    local u = {}
                    for slot, why in pairs(pp.absent or {}) do u[slot] = why end
                    for _, s in ipairs(pp.skips) do u[s.slot] = s.reason end
                    layout.unavailable = next(u) and u or nil
                end
            end
            -- Every slot where the load couldn't place the loadout's action:
            -- left as it was, already empty, or emptied (#46).
            unavailable = {}
            for _, s in ipairs(plan.skips) do unavailable[s.slot] = s.reason end
            for _, s in ipairs(plan.waiting) do unavailable[s.slot] = s.reason end
            for _, op in ipairs(plan.actions) do
                if op.why then unavailable[op.slot] = op.why end
            end
        end
        Record(entry, entry.modules, after, unavailable, result)
    end
    if plan.noop then
        abandonPinned()
        record({ noop = true, skips = plan.skips }, true)
        return { noop = true, skips = plan.skips, changed = 0, created = 0, keys = 0 }
    end
    local snap = Snapshot(plan, "load " .. tostring(entry.name))
    if not snap then return nil, "Couldn't read the current setup for the backup; nothing was changed." end
    abandonPinned()               -- only now: nothing above can fail after this
    local ok, err = ASS.Backups.Pin(snap, { kind = "load", id = entry.id, version = entry.version, name = entry.name })
    if not ok then return nil, err end
    local result = Execute(plan, snap)
    result.skips = plan.skips
    record(result, not result.failed)
    if result.failed then
        ASS.char.interrupted = { id = entry.id, version = entry.version, why = result.failed, at = result.at }
        return result
    end
    ASS.char.interrupted = nil
    ASS.Backups.Release()
    return result
end

------------------------------------------------------------
-- Save and Save As: preserve intent (#28, docs/DESIGN.md "Preserve intent")
------------------------------------------------------------

-- Two key lists hold the same keys (order and nil vs {} don't matter).
local function SameKeys(a, b)
    local x, y = {}, {}
    for _, k in ipairs(a or {}) do x[#x + 1] = k end
    for _, k in ipairs(b or {}) do y[#y + 1] = k end
    table.sort(x); table.sort(y)
    return table.concat(x, "\0") == table.concat(y, "\0")
end

local function CharMacro(mods, name) return mods and mods.macros and mods.macros[name] end

-- A character macro's icon as this slot last saw it: a comparison slot
-- carries its own (frozen slots and advancing ones can share a name).
local function MacroIcon(act, mods)
    if act.icon ~= nil then return act.icon end
    local d = CharMacro(mods, act.name)
    return d and d.icon
end

-- Save's own "unchanged since the load?": action identity, plus a character
-- macro's body and icon (an icon-only edit is a change). Game.SameAction is
-- left as it is: it verifies writes.
local function SaveSame(c, a, cMods, aMods, b)
    if c == nil or a == nil then return c == a end
    if c.kind ~= a.kind then return false end
    if c.kind == "macro" then
        local Game = G()
        if c.name ~= a.name or c.scope ~= a.scope or Game.Normalize(c.body or "") ~= Game.Normalize(a.body or "") then
            return false
        end
        if c.scope == "char" and MacroIcon(c, cMods) ~= MacroIcon(a, aMods) then return false end
        return true
    end
    -- Spells (#42). The same rank is unchanged even when its policy flipped:
    -- a policy depends on the other slots, so an untouched slot keeps the
    -- loaded one. A rank update (a hunter bar after training, or the new rank
    -- dragged in) is no change while both say "highest" for the same spell,
    -- and the loaded entry does too (an entry's exact rank, edited, is an edit).
    if c.kind == "spell" and c.policy == "highest" and a.policy == "highest" and c.name ~= nil and c.name == a.name
        and b and b.kind == "spell" and b.policy == "highest" then
        return true
    end
    return c.id == a.id
end

local function Unsupported(a) return a ~= nil and a.kind == "unsupported" end

-- Does slot content `x` differ from B's `b`? A character macro counts its
-- body and icon too: `def(name)` gives x's definition (nil: action only).
-- An action without its `class` mark (#46: metadata, not intent).
local function Intent(x)
    if type(x) ~= "table" or x.class == nil then return x end
    local y = {}
    for k, v in pairs(x) do if k ~= "class" then y[k] = v end end
    return y
end

-- One spell family: both spells, and the same id or the same non-empty name.
local function SameFamily(x, y)
    if not (x and y and x.kind == "spell" and y.kind == "spell") then return false end
    if type(x.id) == "number" and x.id == y.id then return true end
    return type(x.name) == "string" and x.name ~= "" and x.name == y.name
end

local function SlotDiffers(x, b, def, B)
    if Serialize(Intent(x)) ~= Serialize(Intent(b)) then return true end
    if def and x and x.kind == "macro" and x.scope == "char" then
        return Serialize(def(x.name)) ~= Serialize(CharMacro(B, x.name))
    end
    return false
end

-- The merge (pure). `rec` is the loaded record (baseline B, after A,
-- unavailable), `current` a fresh Capture() (C). Per slot:
--   C unreadable or ambiguous            -> B, and A stays the comparison
--   outside A's cover (no comparison)    -> B inside B's cover, else C (#5)
--   outside B's cover (never covered)    -> C (#5)
--   A unreadable, slot skipped at load   -> B, and A stays the comparison
--   C same as A (unchanged since then)   -> B: the inherited intent
--   C empty, slot unavailable at load    -> B (an emptied skipped destination)
--   anything else                        -> C (a deliberate change)
-- `drop`: unavailable slots hold nothing in the entry instead; they stay in
-- its cover as "empty", so a later Load empties them on every character
-- (#46), and this character's own content there isn't taken on a later Save. Modules, slots and commands this build doesn't
-- capture are kept from B as they are (A35). Returns nil plus a reason on a
-- macro or key clash.
function Loadout.Merge(rec, current, characterBindings, drop)
    local Game = G()
    local B, A = rec.baseline or {}, rec.after or {}
    local bAct, aAct, cAct = B.actions or {}, A.actions or {}, current.actions or {}
    local was = rec.unavailable or {}
    local Cover = ASS.Cover
    -- Coverage is never guessed: without it, "never captured" and "captured
    -- empty" can't be told apart (#5).
    if not (Cover.Ok(B) and Cover.Ok(A)) then
        return nil, "This character's record of the loaded setup is damaged (no list of covered slots). Load it again."
    end
    local bCov, aCov = B.cover, A.cover
    local bSet, aSet = Cover.AddTo({}, bCov), Cover.AddTo({}, aCov)
    local stale = 0         -- slots that differ from B but have no comparison
    local out = Copy(B)
    local actions, src, adv, advSrc = {}, {}, {}, {}
    local kept, dropped, unavailable, changed, gone = {}, {}, {}, {}, {}
    -- `ignored`: what sits now in a gap the load kept for the loadout's
    -- action (#46: often a spell the client placed there when it was
    -- learned); `marked`: class marks this Save adds to kept spells.
    local ignored, marked = {}, 0
    -- Coverage moves with the values (#5): the output covers B's cover plus
    -- each slot taken from a readable C; the comparison covers each slot it
    -- advanced to C, and keeps its old membership where it stays.
    local outSet, advSet = Cover.AddTo({}, bCov), {}
    for slot in pairs(aSet) do
        if not Game.IS_SLOT[slot] then advSet[slot] = true end
    end
    for slot, b in pairs(bAct) do
        if not Game.IS_SLOT[slot] then actions[slot], src[slot] = Copy(b), "B" end
    end
    for _, slot in ipairs(Game.SLOT_LIST) do
        local b, a, c = bAct[slot], aAct[slot], cAct[slot]
        local inA, inB = aSet[slot] == true, bSet[slot] == true
        local keepB, keepA, why, protected = false, false, nil, false
        if Unsupported(c) then keepB, keepA, why = true, true, "couldn't read this slot"
        -- No comparison was ever taken here (a capture by a 1-12 build): keep
        -- what the entry has; where the entry never covered it either, the
        -- slot is new to the entry and C is taken.
        elseif not inA then
            if inB then
                keepB, keepA = true, true
                if SlotDiffers(c, b, function(n) return CharMacro(current, n) end, B) then stale = stale + 1 end
            end
        elseif not inB then         -- the entry never covered it: C
        -- An unreadable A only hides an edit where the load skipped the slot;
        -- where the load placed B, a readable C is what is there now.
        elseif Unsupported(a) and was[slot] then keepB, keepA = true, true
        -- A gap the load kept for an action this character couldn't use
        -- (emptied, or already empty): whatever is there now isn't saved over
        -- the loadout's action - the client puts a newly learned spell in the
        -- first empty slot (#46). It holds until a Load fills the slot.
        elseif was[slot] and b ~= nil and a == nil then
            keepB, keepA, protected = true, true, true
            if c ~= nil then ignored[slot] = Copy(c) end
        elseif SaveSame(c, a, current, A, b) then keepB = true
        elseif c == nil and was[slot] then keepB = true
        end
        if keepB and drop and was[slot] and b ~= nil then
            dropped[#dropped + 1], gone[slot] = { slot = slot, want = b, reason = was[slot] }, true
            -- A dropped gap compares with what is there now, so the next
            -- Save doesn't take that as a new edit.
            if protected then keepA, ignored[slot] = false, nil end
        elseif keepB then
            actions[slot], src[slot] = Copy(b), "B"
            -- The class mark only grows: a fresh capture of the same spell
            -- from a class tab adds it; a capture without it (a failed read,
            -- an older build) never takes it away.
            if SameFamily(b, c) and c.class == true and b.class ~= true then
                actions[slot].class, marked = true, marked + 1
            end
            if b ~= nil and was[slot] then
                unavailable[slot] = was[slot]
                kept[#kept + 1] = { slot = slot, want = b, reason = was[slot] }
            elseif b ~= nil and why then
                kept[#kept + 1] = { slot = slot, want = b, reason = why }
            end
        else
            actions[slot], src[slot] = Copy(c), "C"
            outSet[slot] = true
            -- Another rank of the same spell keeps the entry's mark too: the
            -- capture may lack it only because its book read failed.
            if SameFamily(b, c) and b.class == true then actions[slot].class = true end
        end
        if keepA then
            adv[slot], advSrc[slot] = Copy(a), "A"
            if inA then advSet[slot] = true end
        else
            adv[slot], advSrc[slot] = Copy(c), "C"
            advSet[slot] = true
        end
    end

    -- Character macros follow the slots that use them; one name, one body.
    local slots = {}
    for slot in pairs(actions) do if type(slot) == "number" then slots[#slots + 1] = slot end end
    for _, slot in ipairs(Game.SLOT_LIST) do if actions[slot] == nil then slots[#slots + 1] = slot end end
    table.sort(slots)
    local macros, advMacros = {}, {}
    for _, slot in ipairs(slots) do
        local act = actions[slot]
        if act and act.kind == "macro" and act.scope == "char" then
            local def = CharMacro(src[slot] == "B" and B or current, act.name)
            if def then
                local have = macros[act.name]
                if have and (Game.Normalize(have.body or "") ~= Game.Normalize(def.body or "") or have.icon ~= def.icon) then
                    return nil, ("Macro %q differs between the loaded setup and this character; rename the macro here, then save.")
                        :format(act.name)
                end
                macros[act.name] = Copy(def)
            end
        end
        local x = adv[slot]
        if x and x.kind == "macro" and x.scope == "char" then
            local mods = advSrc[slot] == "A" and A or current
            x.icon = MacroIcon(x, mods)
            advMacros[x.name] = Copy(CharMacro(mods, x.name))
        end
    end

    -- What the preview lists as changed: the slot's action, or the body or
    -- icon of the character macro it uses. Dropped slots are listed apart.
    for _, slot in ipairs(Game.SLOT_LIST) do
        local x = actions[slot]
        local diff = SlotDiffers(x, bAct[slot], src[slot] == "C" and function(n) return macros[n] end, B)
        if diff and not gone[slot] then changed[#changed + 1] = slot end
    end

    -- Keys: compared only against Character keys taken at a load (or a fresh
    -- Save As) under Character bindings; a Save never sets the comparison.
    local bB, aB, cB = B.bindings, A.bindings, current.bindings or {}
    local notes, bindings, advB, keysChanged, keysAdded = {}, nil, nil, {}, {}
    local function differs()
        for _, cmd in ipairs(Game.COMMANDS) do
            if not SameKeys(cB[cmd], bB and bB[cmd]) then return true end
        end
        return false
    end
    if not characterBindings then
        bindings, advB = Copy(bB), Copy(aB)
        if differs() then notes[#notes + 1] = "Keys not saved: Account bindings are active." end
    elseif not aB then
        bindings = Copy(bB)
        if differs() then
            notes[#notes + 1] = "Key changes can't be saved yet: load this loadout with Character bindings active first."
        end
    else
        bindings, advB = {}, Copy(cB)
        local known, cmds = {}, {}
        for _, cmd in ipairs(Game.COMMANDS) do known[cmd] = true end
        for cmd, keys in pairs(bB or {}) do
            if not known[cmd] then bindings[cmd] = Copy(keys) end
        end
        local uncompared = 0
        for _, cmd in ipairs(Game.COMMANDS) do
            local b = bB and bB[cmd]
            if bB and b == nil then
                -- The entry has keys but predates the command (the pet bar,
                -- #47): this character's keys are added. An entry with no
                -- keys at all takes the comparison below.
                if not SameKeys(cB[cmd], nil) then
                    bindings[cmd] = Copy(cB[cmd])
                    keysAdded[#keysAdded + 1] = cmd
                end
            elseif aB[cmd] == nil then
                -- Loaded by a build that didn't compare it: B stays, and so
                -- does the missing comparison, until a Load takes one.
                bindings[cmd], advB[cmd] = Copy(b), nil
                if not SameKeys(cB[cmd], b) then uncompared = uncompared + 1 end
            elseif SameKeys(cB[cmd], aB[cmd]) then
                bindings[cmd] = Copy(b)
            else
                bindings[cmd] = Copy(cB[cmd])
                if not SameKeys(cB[cmd], b) then keysChanged[#keysChanged + 1] = cmd end
            end
        end
        if uncompared > 0 then
            notes[#notes + 1] = (uncompared == 1
                and "1 key differs from the loadout but wasn't loaded by this version, so it isn't saved: load the loadout again to save it."
                or ("%d keys differ from the loadout but weren't loaded by this version, so they aren't saved: load the loadout again to save them."):format(uncompared))
        end
        for cmd in pairs(bindings) do cmds[#cmds + 1] = cmd end
        table.sort(cmds)
        local owner = {}
        for _, cmd in ipairs(cmds) do
            for _, k in ipairs(bindings[cmd] or {}) do
                if owner[k] and owner[k] ~= cmd then
                    return nil, ("Key %s would be bound twice in the saved loadout; check your key bindings, then save."):format(k)
                end
                owner[k] = cmd
            end
        end
    end

    -- A module B doesn't have stays absent when nothing fills it, so an
    -- unchanged entry is a noop whatever its shape.
    local function orNil(t, had)
        if had == nil and t ~= nil and next(t) == nil then return nil end
        return t
    end
    out.actions, out.macros, out.bindings = orNil(actions, B.actions), orNil(macros, B.macros), orNil(bindings, B.bindings)
    -- The pet bar of the family out (#47, Pet.Merge); other families as B has them.
    local petOut, petAdv, petInfo = ASS.Pet.Merge(B.pet, A.pet, current.pet, drop)
    out.pet = petOut
    for _, n in ipairs(petInfo.notes) do notes[#notes + 1] = n end
    out.cover = Cover.FromSet(outSet)
    -- Slots this Save adds to the entry's cover, and how many hold an action.
    if marked > 0 then
        notes[#notes + 1] = ("Marks %d class spell%s: a Load empties their slots on characters that haven't learned them yet.")
            :format(marked, marked == 1 and "" or "s")
    end
    if stale > 0 then
        notes[#notes + 1] = (stale == 1
            and "1 slot differs from the loadout but wasn't loaded by this version, so it isn't saved: load it again to save it."
            or ("%d slots differ from the loadout but weren't loaded by this version, so they aren't saved: load it again to save them."):format(stale))
    end
    local added, addedFull = 0, 0
    for slot in pairs(outSet) do
        if not bSet[slot] then
            added = added + 1
            if actions[slot] ~= nil then addedFull = addedFull + 1 end
        end
    end
    return {
        added = added, addedFull = addedFull,
        before = bAct,                  -- B's actions, for the preview's "was -> now"
        ignored = ignored, marked = marked,
        modules = out,
        noop = Serialize(out) == Serialize(B),
        pet = petInfo,
        kept = kept, dropped = dropped, notes = notes,
        changed = changed, keysChanged = keysChanged, keysAdded = keysAdded,
        unavailable = unavailable,
        advanced = { actions = adv, macros = advMacros, bindings = advB, cover = Cover.FromSet(advSet), pet = petAdv },
    }
end

local function Provenance()
    local name, realm = UnitFullName("player")
    return { sourceChar = tostring(name) .. "-" .. tostring(realm), build = select(2, GetBuildInfo()) }
end
Loadout.Provenance = Provenance

-- Save over the loaded entry: the merge, previewed. Only the entry this
-- character has loaded, only at the version it loaded (A39).
function Loadout.PlanSave(drop)
    local rec = ASS.char and ASS.char.loaded and ASS.char.loaded.loadout
    if not rec then return nil, "Load a loadout first. To save this character as it is, use /altsync saveas <name>." end
    local entry = ASS.Catalog.Get(rec.id)
    if not entry or entry.deleted or entry.conflict then
        return nil, "The loaded loadout no longer exists. Use /altsync saveas <name>."
    end
    if entry.version ~= rec.version then
        return nil, ("%q changed since you loaded it. Load it again, or use /altsync saveas <name>."):format(tostring(entry.name))
    end
    if not rec.after then return nil, "No usable comparison with the loaded setup. Load it again to save over it." end
    local blocked = Loadout.Blocked()
    if blocked then return nil, blocked end
    local current, cerr = Loadout.Capture()
    if not current then return nil, cerr end
    local m, merr = Loadout.Merge(rec, current, G().CharacterBindings(), drop)
    if not m then return nil, merr end
    m.entry, m.drop = entry, drop or false
    -- Everything the confirm commits: the entry and the new comparison.
    m.fingerprint = Serialize({ id = entry.id, v = entry.version, m = m.modules, d = m.drop,
                                a = m.advanced, u = m.unavailable, ig = m.ignored })
    return m
end

-- Apply the Save the player confirmed: recomputed, and refused unless it is
-- exactly what the preview showed.
function Loadout.Save(shown)
    local m, err = Loadout.PlanSave(shown.drop)
    if not m then return nil, err end
    if m.fingerprint ~= shown.fingerprint then return nil, "Something changed since the preview: review it again." end
    if m.noop then return nil, "Already saved." end
    local r, rerr = ASS.Catalog.Replace(m.entry.id, m.modules, m.entry.version, Provenance())
    if not r then return nil, rerr end
    Record(r, m.modules, m.advanced, m.unavailable)
    return r, m
end

-- What Save As would store. With a usable loaded record: the merge, so the
-- fork keeps inherited content (A09). Without one, or when the merge refuses
-- (a macro or key clash, given as `why`): a fresh capture, and `lossy` when a
-- loaded record exists but can't be merged with.
function Loadout.PlanSaveAs()
    local blocked = Loadout.Blocked()
    if blocked then return nil, blocked end
    local current, cerr = Loadout.Capture()
    if not current then return nil, cerr end
    local rec = ASS.char and ASS.char.loaded and ASS.char.loaded.loadout
    local why
    if rec and rec.after then
        local m, merr = Loadout.Merge(rec, current, G().CharacterBindings(), false)
        if m then
            return { modules = m.modules, after = m.advanced, unavailable = m.unavailable, kept = m.kept, notes = m.notes,
                     added = m.added, addedFull = m.addedFull, ignored = m.ignored }
        end
        why = merr
    end
    if current.pet == false then current.pet = nil end
    local after = Copy(current)
    if not G().CharacterBindings() then after.bindings = nil end
    return { modules = current, after = after, unavailable = {}, kept = {}, notes = {}, lossy = rec ~= nil, why = why }
end

-- What a Save As preview froze: the content, the comparison it records, and
-- whether it keeps or loses inherited entries. A confirm whose fresh plan
-- differs is refused (#44), as Save's is.
function Loadout.SaveAsFingerprint(p)
    return Serialize({ m = p.modules, a = p.after, u = p.unavailable, l = p.lossy or false,
                       n = p.added or 0, ig = p.ignored or {} })
end

-- Create the new entry from a Save As plan, and make it this character's
-- loaded record (the player keeps refining what they just created).
function Loadout.SaveAs(p, name, category)
    local e, err = ASS.Catalog.Create("loadout", { class = PlayerClass(), category = category or "general",
        name = name, provenance = Provenance() }, p.modules)
    if not e then return nil, err end
    Record(e, p.modules, p.after, p.unavailable)
    return e
end

------------------------------------------------------------
-- Restore (exact)
------------------------------------------------------------

------------------------------------------------------------
-- Back up now (#61)
------------------------------------------------------------

-- The whole setup as it is now, in the snapshot shape a load's backup has,
-- so PlanRestore and Restore restore it unchanged: every supported slot
-- (false when empty), each key on the commands this addon manages, the bar
-- of the pet that is out. A slot holding something this build can't put
-- back exactly (a flyout, a companion, an item no longer in the bags, an
-- ambiguous macro name) is left out and listed, and Restore leaves it as it
-- is. A read that fails means no backup at all. No macro is ever created,
-- edited or deleted by restoring it (createdMacros is empty).
-- Keys only on Character keybindings: restores write the Character set only,
-- so keys read from the Account set would be copied into another set later.
-- Returns snap, left = { { slot, what } } or nil, why.

-- One slot's content, three ways, each read done once: "ok" (recorded),
-- "left" (verified not restorable: left out and listed), or nil plus why
-- (a read failed: no backup). Game.Restorable answers only yes or no, and
-- would turn a failed read into an omission.
local function Classify(a, book)
    local Game = G()
    if a == nil then return "ok" end
    if a.kind == "spell" then
        if book.byId[a.id] ~= nil then return "ok" end
        -- Absent only when the whole book read and the client says no by id
        -- too (as Resolve decides): a partly read book proves nothing.
        local known = Game.SpellKnownById(a.id)
        if known then return "ok" end
        if known == nil or not book.complete then return nil, "Couldn't read your spells; try again." end
        return "left"
    elseif a.kind == "item" then
        local n = Game.ItemCountRead(a.id)
        if n == nil then return nil, "Couldn't read your bags; try again." end
        return n > 0 and "ok" or "left"
    elseif a.kind == "macro" then
        local m = Game.MacrosNamed(a.name)
        if m == nil then return nil, "Couldn't read your macros; try again." end
        return #m == 1 and "ok" or "left"
    elseif a.what == "unreadable" or a.what == "macros unreadable" then
        return nil, "Couldn't read your action bars; try again."
    end
    return "left"
end

local function SnapshotNow(reason)
    local Game = G()
    local blocked = Loadout.Blocked()
    if blocked then return nil, blocked end
    local snap = { reason = reason, actions = {}, keys = {}, createdMacros = {},
                   characterBindings = Game.CharacterBindings() }
    local left = {}
    local book = Game.Spellbook()
    for _, slot in ipairs(Game.SLOT_LIST) do
        local a = Game.ActionAt(slot)
        local verdict, why = Classify(a, book)
        if not verdict then return nil, why end
        if verdict == "ok" then
            snap.actions[slot] = a or false
        else
            left[#left + 1] = { slot = slot, what = a and (a.what or a.kind) or "?" }
        end
    end
    if snap.characterBindings then
        for _, cmd in ipairs(Game.COMMANDS) do
            local keys = Game.KeysFor(cmd)
            if not keys then return nil, "Couldn't read your key bindings; try again." end
            for _, key in ipairs(keys) do snap.keys[key] = cmd end
        end
    end
    local pet, why = ASS.Pet.SnapshotNow()
    if pet == false then return nil, why end
    snap.pet = pet
    return snap, left
end

-- What a backup holds and how restoring it behaves: its slots, keys, pet
-- bar, binding set, and the macros a restore would edit or keep. The pet
-- counts by what Pet.PlanRestore matches (family and name) and its slots;
-- its GUID changes on every summon (measured), so it's left out.
local function Content(s)
    local pet = s.pet and { f = s.pet.family, n = s.pet.name, s = s.pet.slots } or false
    return Serialize({ a = s.actions or {}, k = s.keys or {}, p = pet, cb = s.characterBindings and true or false,
                       e = s.editedMacros or false, c = s.createdMacros or {} })
end

-- What Back up now would do: the snapshot, what it leaves out, whether the
-- newest backup already holds exactly this, and which backup a full ring
-- would drop. The fingerprint covers all of it, so a confirm whose fresh
-- plan differs is refused.
function Loadout.PlanBackup()
    local snap, left = SnapshotNow("Manual")
    if not snap then return nil, left end
    local ring = ASS.Backups.List()
    local p = { snap = snap, left = left, count = 0, keys = 0, noKeys = not snap.characterBindings }
    for _, a in pairs(snap.actions) do if a then p.count = p.count + 1 end end
    for _ in pairs(snap.keys) do p.keys = p.keys + 1 end
    -- "Nothing new" only against a backup that restores the same way: Content
    -- includes the binding set and any macro edits, which a load's backup can
    -- carry and a manual one never does.
    p.matches = ring[1] ~= nil and Content(ring[1]) == Content(snap)
    if #ring >= ASS.Backups.RING then p.evicts = ring[#ring] end
    -- Everything the preview shows, by value: the content, what is left out,
    -- and the backup that would drop (its content and time, not a reference).
    p.fingerprint = Serialize({ s = Content(snap), l = left, n = #ring,
        ev = p.evicts and { Content(p.evicts), p.evicts.at or false, p.evicts.reason or false } or false })
    return p
end

-- Store it. Re-planned and refused unless it is what the caller was shown.
function Loadout.Backup(shown)
    local p, err = Loadout.PlanBackup()
    if not p then return nil, err end
    if p.fingerprint ~= shown.fingerprint then return nil, "Something changed since the preview: review it again." end
    if p.matches then return nil, "Your newest backup already matches this character." end
    p.snap.at = time and time() or 0
    local ok, why = ASS.Backups.PushRing(p.snap)
    if not ok then return nil, why end
    return p
end

function Loadout.PlanRestore(which)
    local Game = G()
    local snap = ASS.Backups.Get(which)
    local plan = { kind = "restore", which = which, actions = {}, creates = {}, edits = {}, keys = {}, skips = {},
                   unavailable = {} }
    if not snap then plan.blocked = "No such backup." return Finish(plan) end
    plan.blocked = Loadout.Blocked()
    if plan.blocked then return Finish(plan) end
    local book = Game.Spellbook()
    -- The character macros the backed-up operation updated (#6), each now:
    -- as it was (already restored, or the update never ran): nothing to do;
    -- as that operation left it: put back; anything else (edited again,
    -- gone, two of that name): left as is, and the restore stays partial.
    -- `view`: their text once this restore has run.
    local view = {}
    local edited = type(snap.editedMacros) == "table" and snap.editedMacros or {}
    for i = #edited, 1, -1 do
        local e = edited[i]
        local m = Game.MacrosNamed(e.name)
        local one = m and #m == 1 and m[1].scope == "char" and type(m[1].body) == "string" and m[1]
        local function is(x)
            return one and type(x) == "table" and type(x.body) == "string"
                and Game.Normalize(one.body) == Game.Normalize(x.body) and one.icon == x.icon
        end
        if is(e.before) then
            view[e.name] = e.before
        elseif is(e.after) then
            plan.edits[#plan.edits + 1] = { name = e.name, from = { body = one.body, icon = one.icon },
                                            to = ASS.Catalog.Copy(e.before) }
            view[e.name] = e.before
        else
            plan.unavailable[#plan.unavailable + 1] = { name = tostring(e.name),
                reason = m == nil and "macros unreadable" or "changed since the load, left as is" }
        end
    end
    local function View(a)
        local v = a and a.kind == "macro" and a.scope == "char" and view[a.name]
        if not v then return a end
        local c = ASS.Catalog.Copy(a)
        c.body, c.icon = v.body, v.icon
        return c
    end
    local slots = {}
    for slot in pairs(snap.actions or {}) do slots[#slots + 1] = slot end
    table.sort(slots)
    for _, slot in ipairs(slots) do
        local want = snap.actions[slot]
        local current = Game.IS_SLOT[slot] and View(Game.ActionAt(slot))
        local target, why
        if not Game.IS_SLOT[slot] then
            why = "not supported on this build"
        elseif want == false then
            target = nil
        elseif want.kind == "spell" then
            if Game.SpellKnown(want.id, book) then target = { kind = "spell", id = want.id } else why = "spell no longer known" end
        elseif want.kind == "item" then
            if Game.ItemCount(want.id) > 0 then target = { kind = "item", id = want.id } else why = "item not in bags" end
        elseif want.kind == "macro" then
            -- As the macro will be after the reverts above.
            local m = Game.MacrosNamed(want.name)
            local live = m and #m == 1 and m[1].scope == want.scope
                and View({ kind = "macro", name = want.name, scope = want.scope, body = m[1].body, icon = m[1].icon })
            if live and Game.Normalize(live.body) == Game.Normalize(want.body) then
                target = { kind = "macro", name = want.name, body = live.body, scope = want.scope }
            else
                why = "macro gone or changed"
            end
        else
            why = "not restorable"
        end
        if not why and not Game.SameAction(current, target) and not Game.Restorable(current, book) then
            why = "slot now holds something that couldn't be put back"
        end
        if why and not Game.IS_SLOT[slot] then
            -- No build of this one writes it: listed, and the backup can still
            -- finish (otherwise it would stay "partial" forever).
            plan.skips[#plan.skips + 1] = { slot = slot, reason = why }
        elseif why then
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
    -- The pet bar: only with the backup's pet out (family and name, #47).
    plan.pet = ASS.Pet.PlanRestore(snap.pet)
    if Unsaved() and Game.CharacterBindings() then plan.resave = true end
    if plan.blocked then plan.actions, plan.edits, plan.keys, plan.resave, plan.pet = {}, {}, {}, nil, nil end
    return Finish(plan)
end

-- Is everything the snapshot asks for back (nothing unavailable or blocked)?
local function Complete(plan, result)
    return not (result and result.failed) and #plan.unavailable == 0 and not plan.keysBlocked
        and not (plan.pet and (plan.pet.missing or #plan.pet.skips > 0))
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
        -- The bars no longer hold what the last load left: Save must not read
        -- the restore as edits, so the comparison goes (load again to save).
        local rec = ASS.char.loaded and ASS.char.loaded.loadout
        if rec then rec.after, rec.unavailable = nil, nil end
    end
    result.unavailable, result.kept, result.skips = plan.unavailable, plan.kept, plan.skips
    result.keysBlocked = plan.keysBlocked
    result.petPlan = plan.pet
    result.partial = not Complete(plan, result) or nil
    -- The pinned operation is released only when it is fully restored.
    if which == "op" and Complete(plan, result) then
        ASS.Backups.Release()
        ASS.char.interrupted = nil
    end
    return result
end
