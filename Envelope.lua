------------------------------------------------------------
-- Envelope.lua - the catalog's wire format (#17, M1 part)
--
--   "ASE1:<adler32 of the CBOR, 8 hex>:<Base64(Deflate(CBOR({ s = 1, ... })))>"
--
-- C_EncodingUtil (declared on 70245, round trip measured: a worst-case
-- loadout is 2.7 KB, docs/forever-api-notes.md). Base64 is kept although
-- LibAccountSync is binary-safe: the same string is the paste format of #17's
-- later part. Every step is pcall'd; a malformed or newer string is refused
-- whole and nothing is touched. Pure: no game state, no SavedVariables.
------------------------------------------------------------

AltStableSync = AltStableSync or {}
local ASS = AltStableSync

local Envelope = {}
ASS.Envelope = Envelope

local PREFIX = "ASE1:"
-- 2 (#5): loadouts carry `cover`, and a 1-12 build must never receive or
-- edit a wider entry, so every message kind moved to 2 together. 4 (#47):
-- loadouts may carry a pet bar per pet family; a schema-6 build never
-- receives one.
local SCHEMA = 4
Envelope.SCHEMA = SCHEMA

-- Adler-32 in plain Lua 5.1 arithmetic (no bit library needed).
local function Adler32(s)
    local a, b = 1, 0
    for i = 1, #s do
        a = (a + s:byte(i)) % 65521
        b = (b + a) % 65521
    end
    -- Two 16-bit halves: "%08x" of b*65536+a would pass a value >= 2^31
    -- through C's long, which differs between 32- and 64-bit clients.
    return ("%04x%04x"):format(b, a)
end
Envelope.Adler32 = Adler32

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, out = pcall(fn, ...)
    if ok then return out end
    return nil
end

-- Any table with `s = SCHEMA` -> the string, or nil plus "encode-failed".
function Envelope.Pack(value)
    local E = C_EncodingUtil
    if type(E) ~= "table" then return nil, "encode-failed" end
    local cbor = Call(E.SerializeCBOR, value)
    if type(cbor) ~= "string" then return nil, "encode-failed" end
    local z = Call(E.CompressString, cbor)
    if type(z) ~= "string" then return nil, "encode-failed" end
    local b64 = Call(E.EncodeBase64, z)
    if type(b64) ~= "string" then return nil, "encode-failed" end
    return PREFIX .. Adler32(cbor) .. ":" .. b64
end

-- Share strings (#71): the limits on a pasted string. RAW_MAX is the paste
-- as typed, whitespace included; SHARE_MAX the string once whitespace is
-- stripped; BOX_MAX the paste box's own limit, above RAW_MAX, so text the
-- box cut off is always over RAW_MAX and never decoded; CBOR_MAX the
-- decompressed data, refused before it is checksummed or deserialized
-- (DecompressString itself has no output limit).
Envelope.RAW_MAX, Envelope.SHARE_MAX, Envelope.BOX_MAX, Envelope.CBOR_MAX = 20000, 16384, 24000, 65536

-- The string -> the table, or nil plus "bad-envelope" / "bad-checksum" /
-- "older-schema" / "newer-schema" (anything but SCHEMA: refused, never
-- guessed at; "newer" also covers a schema that isn't a number) /
-- "too-long" (decompressed data over `maxCbor`, when given).
function Envelope.Unpack(text, maxCbor)
    if type(text) ~= "string" then return nil, "bad-envelope" end
    local sum, b64 = text:match("^ASE1:(%x%x%x%x%x%x%x%x):(.+)$")
    if not sum then return nil, "bad-envelope" end
    local E = C_EncodingUtil
    if type(E) ~= "table" then return nil, "bad-envelope" end
    local z = Call(E.DecodeBase64, b64)
    if type(z) ~= "string" then return nil, "bad-envelope" end
    local cbor = Call(E.DecompressString, z)
    if type(cbor) ~= "string" then return nil, "bad-envelope" end
    if maxCbor and #cbor > maxCbor then return nil, "too-long" end
    if Adler32(cbor) ~= sum:lower() then return nil, "bad-checksum" end
    local value = Call(E.DeserializeCBOR, cbor)
    if type(value) ~= "table" then return nil, "bad-envelope" end
    if type(value.s) == "number" and value.s < SCHEMA then return nil, "older-schema" end
    if value.s ~= SCHEMA then return nil, "newer-schema" end
    return value
end

-- One catalog entry, never its `previous` (local Save recovery stays on the
-- account that saved).
function Envelope.Encode(entry)
    if type(entry) ~= "table" then return nil, "encode-failed" end
    local e = ASS.Catalog.Copy(entry)
    e.previous = nil
    return Envelope.Pack({ s = SCHEMA, e = e })
end

-- The entry, or nil plus why. Catalog.Upsert validates its fields. A share
-- string is never a sync message (#71).
function Envelope.Decode(text)
    local value, err = Envelope.Unpack(text)
    if not value then return nil, err end
    if type(value.e) ~= "table" or value.share ~= nil then return nil, "bad-envelope" end
    value.e.previous = nil
    return value.e
end

-- A share string (#71): { kind, class, category, name, modules } only, never
-- an entry's identity, versions, `previous` or provenance. Share.lua builds
-- and validates the table; this is only the container.
function Envelope.EncodeShare(share)
    if type(share) ~= "table" then return nil, "encode-failed" end
    return Envelope.Pack({ s = SCHEMA, share = share })
end

-- The pasted text -> the share table, or nil plus "too-long" / "not-a-share"
-- or an Unpack refusal. Whitespace is stripped first (a paste from chat or a
-- forum may wrap); both length limits are checked, the raw one before the
-- strip. A sync message is not a share string.
function Envelope.DecodeShare(text)
    if type(text) ~= "string" then return nil, "bad-envelope" end
    if #text > Envelope.RAW_MAX then return nil, "too-long" end
    text = text:gsub("%s+", "")
    if #text > Envelope.SHARE_MAX then return nil, "too-long" end
    local value, err = Envelope.Unpack(text, Envelope.CBOR_MAX)
    if not value then return nil, err end
    if value.e ~= nil or type(value.share) ~= "table" then return nil, "not-a-share" end
    return value.share
end
