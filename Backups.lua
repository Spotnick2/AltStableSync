------------------------------------------------------------
-- Backups.lua - exact runtime snapshots per character (#4, #8)
--
-- backups[guid] = {
--   ring = { newest first, at most RING },
--   firstSeen = <the first snapshot ever taken for this character, kept forever>,
--   operation = { snapshot, op } | nil,   -- pinned: an operation that started
-- }                                       -- and has not completed
--
-- Lifecycle (docs/DESIGN.md safety rule 1, #4 scope): an operation pins its
-- pre-write snapshot in `operation` BEFORE its first write. Completing moves
-- it into the ring. Any incomplete outcome leaves it pinned; the only ways
-- out are restoring it or abandoning it (which also moves it into the ring).
-- At most one operation is pinned per character. A restore's own pre-write
-- snapshot always goes straight into the ring.
------------------------------------------------------------

AltStableSync = AltStableSync or {}
local ASS = AltStableSync

local RING = 10

local Backups = {}
ASS.Backups = Backups
Backups.RING = RING

local function Now() return time and time() or 0 end

-- This character's record. Only writers pass `create`: reading never adds or
-- repairs anything (the panel reads it every half second, #9). A record
-- without a ring still shows its pinned operation and first backup; only the
-- writers give it a ring.
local function Store(create)
    local guid = UnitGUID("player")
    if type(guid) ~= "string" then return nil end
    local all = ASS.db.backups
    if not all[guid] then
        if not create then return nil end
        all[guid] = { ring = {} }
    end
    local b = all[guid]
    if create and type(b.ring) ~= "table" then b.ring = {} end
    return b
end

local function Ring(b) return type(b.ring) == "table" and b.ring or {} end

local function First(b, snapshot)
    if b.firstSeen then return end
    b.firstSeen = ASS.Catalog.Copy(snapshot)
    -- This tiny mutable journal is filled after Show, including when Show
    -- throws after mutation. The first backup represents the same operation.
    -- Both serialized copies then retain its proof; other snapshots don't share it.
    if snapshot.damageMeter then
        b.firstSeen.damageMeter.journal = snapshot.damageMeter.journal
    end
    -- The macros a load creates are journaled during Execute, after this
    -- copy: shared the same way, so the first backup lists them as kept too.
    if snapshot.createdMacros then b.firstSeen.createdMacros = snapshot.createdMacros end
end

-- Newest first; past RING the oldest goes, except `keep` (the snapshot a
-- restore is reading from, so restoring the oldest backup can be retried).
local function Push(b, snapshot, keep)
    table.insert(b.ring, 1, snapshot)
    while #b.ring > RING do
        local i = #b.ring
        if b.ring[i] == keep then i = i - 1 end
        table.remove(b.ring, i)
    end
    First(b, snapshot)
end

function Backups.Operation()
    local b = Store()
    return b and b.operation
end

-- Pin `snapshot` for operation `op` ({ kind, id, version, name }). Refuses
-- when another operation is already pinned.
function Backups.Pin(snapshot, op)
    local b = Store(true)
    if not b then return nil, "no-guid" end
    if b.operation then return nil, "incomplete" end
    snapshot.at = snapshot.at or Now()
    b.operation = { snapshot = snapshot, op = op }
    First(b, snapshot)
    return true
end

-- The pinned operation completed, or the player abandoned it: into the ring.
function Backups.Release()
    local b = Store(true)
    if not b or not b.operation then return end
    local snap = b.operation.snapshot
    snap.op = b.operation.op
    b.operation = nil
    Push(b, snap)
end

-- A restore's own pre-write snapshot; `keep` is the snapshot being restored.
function Backups.PushRing(snapshot, keep)
    local b = Store(true)
    if not b then return nil, "no-guid" end
    snapshot.at = snapshot.at or Now()
    Push(b, snapshot, keep)
    return true
end

-- "op" for the pinned one, "first", or a ring index (1 = newest). Anything
-- else is nil: an unrecognised name never falls back to some other backup.
function Backups.Get(which)
    local b = Store()
    if not b then return nil end
    if which == "op" then return b.operation and b.operation.snapshot end
    if which == "first" then return b.firstSeen end
    local n = tonumber(which)
    if n and n == math.floor(n) then return Ring(b)[n] end
    return nil
end

function Backups.List()
    local b = Store()
    return b and Ring(b) or {}, b and b.operation, b and b.firstSeen
end
