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

-- Live entries of one list (kind, and for loadouts class + category), sorted
-- by name. Unresolved conflict copies are included (`entry.conflict` set);
-- tombstones and retired copies are not.
function Catalog.List(kind, class, category)
    local out = {}
    for _, e in pairs(Presets()) do
        if type(e) == "table" and not e.deleted and SameList(e, kind, class, category) then
            out[#out + 1] = e
        end
    end
    table.sort(out, function(a, b)
        local x, y = tostring(a.name):lower(), tostring(b.name):lower()
        if x ~= y then return x < y end
        return a.id < b.id
    end)
    return out
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

-- Save As: a new entry. meta = { class, category, name, provenance }.
function Catalog.Create(kind, meta, modules)
    meta = meta or {}
    if kind ~= "ui" and kind ~= "loadout" then return nil, "bad-kind" end
    local class, category
    if kind == "loadout" then
        class, category = meta.class, meta.category
        if not (ASS.Categories and ASS.Categories.List(class)) then return nil, "bad-class" end
        if not ASS.Categories.IsValid(class, category) then return nil, "bad-category" end
    end
    if type(modules) ~= "table" then return nil, "bad-modules" end
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

-- Save over the entry: new content, a new version descending from the old
-- one, and the old content kept as `previous` (local "undo my last Save").
function Catalog.Replace(id, modules, expectedVersion, provenance)
    local e, err = Editable(id, expectedVersion)
    if not e then return nil, err end
    if type(modules) ~= "table" then return nil, "bad-modules" end
    local old = { modules = e.modules, updated = e.updated }
    Advance(e)
    e.previous = { of = e.version, modules = old.modules, updated = old.updated }
    e.modules = Copy(modules)
    if provenance then e.provenance = Copy(provenance) end
    return e
end

function Catalog.Rename(id, name, expectedVersion)
    local e, err = Editable(id, expectedVersion)
    if not e then return nil, err end
    local trimmed, nerr = Catalog.ValidateName(e.kind, e.class, e.category, name, id)
    if not trimmed then return nil, nerr end
    Advance(e)
    e.name = trimmed
    return e
end

-- A versioned tombstone: the content goes, the identity and name stay, so a
-- stale peer can't resurrect it and a later conflict can still be named.
function Catalog.Delete(id, expectedVersion)
    local e, err = Editable(id, expectedVersion)
    if not e then return nil, err end
    Advance(e)
    e.deleted, e.modules, e.previous = true, nil, nil
    return e
end

-- Undo my last Save: only while that Save is still the current version, so
-- it can never overwrite a newer Save from the other account. It is itself a
-- Save (a successor, which sync carries), and it is not repeatable.
function Catalog.UndoLastSave(id, expectedVersion)
    local e, err = Editable(id, expectedVersion)
    if not e then return nil, err end
    local prev = e.previous
    if not prev or prev.of ~= e.version then return nil, "no-undo" end
    Advance(e)
    e.modules = Copy(prev.modules)
    e.previous = nil
    return e
end

-- Forward declarations: Upsert and Resolve both tidy covered conflict copies.
local Retire, RetireCovered

------------------------------------------------------------
-- Receiving from the other account (#18): docs/DESIGN.md "Receive rules"
------------------------------------------------------------

local function ValidIncoming(x)
    if type(x) ~= "table" then return false end
    if type(x.id) ~= "string" or x.id == "" or type(x.version) ~= "string" then return false end
    if x.kind ~= "ui" and x.kind ~= "loadout" then return false end
    if x.ancestors ~= nil and type(x.ancestors) ~= "table" then return false end
    local contentless = x.deleted or (type(x.conflict) == "table" and x.conflict.deletion)
    if not contentless and type(x.modules) ~= "table" then return false end
    return true
end

-- A clean local copy of an incoming entry: never its `previous` (local Save
-- recovery belongs to the account that saved), ancestors capped.
local function Sanitize(x)
    local e = Copy(x)
    e.previous = nil
    e.ancestors = AncestorList({}, e.ancestors)
    return e
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
    local cid = id .. "~" .. incoming.version
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
    local covered = {}
    for cid, c in pairs(p) do
        if type(c) == "table" and type(c.conflict) == "table" and c.conflict.of == rootId
            and not c.deleted
            and (c.version == root.version or Contains(root.ancestors, c.version)) then
            covered[#covered + 1] = cid
        end
    end
    for _, cid in ipairs(covered) do Retire(cid) end
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
function Catalog.Resolve(copyId, choice, expectedRootVersion)
    local p = Presets()
    local copy = p[copyId]
    if not copy or not copy.conflict or copy.deleted then return nil, "not-conflict" end
    local root = p[copy.conflict.of]
    if not root then return nil, "unknown-id" end
    if root.version ~= expectedRootVersion then return nil, "stale" end

    local rootVersion, theirsVersion = root.version, copy.version
    -- Both competing tips first, then the other branch's own history (the
    -- root's is added by Advance), so a delayed older message from either
    -- branch is recognised as an ancestor and can't reopen the conflict.
    local both = AncestorList({ rootVersion, theirsVersion }, copy.ancestors)
    local deletedThere = copy.conflict.deletion
    local created

    if root.deleted then
        if deletedThere then return nil, "bad-choice" end      -- converges by tie-break instead
        if choice == "theirs" then
            local name = Catalog.ValidateName(root.kind, root.class, root.category, copy.conflict.name)
                or (tostring(copy.conflict.name) .. " (kept)")
            local err
            created, err = Catalog.Create(root.kind,
                { class = root.class, category = root.category, name = name, provenance = copy.provenance },
                copy.modules)
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
    return root, created
end

-- Deleting a conflict copy is "Keep mine" (docs/DESIGN.md): there is no way to
-- discard a copy without resolving, or the roots would stay split.
function Catalog.DeleteConflictCopy(copyId, expectedRootVersion)
    return Catalog.Resolve(copyId, "mine", expectedRootVersion)
end

