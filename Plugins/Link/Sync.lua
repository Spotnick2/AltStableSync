------------------------------------------------------------
-- Sync.lua - the catalog exchange between the owner's WoW accounts (#18)
--
-- docs/DESIGN.md "Catalog sync" is the contract. A factory with no WoW
-- dependencies, so two instances can talk to each other in one test:
--
--   local s = ASS.Sync.New{ catalog, envelope, transport, now, report, maxPayload, gen }
--   s.Receive(payload, sender, sid) from LibAccountSync's OnMessage (sid grows per
--                                 sender, across its reloads too)
--   s.Tick()                      once a second
--   s.LocalWrite()                after a LOCAL catalog write (never a receipt)
--   s.Refresh()                   the manual Refresh
--
-- Messages ("<kind>\n...", each size-checked whole):
--   MAN\n<envelope>       a manifest batch { b = session, c = counter, p = part, n = parts,
--                         l = { [id] = version } }                     -> Send (broadcast)
--   REQ\n<envelope>       one id we want { i = id }                    -> SendTo that peer
--   ENT\n<id>\n<version>\n<envelope>
--                         one entry (Envelope.Encode); id and version travel outside the
--                         envelope so even a refused one is matched to ITS request only
-- Each side PULLS what it lacks from the other's manifest; nothing is pushed.
--
-- A peer counts (for "confirmed", status and requests) once it has spoken:
-- LibAccountSync lists every online account of the owner, with the Link addon
-- or not. Received entries go through Catalog.Upsert and nowhere else: this
-- file never reads or writes game state, and never applies anything (A40).
------------------------------------------------------------

AltStableSync = AltStableSync or {}
local ASS = AltStableSync

local Sync = {}
ASS.Sync = Sync

local BATCH_SIZES = { 100, 50, 25 }  -- ids per manifest batch, shrunk until it fits
local COALESCE = 2                   -- seconds: local writes -> one exchange
local INTERVAL = 120                 -- seconds between exchanges while a peer is listed
local RETRY = 5                      -- seconds before a manifest nobody took is sent again
local POLL = 10                      -- seconds between Peers() polls
local MAX_OUT = 3                    -- outstanding requests per peer
local REQ_TIMEOUT = 30               -- seconds before an outstanding request expires (and may be asked again)

