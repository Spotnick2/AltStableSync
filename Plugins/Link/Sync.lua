------------------------------------------------------------
-- Sync.lua - the catalog exchange between the owner's WoW accounts (#18)
--
-- docs/DESIGN.md "Catalog sync" is the contract. A factory with no WoW
-- dependencies, so two instances can talk to each other in one test:
--
--   local s = ASS.Sync.New{ catalog, envelope, transport, now, report, maxPayload, gen }
--   s.Receive(payload, sender)    from LibAccountSync's OnMessage
--   s.Tick()                      once a second
--   s.LocalWrite()                after a LOCAL catalog write (never a receipt)
--   s.Refresh()                   the manual Refresh
--
-- Messages ("<kind>\n<envelope>", each size-checked whole):
--   MAN  a manifest batch { g = generation, p = part, n = parts, l = { [id] = version } }
--   REQ  one id we want { i = id }                    -> SendTo that peer
--   ENT  one entry (Envelope.Encode)                  -> SendTo that peer
-- Each side PULLS what it lacks from the other's manifest; nothing is pushed.
--
-- Received entries go through Catalog.Upsert and nowhere else: this file
-- never reads or writes game state, and never applies anything (A40).
------------------------------------------------------------

AltStableSync = AltStableSync or {}
local ASS = AltStableSync

local Sync = {}
ASS.Sync = Sync

local BATCH_SIZES = { 100, 50, 25 }  -- ids per manifest batch, shrunk until it fits
local COALESCE = 2                   -- seconds: local writes -> one exchange
local INTERVAL = 120                 -- seconds between exchanges while a peer is listed
local POLL = 10                      -- seconds between Peers() polls
local MAX_OUT = 3                    -- outstanding requests per peer
local REQ_TIMEOUT = 30               -- seconds before an outstanding request expires (and may be asked again)

Sync.BATCH_SIZES, Sync.MAX_OUT, Sync.REQ_TIMEOUT, Sync.INTERVAL = BATCH_SIZES, MAX_OUT, REQ_TIMEOUT, INTERVAL

local function Contains(list, value)
    for _, v in ipairs(list or {}) do if v == value then return true end end
    return false
end

local function Count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- "Name-Realm", or the name alone: LibAccountSync may report no realm.
local function Label(sender)
    local name = type(sender.name) == "string" and sender.name ~= "" and sender.name or "?"
    if type(sender.realm) == "string" and sender.realm ~= "" then return name .. "-" .. sender.realm end
    return name
end
Sync.Label = Label

