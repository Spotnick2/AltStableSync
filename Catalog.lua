------------------------------------------------------------
-- Catalog.lua - the account-wide catalog of saved setups (#27)
--
-- Pure state over AltStableSyncDB.presets: no game-state reads or writes, no
-- events. docs/DESIGN.md ("Data model", "Catalog sync", "Preserve intent on
-- Save") is the contract; the rules below cite it rather than restate it.
--
-- Every entry has an opaque id (kind-writer-seq) and a version (writer:seq)
-- with its last MAX_ANCESTORS ancestors. Versions are ancestry, never numbers:
-- two accounts saving offline produce incomparable versions, which become a
-- conflict copy the player resolves - never a silent overwrite.
--
-- Every mutating call takes the version the caller last saw and refuses when
-- it is stale ("stale"), so a newer version that arrived from the other
-- account is never overwritten, renamed or deleted unreviewed.
--
-- Errors are short codes the UI turns into copy: unknown-id, deleted,
-- conflict-copy, not-conflict, stale, name-empty, name-duplicate, bad-kind,
-- bad-class, bad-category, bad-modules, bad-choice, no-undo, bad-entry.
-- bad-modules also covers a loadout without a valid `cover` (#5).
------------------------------------------------------------

AltStableSync = AltStableSync or {}
local ASS = AltStableSync

local MAX_ANCESTORS = 20

local Catalog = {}
ASS.Catalog = Catalog
Catalog.MAX_ANCESTORS = MAX_ANCESTORS

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function Presets() return ASS.db.presets end

local function Now() return time and time() or 0 end

local function Copy(v, seen)
    if type(v) ~= "table" then return v end
    seen = seen or {}
    if seen[v] then return seen[v] end
    local out = {}
    seen[v] = out
    for k, x in pairs(v) do out[Copy(k, seen)] = Copy(x, seen) end
    return out
end
Catalog.Copy = Copy

-- The Link addon (#18) listens for LOCAL writes, to tell the other account.
-- Receipts (Upsert, and the retirements it causes) never fire this.
local listeners = {}
function Catalog.OnLocalWrite(fn) listeners[#listeners + 1] = fn end
local function Wrote(e)
    if e then for _, fn in ipairs(listeners) do pcall(fn) end end
    return e
end

-- A new version token for this session's writer (Core.lua makes the token).
local function Mint()
    ASS.seq = (ASS.seq or 0) + 1
    return ASS.writer .. ":" .. ASS.seq, ASS.seq
end

local function Contains(list, value)
    for _, v in ipairs(list or {}) do
        if v == value then return true end
    end
    return false
end

-- `firsts` (in order), then each list in turn, without duplicates, capped.
local function AncestorList(firsts, ...)
    local out, seen = {}, {}
    local function add(v)
        if type(v) == "string" and not seen[v] and #out < MAX_ANCESTORS then
            seen[v] = true
            out[#out + 1] = v
        end
    end
    for _, v in ipairs(firsts) do add(v) end
    for i = 1, select("#", ...) do
        for _, v in ipairs(select(i, ...) or {}) do add(v) end
    end
    return out
end

-- Move `entry` to a new version that descends from its current one.
local function Advance(entry, extraAncestors)
    local version = Mint()
    entry.parent = entry.version
    entry.ancestors = AncestorList({ entry.version }, extraAncestors, entry.ancestors)
    entry.version = version
    entry.updated = Now()
    return entry
end

local function Trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end
Catalog.Trim = Trim

-- The deterministic id of a conflict copy: root id + "~" + its version.
local function CopyId(id, version) return id .. "~" .. version end

local function SameList(e, kind, class, category)
    if e.kind ~= kind then return false end
    if kind == "loadout" then return e.class == class and e.category == category end
    return true
end

-- The live entry `id`, or nil plus why it can't be changed.
local function Editable(id, expectedVersion)
    local e = Presets()[id]
    if not e then return nil, "unknown-id" end
    if e.deleted then return nil, "deleted" end
    if e.conflict then return nil, "conflict-copy" end
    if e.version ~= expectedVersion then return nil, "stale" end
    return e
end

------------------------------------------------------------
-- Reading
------------------------------------------------------------

function Catalog.Get(id) return Presets()[id] end

-- Live entries matching `keep`, sorted by name then id. Unresolved conflict
-- copies are included (`entry.conflict` set); tombstones and retired copies
-- are not.
local function Collect(keep)
    local out = {}
    for _, e in pairs(Presets()) do
        if type(e) == "table" and not e.deleted and keep(e) then out[#out + 1] = e end
    end
    table.sort(out, function(a, b)
        local x, y = tostring(a.name):lower(), tostring(b.name):lower()
        if x ~= y then return x < y end
        return a.id < b.id
    end)
    return out
end

-- One list: kind, and for loadouts class + category.
function Catalog.List(kind, class, category)
    return Collect(function(e) return SameList(e, kind, class, category) end)
end

-- Every category of `kind` (and `class`), including keys this build doesn't
-- know (a newer build's, received by sync).
function Catalog.ListAll(kind, class)
    return Collect(function(e) return e.kind == kind and (kind ~= "loadout" or e.class == class) end)
end

-- Every live conflict copy, of any kind and class.
function Catalog.Conflicts()
    return Collect(function(e) return type(e.conflict) == "table" end)
end

-- { [id] = version } for every entry, live, tombstoned or conflict copy: what
-- the Link addon (#18) exchanges.
function Catalog.Manifest()
    local out = {}
    for id, e in pairs(Presets()) do
        if type(e) == "table" and type(e.version) == "string" then out[id] = e.version end
    end
    return out
end

-- The trimmed name, or nil plus "name-empty" / "name-duplicate". A duplicate
-- is a live entry of the same list with the same name, ignoring case;
-- `exceptId` is the entry being renamed. Only local Save As / Rename check
-- this: names that arrive by sync are never rejected.
function Catalog.ValidateName(kind, class, category, name, exceptId)
    local trimmed = Trim(name)
    if trimmed == "" then return nil, "name-empty" end
    for _, e in ipairs(Catalog.List(kind, class, category)) do
        if e.id ~= exceptId and tostring(e.name):lower() == trimmed:lower() then
            return nil, "name-duplicate"
        end
    end
    return trimmed
end

------------------------------------------------------------
-- Local changes (each one is an explicit, confirmed player action)
------------------------------------------------------------

-- An array of exactly the keys 1..n (no holes, no other keys), n <= max,
-- each value passing `ok`.
local function ArrayOf(t, max, ok)
    if type(t) ~= "table" then return false end
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then return false end
        n = n + 1
    end
    if n > max then return false end
    for i = 1, n do
        if t[i] == nil or not ok(t[i]) then return false end
    end
    return true
end

local function Text(s, max) return type(s) == "string" and s ~= "" and #s <= max end

-- A chat message group token (ChatTypeGroup keys: "SAY", "BN_WHISPER", ...).
local function Group(s) return type(s) == "string" and #s <= 64 and s:match("^%u[%u%d_]*$") ~= nil end

local function Groups(t)
    if not ArrayOf(t, 80, Group) then return false end
    local seen = {}
    for _, g in ipairs(t) do
        if seen[g] then return false end
        seen[g] = true
    end
    return true
end

-- A UI setup's parts (#10). Every known part is optional, and a malformed
-- one rejects the entry, here or received. Unknown keys (a newer build's
-- parts) are kept as they are: never applied, kept by Save.
local function GoodUIModules(m)
    local meter = m.damageMeter
    if meter ~= nil then
        if type(meter) ~= "table" or type(meter.windows) ~= "table" then return false end
        local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
        for i = 1, 2 do
            local w = meter.windows[i]
            if type(w) ~= "table" or not finite(w.meterType) or w.meterType < 0
                or w.meterType ~= math.floor(w.meterType) or w.sessionType ~= 1
                or type(w.locked) ~= "boolean" or w.sessionID ~= nil then return false end
            local g = w.geometry
            if g ~= nil then
                if type(g) ~= "table" or not finite(g.x) or not finite(g.y) or g.x < 0 or g.y < 0
                    or not finite(g.width) or g.width < 200 or g.width > 600
                    or not finite(g.height) or g.height < 120 or g.height > 400
                    or (g.userPlaced ~= nil and type(g.userPlaced) ~= "boolean") then return false end
            end
        end
        for k in pairs(meter.windows) do
            if type(k) ~= "string" and k ~= 1 and k ~= 2 then return false end
        end
    end
    local l = m.layout
    if l ~= nil then
        if type(l) ~= "table" then return false end
        if l.type == 1 then
            if not Text(l.name, 64) then return false end
        elseif l.type == 0 then
            if type(l.index) ~= "number" or l.index < 1 or l.index > 3 or l.index ~= math.floor(l.index) then
                return false
            end
            if l.name ~= nil and not Text(l.name, 64) then return false end
        else
            return false
        end
    end
    local b = m.bars
    if b ~= nil then
        if type(b) ~= "table" then return false end
        for k, v in pairs(b) do
            if type(k) ~= "number" or k < 2 or k > 8 or k ~= math.floor(k) or type(v) ~= "boolean" then return false end
        end
        for i = 2, 8 do if b[i] == nil then return false end end
    end
    local c = m.cvars
    if c ~= nil then
        if type(c) ~= "table" then return false end
        for k, v in pairs(c) do
            if type(k) ~= "string" or #k > 64 or not k:match("^%a[%w_]*$") then return false end
            if type(v) ~= "string" or #v > 64 then return false end
        end
    end
    local ch = m.chat
    if ch ~= nil then
        if type(ch) ~= "table" then return false end
        if ch.primary ~= nil and not Groups(ch.primary) then return false end
        if ch.tabs ~= nil then
            local names = {}
            local function tab(t)
                if type(t) ~= "table" or not Text(t.name, 32) or names[t.name] or not Groups(t.groups) then
                    return false
                end
                names[t.name] = true
                return true
            end
            if not ArrayOf(ch.tabs, 9, tab) then return false end
        end
    end
    return true
end

-- Content an entry may hold: a table; a UI setup's with well-formed parts
-- (#10); a loadout's with a valid cover (#5) and every known part well
-- formed (#98, E1: Share.GoodModules, "lenient", so what A35 keeps from
-- another build still saves). Without the validator nothing passes.
local function GoodModules(kind, modules)
    if type(modules) ~= "table" then return false end
    if kind == "ui" then return GoodUIModules(modules) end
    if kind ~= "loadout" then return true end
    local S = ASS.Share
    return S ~= nil and S.GoodModules(modules, "lenient") == true
end
Catalog.GoodUIModules = GoodUIModules

-- A new entry. `keepKeys` is for keeping an entry that arrived from the other
-- account: its class/category stay as they are, even keys this build doesn't
-- know (a newer build's), exactly as the receive boundary accepted them.

local function NewEntry(kind, meta, modules, keepKeys)
    meta = meta or {}
    if kind ~= "ui" and kind ~= "loadout" then return nil, "bad-kind" end
    local class, category
    if kind == "loadout" then
        class, category = meta.class, meta.category
        if keepKeys then
            if type(class) ~= "string" or class == "" then return nil, "bad-class" end
            if type(category) ~= "string" or category == "" then return nil, "bad-category" end
        else
            if not (ASS.Categories and ASS.Categories.List(class)) then return nil, "bad-class" end
            if not ASS.Categories.IsValid(class, category) then return nil, "bad-category" end
        end
    end
    if not GoodModules(kind, modules) then return nil, "bad-modules" end
    local name, err = Catalog.ValidateName(kind, class, category, meta.name)
    if not name then return nil, err end
    local version, seq = Mint()
    local now = Now()
    local e = {
        id = kind .. "-" .. ASS.writer .. "-" .. seq,
        kind = kind, class = class, category = category, name = name,
        version = version, parent = nil, ancestors = {},
        created = now, updated = now,
        provenance = Copy(meta.provenance),
        modules = Copy(modules),
    }
    Presets()[e.id] = e
    return e
end

-- Save As: a new entry. meta = { class, category, name, provenance }. The
-- class and category must be ones this build offers.
function Catalog.Create(kind, meta, modules)
    local e, err = NewEntry(kind, meta, modules, false)
    return Wrote(e), err
end

-- Save over the entry: new content, a new version descending from the old
-- one, and the old content kept as `previous` (local "undo my last Save").
function Catalog.Replace(id, modules, expectedVersion, provenance)
    local e, err = Editable(id, expectedVersion)
    if not e then return nil, err end
    if not GoodModules(e.kind, modules) then return nil, "bad-modules" end
    local old = { modules = e.modules, updated = e.updated }
    Advance(e)
    e.previous = { of = e.version, modules = old.modules, updated = old.updated }
    e.modules = Copy(modules)
    if provenance then e.provenance = Copy(provenance) end
    return Wrote(e)
end

function Catalog.Rename(id, name, expectedVersion)
    local e, err = Editable(id, expectedVersion)
    if not e then return nil, err end
    local trimmed, nerr = Catalog.ValidateName(e.kind, e.class, e.category, name, id)
    if not trimmed then return nil, nerr end
    Advance(e)
    e.name = trimmed
    return Wrote(e)
end

-- A versioned tombstone: the content goes, the identity and name stay, so a
-- stale peer can't resurrect it and a later conflict can still be named.
function Catalog.Delete(id, expectedVersion)
    local e, err = Editable(id, expectedVersion)
    if not e then return nil, err end
    Advance(e)
    e.deleted, e.modules, e.previous = true, nil, nil
    return Wrote(e)
end

-- Undo my last Save: only while that Save is still the current version, so
-- it can never overwrite a newer Save from the other account. It is itself a
-- Save (a successor, which sync carries), and it is not repeatable.
function Catalog.UndoLastSave(id, expectedVersion)
    local e, err = Editable(id, expectedVersion)
    if not e then return nil, err end
    local prev = e.previous
    if not prev or prev.of ~= e.version then return nil, "no-undo" end
    if not GoodModules(e.kind, prev.modules) then return nil, "bad-modules" end
    Advance(e)
    e.modules = Copy(prev.modules)
    e.previous = nil
    return Wrote(e)
end

-- Forward declarations: Upsert and Resolve both tidy covered conflict copies.
local Retire, RetireCovered

------------------------------------------------------------
-- Receiving from the other account (#18): docs/DESIGN.md "Receive rules"
------------------------------------------------------------

local function OptionalType(v, t) return v == nil or type(v) == t end

-- The receive boundary admits only entries the catalog's own operations can
-- handle: every field this file reads has the type it expects, or is absent.
local function ValidIncoming(x)
    if type(x) ~= "table" then return false end
    if type(x.id) ~= "string" or x.id == "" or type(x.version) ~= "string" or x.version == "" then
        return false
    end
    if x.kind ~= "ui" and x.kind ~= "loadout" then return false end
    -- A loadout belongs to a class/category list or it can't be listed,
    -- resolved or kept. Any non-empty key is accepted (a newer build may add
    -- categories); Categories.Label shows an unknown key as itself.
    if x.kind == "loadout" and (type(x.class) ~= "string" or x.class == ""
                                or type(x.category) ~= "string" or x.category == "") then
        return false
    end
    if not (OptionalType(x.ancestors, "table") and OptionalType(x.deleted, "boolean")
            and OptionalType(x.name, "string") and OptionalType(x.class, "string")
            and OptionalType(x.category, "string") and OptionalType(x.modules, "table")
            and OptionalType(x.provenance, "table") and OptionalType(x.parent, "string")) then
        return false
    end
    if x.conflict ~= nil then
        local c = x.conflict
        if type(c) ~= "table" or type(c.of) ~= "string" or c.of == "" then return false end
        -- A conflict copy's id is always "<root id>~<version>" (Upsert makes it
        -- so), which also rules out a copy pointing at itself.
        if x.id:sub(1, #c.of + 1) ~= c.of .. "~" or #x.id <= #c.of + 1 then return false end
        if not (OptionalType(c.deletion, "boolean") and OptionalType(c.retired, "boolean")
                and OptionalType(c.name, "string") and OptionalType(c.from, "string")) then
            return false
        end
    end
    local contentless = x.deleted or (x.conflict and x.conflict.deletion)
    -- Every schema-2 sender stamps a loadout's cover (#5).
    if not contentless and not GoodModules(x.kind, x.modules) then return false end
    return true
end

-- The fields an entry may carry (#98, E3); anything else a peer sends is
-- dropped, never stored or sent on. Never `previous`: local Save recovery
-- belongs to the account that saved.
local ENTRY_FIELDS = { id = true, kind = true, class = true, category = true, name = true, version = true,
                       parent = true, ancestors = true, created = true, updated = true, provenance = true,
                       modules = true, deleted = true, conflict = true }
local CONFLICT_FIELDS = { of = true, from = true, name = true, deletion = true, retired = true }
local TIME_MAX = 2 ^ 31          -- display times: a whole second before 2038, else dropped

local function Time(t)
    if type(t) == "number" and t == t and t >= 0 and t < TIME_MAX then return t end
    return nil
end
Catalog.Time = Time

-- A clean local copy of an incoming entry: the known fields only, times
-- that `date` can show, provenance as text, ancestors capped.
local function Sanitize(x)
    local e = {}
    for k, v in pairs(x) do
        if ENTRY_FIELDS[k] then e[k] = Copy(v) end
    end
    e.created, e.updated = Time(e.created), Time(e.updated)
    if type(e.provenance) == "table" then
        local p = e.provenance
        e.provenance = { sourceChar = type(p.sourceChar) == "string" and p.sourceChar or nil,
                         build = type(p.build) == "string" and p.build or nil }
    end
    if type(e.conflict) == "table" then
        for k in pairs(e.conflict) do
            if not CONFLICT_FIELDS[k] then e.conflict[k] = nil end
        end
    end
    e.ancestors = AncestorList({}, e.ancestors)
    return e
end

-- An entry keeps its identity under one id (#98, E5): nothing here ever
-- changes a stored entry's kind, class or category, so an incoming version
-- that does is refused, never a silent move to another list.
local function SameIdentity(a, b)
    return a.kind == b.kind and a.class == b.class and a.category == b.category
end

-- Would receiving `id` at `version` change anything here? False when we hold
-- that version or have moved past it, or already keep it as a conflict copy:
-- Upsert would ignore it. The Link addon asks this before fetching an entry.
-- (A copy of OUR version listed by the other account can't be told apart from
-- its retired tombstone by id and version alone, so it is fetched once.)
function Catalog.Wants(id, version)
    if type(id) ~= "string" or type(version) ~= "string" then return false end
    local p = Presets()
    local e = p[id]
    if not e then return true end
    if e.version == version or Contains(e.ancestors, version) then return false end
    if p[CopyId(id, version)] then return false end
    return true
end

-- Apply one entry received from `fromChar`'s account. Returns the action
-- taken: "ignore", "replace", "conflict", or nil plus "bad-entry". Never
-- touches game state, and never applies anything to a character.
function Catalog.Upsert(incoming, fromChar)
    if not ValidIncoming(incoming) then return nil, "bad-entry" end
    local p = Presets()
    local id = incoming.id
    local local_ = p[id]

    -- A live conflict copy of a version our root already holds (or has moved
    -- past) is the other account's copy of OUR content: nothing to keep.
    -- Retired copies (tombstones) still propagate, which is how a resolution
    -- settles both accounts.
    -- A conflict copy carries its root's identity (Upsert makes it from a
    -- version of that root); one that doesn't is refused like any change.
    if type(incoming.conflict) == "table" then
        local root = p[incoming.conflict.of]
        if root and not SameIdentity(root, incoming) then return nil, "bad-entry" end
    end
    if local_ and not SameIdentity(local_, incoming) then return nil, "bad-entry" end

    if type(incoming.conflict) == "table" and not incoming.deleted then
        local root = p[incoming.conflict.of]
        if root and (root.version == incoming.version or Contains(root.ancestors, incoming.version)) then
            return "ignore"
        end
    end

    if not local_ then
        p[id] = Sanitize(incoming)
        return "replace"
    end
    if local_.version == incoming.version then return "ignore" end
    -- Older than what we hold (includes a stale copy of our own predecessor).
    if Contains(local_.ancestors, incoming.version) then return "ignore" end
    -- A descendant of what we hold: fast-forward. Our `previous` stays: it is
    -- this account's own undo, and its `of` no longer matches, so it lapses.
    if Contains(incoming.ancestors, local_.version) then
        local e = Sanitize(incoming)
        e.previous = local_.previous
        p[id] = e
        RetireCovered(id)
        return "replace"
    end
    -- Two incomparable tombstones are the same decision: both accounts keep
    -- the lexically greater token, so the roots converge.
    if local_.deleted and incoming.deleted then
        if incoming.version > local_.version then
            p[id] = Sanitize(incoming)
            return "replace"
        end
        return "ignore"
    end
    -- Divergent: keep ours, keep theirs whole as a deterministic conflict copy.
    -- A copy id that already exists, live or retired, means it was handled.
    local cid = CopyId(id, incoming.version)
    if p[cid] then return "ignore" end
    local copy = Sanitize(incoming)
    local originalName = incoming.name or local_.name
    copy.id = cid
    copy.conflict = { of = id, from = fromChar, name = originalName,
                      deletion = incoming.deleted and true or nil }
    copy.deleted = nil
    if copy.conflict.deletion then copy.modules = nil end
    copy.name = tostring(originalName) .. " (from " .. tostring(fromChar or "?") .. ")"
    p[cid] = copy
    return "conflict"
end

------------------------------------------------------------
-- Resolving a conflict copy
------------------------------------------------------------

-- Retire the stored conflict copy `cid`: a tombstone descending from the
-- copy's version, which travels like any other.
function Retire(cid)
    local c = Presets()[cid]
    if not c or c.deleted then return end
    Advance(c)
    c.deleted, c.modules = true, nil
    c.conflict.retired = true
end

-- Retire every stored live conflict copy of `rootId` whose version the root
-- now holds or descends from: its content is part of the root's history, so
-- it can't stay open (e.g. a copy of a version that was edited again before
-- the conflict was resolved). The retirements travel like any tombstone.
function RetireCovered(rootId)
    local p = Presets()
    local root = p[rootId]
    if not root then return end
    -- Retire only changes fields of existing entries (no keys added or
    -- removed), so calling it during pairs() is safe in Lua 5.1.
    for cid, c in pairs(p) do
        if type(c) == "table" and type(c.conflict) == "table" and c.conflict.of == rootId
            and not c.deleted
            and (c.version == root.version or Contains(root.ancestors, c.version)) then
            Retire(cid)
        end
    end
end

-- choice:
--   "theirs" - keep the copy's version (for a deleted root: save it as a new
--              entry, the root stays deleted);
--   "mine"   - keep what this account has (deleting a conflict copy means this);
--   "delete" - only when the other account deleted it: delete here too.
-- Either way the root gets a version descending from BOTH competing versions.
-- Every copy that version covers is retired here; the other account retires
-- its mirror the same way when it fast-forwards to it, so both settle.
-- Returns the root entry, plus the new entry for "theirs" over a deleted root.
-- `newName` (optional) names that new entry; otherwise the first free name.
function Catalog.Resolve(copyId, choice, expectedRootVersion, newName)
    local p = Presets()
    local copy = p[copyId]
    if not copy or not copy.conflict or copy.deleted then return nil, "not-conflict" end
    local root = p[copy.conflict.of]
    if not root then return nil, "unknown-id" end
    if root.version ~= expectedRootVersion then return nil, "stale" end
    -- A copy stored before its root arrived was checked against nothing; one
    -- that claims another kind, class or category never gives its content or
    -- its deletion to the root (#98, E5, Codex on PR #99). "Keep mine" takes
    -- nothing from it and still settles it.
    if choice ~= "mine" and not SameIdentity(root, copy) then return nil, "bad-copy" end

    local rootVersion, theirsVersion = root.version, copy.version
    -- Both competing tips first, then the other branch's own history (the
    -- root's is added by Advance), so a delayed older message from either
    -- branch is recognised as an ancestor and can't reopen the conflict.
    local both = AncestorList({ rootVersion, theirsVersion }, copy.ancestors)
    local deletedThere = copy.conflict.deletion
    local created

    if root.deleted then
        -- Deleted on both sides (deleted here after the deletion copy
        -- arrived): the only sensible answer is "keep it deleted".
        if deletedThere and choice ~= "mine" and choice ~= "delete" then return nil, "bad-choice" end
        if deletedThere then choice = "mine" end
        if choice == "theirs" then
            -- The caller's name if given (validated), else the original name, else
            -- the first free "<name> (kept)", "<name> (kept 2)", ...
            local base = tostring(copy.conflict.name or root.name)
            local name, nerr
            if newName ~= nil then
                name, nerr = Catalog.ValidateName(root.kind, root.class, root.category, newName)
                if not name then return nil, nerr end
            else
                name = Catalog.ValidateName(root.kind, root.class, root.category, base)
                local n = 1
                while not name and n <= 99 do
                    name = Catalog.ValidateName(root.kind, root.class, root.category,
                        base .. (n == 1 and " (kept)" or (" (kept " .. n .. ")")))
                    n = n + 1
                end
                if not name then return nil, "name-duplicate" end
            end
            local err
            created, err = NewEntry(root.kind,
                { class = root.class, category = root.category, name = name, provenance = copy.provenance },
                copy.modules, true)
            if not created then return nil, err end
        elseif choice ~= "mine" then
            return nil, "bad-choice"
        end
        Advance(root, both)                 -- a successor tombstone: still deleted
    elseif deletedThere then
        if choice == "delete" then
            Advance(root, both)
            root.deleted, root.modules, root.previous = true, nil, nil
        elseif choice == "mine" then
            Advance(root, both)
        else
            return nil, "bad-choice"
        end
    else
        if choice == "theirs" then
            -- The chosen version whole: content, name and provenance. Only the
            -- root's identity and the new resolution version are ours.
            if not GoodModules(root.kind, copy.modules) then return nil, "bad-modules" end
            Advance(root, both)
            root.modules = Copy(copy.modules)
            root.name = copy.conflict.name or root.name
            root.provenance = Copy(copy.provenance)
        elseif choice == "mine" then
            Advance(root, both)
        else
            return nil, "bad-choice"
        end
    end

    RetireCovered(root.id)
    Wrote(root)
    return root, created
end

-- Deleting a conflict copy is "Keep mine" (docs/DESIGN.md): there is no way to
-- discard a copy without resolving, or the roots would stay split.
function Catalog.DeleteConflictCopy(copyId, expectedRootVersion)
    return Catalog.Resolve(copyId, "mine", expectedRootVersion)
end