Sync.BATCH_SIZES, Sync.MAX_OUT, Sync.REQ_TIMEOUT, Sync.INTERVAL, Sync.RETRY =
    BATCH_SIZES, MAX_OUT, REQ_TIMEOUT, INTERVAL, RETRY

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
    local peers = {}          -- [guid] = peer state, for listed peers only
    local session, counter = tostring(o.gen or "g"), 0
    local exchangeDue         -- time a (coalesced or retried) exchange is due
    local lastExchange        -- time of the last exchange
    local lastPoll
    local handled = {}        -- ["id@version"] = true: received (or refused) this session
    local tooLarge = {}       -- [id] = version that couldn't be sent
    local said = {}           -- one-shot report lines

    local function Once(key, text)
        if said[key] then return end
        said[key] = true
        report(text)
    end

    -- A peer on another wire schema (#5) is paused, not refused: nothing it
    -- sends is cached as handled, so once it updates, the same versions are
    -- fetched. Its first message at our schema clears the pause.
    local function Incompatible(p, why)
        if why ~= "older-schema" and why ~= "newer-schema" then return false end
        p.schema = why
        -- It can't read our requests: stop asking until it speaks our schema
        -- (its next manifest queues what we still lack).
        p.queue, p.queued, p.out = {}, {}, {}
        Once("schema:" .. p.guid .. ":" .. why, why == "older-schema"
            and ("Your other account (%s) runs an older AltStableSync: sync is paused until both are updated."):format(p.label)
            or ("Your other account (%s) runs a newer AltStableSync: update this one; sync is paused until then."):format(p.label))
        return true
    end

    local function Peer(guid, label)
        local p = peers[guid]
        if not p then
            p = { guid = guid, label = label or "?", manifest = nil, acc = nil, heard = false,
                  sessions = {}, queue = {}, queued = {}, out = {} }
            peers[guid] = p
        end
        if label then p.label = label end
        return p
    end

    local function Heard()
        for _, p in pairs(peers) do if p.listed and p.heard then return true end end
        return false
    end
    local function AnyListed()
        for _, p in pairs(peers) do if p.listed then return true end end
        return false
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

    -- Returns how many peers took it (0 or nil: retried in RETRY seconds
    -- while a peer is listed - e.g. one still mid-handshake).
    function self.Exchange()
        local t = now()
        exchangeDue, lastExchange = nil, t
        counter = counter + 1
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
                local msg = Frame("MAN", Env.Pack({ s = Env.SCHEMA, b = session, c = counter, p = p, n = parts, l = l }))
                if not msg then fits = false break end
                msgs[p] = msg
            end
            if fits then
                local took
                for _, msg in ipairs(msgs) do
                    local n = T.Send(msg)
                    took = math.min(took or math.huge, tonumber(n) or 0)
                end
                if (took or 0) < 1 and AnyListed() then exchangeDue = t + RETRY end
                return took or 0
            end
        end
        Once("man-too-large", "Couldn't send the list of saved setups: it is too large to sync.")
        return 0
    end

    function self.LocalWrite()
        if not exchangeDue then exchangeDue = now() + COALESCE end
    end

    function self.Refresh()
        return self.Exchange()
    end

    ------------------------------------------------------------
    -- Requests: one id each, at most MAX_OUT outstanding per peer
    ------------------------------------------------------------

    -- Would receiving `id` at `version` change anything? The catalog's own
    -- rule (Catalog.Wants), plus what this session already received.
    local function Lacks(id, version)
        if handled[id .. "@" .. tostring(version)] then return false end
        return C.Wants(id, version)
    end

    -- Queue `id` at `version`. A manifest's listing replaces the queued
    -- version (the newest listing wins); a retry after a timeout never does.
    local function Want(p, id, version, retry)
        if p.queued[id] then
            if not retry then p.queued[id] = version end
            return
        end
        p.queue[#p.queue + 1] = id
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

    -- Manifests are ordered per peer session `b` by counter `c`. Sessions are
    -- ordered by the transport's sid, which grows per sender across reloads:
    -- a session whose message carries a lower sid than the current one's is
    -- an older one arriving late, ignored for good; a higher one replaces the
    -- current session (the peer reloaded), and the replaced one is ignored.
    local function OnManifest(p, m, sid)
        if type(m.b) ~= "string" or type(m.c) ~= "number" or type(m.p) ~= "number"
            or type(m.n) ~= "number" or type(m.l) ~= "table" then return end
        if p.sessions[m.b] then return end                         -- a replaced session
        if p.session ~= m.b then
            if p.session and sid and p.sessionSid and sid < p.sessionSid then
                p.sessions[m.b] = true                             -- an older session, late
                return
            end
            if p.session then p.sessions[p.session] = true end
            p.session, p.counter, p.acc, p.sessionSid = m.b, nil, nil, nil
        end
        if sid and (not p.sessionSid or sid > p.sessionSid) then p.sessionSid = sid end
        if p.counter and m.c < p.counter then return end           -- older than what we hold
        if not p.acc or p.acc.c ~= m.c then
            if p.acc and m.c < p.acc.c then return end             -- a stray part of an older one
            p.acc = { c = m.c, n = m.n, got = {}, l = {} }
        end
        local acc = p.acc
        if acc.got[m.p] then return end
        acc.got[m.p] = true
        for id, v in pairs(m.l) do
            if type(id) == "string" and type(v) == "string" then
                acc.l[id] = v
                if Lacks(id, v) then Want(p, id, v) end
            end
        end
        if Count(acc.got) >= acc.n then p.manifest, p.counter, p.acc = acc.l, acc.c, nil end
        Pump(p)
    end

    local function OnRequest(p, m)
        if type(m.i) ~= "string" then return end
        local e = C.Get(m.i)
        if not e then return end
        local text, why = Env.Encode(e)
        if not text then
            Once("enc:" .. e.id .. "@" .. e.version, ("Couldn't encode %q for sync (%s); it stays on this account.")
                :format(tostring(e.name), tostring(why)))
            return
        end
        local msg = Frame("ENT", e.id .. "\n" .. e.version .. "\n" .. text)
        if not msg then
            tooLarge[e.id] = e.version
            Once("big:" .. e.id .. "@" .. e.version, ("%q is too large to sync; it stays on this account.")
                :format(tostring(e.name)))
            return
        end
        T.SendTo(p.guid, msg)
    end

    local function OnEntry(p, body)
        local rid, rver, text = body:match("^([^\n]+)\n([^\n]+)\n(.*)$")
        if not rid then return end
        local asked = p.out[rid]
        -- Only the answer to THIS request frees it: an answer for another
        -- version (late, after a timeout) leaves the newer request alone.
        if asked and asked.version == rver then p.out[rid] = nil end
        local entry, why = Env.Decode(text)
        if not entry and Incompatible(p, why) then Pump(p) return end
        if entry then p.schema = nil end       -- decoded at our schema: compatible
        if entry and (entry.id ~= rid or entry.version ~= rver) then entry, why = nil, "mismatch" end
        if not entry then
            -- Refused: don't ask for THAT version again this session.
            handled[rid .. "@" .. rver] = true
            Once("bad:" .. tostring(why), "Ignored a saved setup from " .. p.label .. " that this version can't read ("
                .. tostring(why) .. ").")
            Pump(p)
            return
        end
        local result = C.Upsert(entry, p.label)
        if type(entry.id) == "string" and type(entry.version) == "string" then
            handled[entry.id .. "@" .. entry.version] = true
        end
        if result == "conflict" then
            report(("%q was changed on both accounts. The version from %s is kept as a copy: /altsync conflicts")
                :format(tostring(entry.name), p.label))
        elseif not result then
            Once("bad-entry:" .. tostring(entry.id), "Ignored a saved setup from " .. p.label .. " that this version can't read.")
        end
        -- The peer may answer with a newer version than it listed: once what
        -- we asked for is covered, the request is done.
        if p.out[rid] and not Lacks(rid, p.out[rid].version) then p.out[rid] = nil end
        Pump(p)
    end

    function self.Receive(payload, sender, sid)
        if type(payload) ~= "string" or type(sender) ~= "table" or type(sender.guid) ~= "string" then return end
        local kind, body = payload:match("^(%u%u%u)\n(.*)$")
        if not kind then return end
        local p = Peer(sender.guid, Label(sender))
        if not p.listed then           -- talking to us, so online: a sighting
            p.listed = true
            if not exchangeDue then exchangeDue = now() end
        end
        p.heard = true
        if kind == "ENT" then return OnEntry(p, body) end
        local m, why = Env.Unpack(body)
        if not m then Incompatible(p, why) return end
        p.schema = nil
        if kind == "MAN" then return OnManifest(p, m, tonumber(sid)) end
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
            -- Gone (logged out, or another character of that account): drop
            -- its state, queue and requests with it.
            for guid in pairs(peers) do
                if not listed[guid] then peers[guid] = nil end
            end
        end
        if exchangeDue and t >= exchangeDue then
            self.Exchange()
        elseif lastExchange and t - lastExchange >= INTERVAL and AnyListed() then
            self.Exchange()
        end
        for _, p in pairs(peers) do
            -- An expired request goes back in the queue (at its end) while we
            -- still lack it: a lost message is retried without waiting for
            -- the next manifest. MAX_OUT and REQ_TIMEOUT bound the traffic,
            -- even for an id the peer never answers.
            for id, o in pairs(p.out) do
                if t >= o.expires then
                    p.out[id] = nil
                    if Lacks(id, o.version) then Want(p, id, o.version, true) end
                end
            end
            Pump(p)
        end
    end

    ------------------------------------------------------------
    -- Status
    ------------------------------------------------------------

    -- The listed peers: { label, guid, heard = it has spoken (runs the Link
    -- addon), complete = we hold its whole manifest, schema = "older-schema" |
    -- "newer-schema" while it runs an incompatible AltStableSync }.
    function self.Peers()
        local out = {}
        for _, p in pairs(peers) do
            if p.listed then
                out[#out + 1] = { label = p.label, guid = p.guid, heard = p.heard, complete = p.manifest ~= nil,
                                  schema = p.schema }
            end
        end
        table.sort(out, function(a, b) return a.label < b.label end)
        return out
    end

    -- "confirmed" when every peer that has spoken (or just `guid`) lists our
    -- exact version in its whole manifest, "too large", or "pending"; nil
    -- with no such peer.
    function self.EntryStatus(e, guid)
        if tooLarge[e.id] == e.version then return "too large" end
        local any = false
        for _, p in pairs(peers) do
            if p.listed and p.heard and (guid == nil or p.guid == guid) then
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

    self.Heard = Heard
    return self
end