function Sync.New(o)
    local C, Env, T = o.catalog, o.envelope, o.transport
    local now = o.now
    local report = o.report or function() end
    local maxPayload = o.maxPayload or 16384
    local self = {}
    local peers = {}          -- [guid] = peer state
    local genBase, genN = tostring(o.gen or "g"), 0
    local exchangeDue         -- time a coalesced exchange is due
    local lastExchange       -- time of the last exchange
    local lastPoll
    local handled = {}        -- ["id@version"] = true: received and settled this session
    local tooLarge = {}       -- [id] = version that couldn't be sent
    local said = {}           -- one-shot report lines

    local function Once(key, text)
        if said[key] then return end
        said[key] = true
        report(text)
    end

    local function Peer(guid, label)
        local p = peers[guid]
        if not p then
            p = { guid = guid, label = label or "?", manifest = nil, acc = nil,
                  queue = {}, queued = {}, out = {} }
            peers[guid] = p
        end
        if label then p.label = label end
        return p
    end

    -- The whole string handed to the transport, or nil when it doesn't fit.
    local function Frame(kind, body)
        if not body then return nil end
        local msg = kind .. "\n" .. body
        if #msg > maxPayload then return nil end
        return msg
    end

    ------------------------------------------------------------
    -- Exchange: broadcast our manifest
    ------------------------------------------------------------

    function self.Exchange()
        exchangeDue, lastExchange = nil, now()
        genN = genN + 1
        local gen = genBase .. ":" .. genN
        local ids = {}
        local manifest = C.Manifest()
        for id in pairs(manifest) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, size in ipairs(BATCH_SIZES) do
            local parts = math.max(1, math.ceil(#ids / size))
            local msgs, fits = {}, true
            for p = 1, parts do
                local l = {}
                for i = (p - 1) * size + 1, math.min(p * size, #ids) do l[ids[i]] = manifest[ids[i]] end
                local msg = Frame("MAN", Env.Pack({ s = Env.SCHEMA, g = gen, p = p, n = parts, l = l }))
                if not msg then fits = false break end
                msgs[p] = msg
            end
            if fits then
                for _, msg in ipairs(msgs) do T.Send(msg) end
                return true
            end
        end
        Once("man-too-large", "Couldn't send the list of saved setups: it is too large to sync.")
        return false
    end

    function self.LocalWrite()
        if not exchangeDue then exchangeDue = now() + COALESCE end
    end

    function self.Refresh()
        self.Exchange()
    end

    ------------------------------------------------------------
    -- Requests: one id each, at most MAX_OUT outstanding per peer
    ------------------------------------------------------------

    -- Do we lack what the peer lists for `id`?
    local function Lacks(id, version)
        if handled[id .. "@" .. version] then return false end
        local e = C.Get(id)
        if not e then return true end
        if e.version == version or Contains(e.ancestors, version) then return false end
        -- Divergent and already kept as a conflict copy: nothing new to fetch.
        if C.Get(id .. "~" .. version) then return false end
        return true
    end

    -- Queue `id` at the `version` the peer listed (the newest listing wins).
    local function Want(p, id, version)
        if not p.queued[id] then p.queue[#p.queue + 1] = id end
        p.queued[id] = version
    end

    local function Pump(p)
        local t = now()
        local i = 1
        while Count(p.out) < MAX_OUT and i <= #p.queue do
            local id = p.queue[i]
            if not Lacks(id, p.queued[id]) then
                table.remove(p.queue, i)                   -- arrived meanwhile
                p.queued[id] = nil
            elseif p.out[id] then
                i = i + 1                                  -- already asked: keep it queued
            else
                table.remove(p.queue, i)
                local version = p.queued[id]
                p.queued[id] = nil
                local msg = Frame("REQ", Env.Pack({ s = Env.SCHEMA, i = id }))
                if msg then
                    -- Bookkeeping first: the transport may answer synchronously.
                    p.out[id] = { expires = t + REQ_TIMEOUT, version = version }
                    T.SendTo(p.guid, msg)
                end
            end
        end
    end

    ------------------------------------------------------------
    -- Receiving
    ------------------------------------------------------------

    local function OnManifest(p, m)
        if type(m.g) ~= "string" or type(m.p) ~= "number" or type(m.n) ~= "number" or type(m.l) ~= "table" then return end
        if not p.acc or p.acc.g ~= m.g then p.acc = { g = m.g, n = m.n, got = {}, l = {} } end
        local acc = p.acc
        if acc.got[m.p] then return end
        acc.got[m.p] = true
        for id, v in pairs(m.l) do
            if type(id) == "string" and type(v) == "string" then
                acc.l[id] = v
                if Lacks(id, v) then Want(p, id, v) end
            end
        end
        if Count(acc.got) >= acc.n then p.manifest, p.acc = acc.l, nil end
        Pump(p)
    end

    local function OnRequest(p, m)
        if type(m.i) ~= "string" then return end
        local e = C.Get(m.i)
        if not e then return end
        local msg = Frame("ENT", (Env.Encode(e)))
        if not msg then
            tooLarge[e.id] = e.version
            Once("big:" .. e.id .. "@" .. e.version, ("%q is too large to sync; it stays on this account.")
                :format(tostring(e.name)))
            return
        end
        T.SendTo(p.guid, msg)
    end

    local function OnEntry(p, body)
        local entry, why = Env.Decode(body)
        if not entry then
            Once("bad:" .. tostring(why), "Ignored a saved setup from " .. p.label .. " that this version can't read ("
                .. tostring(why) .. ").")
            return
        end
        if type(entry.id) == "string" then p.out[entry.id] = nil end
        local result = C.Upsert(entry, p.label)
        if type(entry.id) == "string" and type(entry.version) == "string" and result then
            handled[entry.id .. "@" .. entry.version] = true
        end
        if result == "conflict" then
            report(("%q was changed on both accounts. The version from %s is kept as a copy: /altsync conflicts")
                :format(tostring(entry.name), p.label))
        elseif not result then
            Once("bad-entry:" .. tostring(entry.id), "Ignored a saved setup from " .. p.label .. " that this version can't read.")
        end
        Pump(p)
    end

    function self.Receive(payload, sender)
        if type(payload) ~= "string" or type(sender) ~= "table" or type(sender.guid) ~= "string" then return end
        local kind, body = payload:match("^(%u%u%u)\n(.*)$")
        if not kind then return end
        local p = Peer(sender.guid, Label(sender))
        if kind == "ENT" then return OnEntry(p, body) end
        local m = Env.Unpack(body)
        if not m then return end
        if kind == "MAN" then return OnManifest(p, m) end
        if kind == "REQ" then return OnRequest(p, m) end
    end

    ------------------------------------------------------------
    -- Timer
    ------------------------------------------------------------

    function self.Tick()
        local t = now()
        if not lastPoll or t - lastPoll >= POLL then
            lastPoll = t
            local listed = {}
            for _, info in ipairs(T.Peers() or {}) do
                if type(info) == "table" and type(info.guid) == "string" then
                    listed[info.guid] = true
                    local p = peers[info.guid]
                    if not p or not p.listed then
                        Peer(info.guid, Label(info)).listed = true
                        if not exchangeDue then exchangeDue = t end      -- a peer sighting
                    end
                end
            end
            for guid, p in pairs(peers) do
                if not listed[guid] then p.listed = nil end
            end
        end
        if exchangeDue and t >= exchangeDue then
            self.Exchange()
        elseif lastExchange and t - lastExchange >= INTERVAL then
            for _, p in pairs(peers) do
                if p.listed then self.Exchange() break end
            end
        end
        for _, p in pairs(peers) do
            -- An expired request goes back in the queue (at its end) while we
            -- still lack it: a lost message is retried without waiting for
            -- the next manifest. MAX_OUT and REQ_TIMEOUT bound the traffic,
            -- even for an id the peer never answers (too large on its side).
            for id, o in pairs(p.out) do
                if t >= o.expires then
                    p.out[id] = nil
                    if Lacks(id, o.version) then Want(p, id, o.version) end
                end
            end
            Pump(p)
        end
    end

    ------------------------------------------------------------
    -- Status
    ------------------------------------------------------------

    -- The listed peers: { label, guid, complete = has a whole manifest }.
    function self.Peers()
        local out = {}
        for _, p in pairs(peers) do
            if p.listed then out[#out + 1] = { label = p.label, guid = p.guid, complete = p.manifest ~= nil } end
        end
        table.sort(out, function(a, b) return a.label < b.label end)
        return out
    end

    -- "confirmed" when every listed peer's (or just `guid`'s) manifest has our
    -- exact version, "too large", or "pending"; nil with no listed peer.
    function self.EntryStatus(e, guid)
        if tooLarge[e.id] == e.version then return "too large" end
        local any = false
        for _, p in pairs(peers) do
            if p.listed and (guid == nil or p.guid == guid) then
                any = true
                if not (p.manifest and p.manifest[e.id] == e.version) then return "pending" end
            end
        end
        return any and "confirmed" or nil
    end

    function self.Outstanding(guid)
        local p = peers[guid]
        return p and Count(p.out) or 0, p and #p.queue or 0
    end

    return self
end
