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

local function Store()
    local guid = UnitGUID("player")
    if type(guid) ~= "string" then return nil end
    local all = ASS.db.backups
    all[guid] = all[guid] or { ring = {} }
    local b = all[guid]
    b.ring = b.ring or {}
    return b
end

local function Push(b, snapshot)
    table.insert(b.ring, 1, snapshot)
    while #b.ring > RING do table.remove(b.ring) end
    if not b.firstSeen then b.firstSeen = ASS.Catalog.Copy(snapshot) end
end

function Backups.Operation()
    local b = Store()
    return b and b.operation
end

-- Pin `snapshot` for operation `op` ({ kind, id, version, name }). Refuses
-- when another operation is already pinned.
function Backups.Pin(snapshot, op)
    local b = Store()
    if not b then return nil, "no-guid" end
    if b.operation then return nil, "incomplete" end
    snapshot.at = snapshot.at or Now()
    b.operation = { snapshot = snapshot, op = op }
    if not b.firstSeen then b.firstSeen = ASS.Catalog.Copy(snapshot) end
    return true
end

-- The pinned operation completed, or the player abandoned it: into the ring.
function Backups.Release()
    local b = Store()
    if not b or not b.operation then return end
    local snap = b.operation.snapshot
    snap.op = b.operation.op
    b.operation = nil
    Push(b, snap)
end

-- A restore's own pre-write snapshot.
function Backups.PushRing(snapshot)
    local b = Store()
    if not b then return nil, "no-guid" end
    snapshot.at = snapshot.at or Now()
    Push(b, snapshot)
    return true
end

-- "op" for the pinned one, a ring index (1 = newest), or "first".
function Backups.Get(which)
    local b = Store()
    if not b then return nil end
    if which == "op" then return b.operation and b.operation.snapshot end
    if which == "first" then return b.firstSeen end
    return b.ring[tonumber(which) or 1]
end

function Backups.List()
    local b = Store()
    return b and b.ring or {}, b and b.operation, b and b.firstSeen
end
