------------------------------------------------------------
-- libaccountsync.lua - load LibAccountSync the way the client does
--
-- The main addon's TOC loads Libs\LibAccountSync-1.0\LibAccountSync-1.0.xml (#66).
-- That folder is gitignored (the packager fills it), so the tests read the
-- library from a checkout: $LIBACCOUNTSYNC, else ../LibAccountSync (CI fetches
-- the .pkgmeta pin with tests/fetch_libaccountsync.sh). No checkout, or a
-- file its XML lists missing, fails the run LOUDLY: a silently skipped
-- library would test nothing. (AltStable's tests/libaccountsync.lua.)
------------------------------------------------------------

function LibAccountSyncRoot()
    local root = (os.getenv("LIBACCOUNTSYNC") or "../LibAccountSync"):gsub("\\", "/"):gsub("/$", "")
    local f = io.open(root .. "/LibAccountSync-1.0.xml", "rb")
    if not f then
        error("LibAccountSync checkout not found at " .. root .. " (no LibAccountSync-1.0.xml): clone "
              .. "github.com/Spotnick2/LibAccountSync there or set LIBACCOUNTSYNC", 0)
    end
    f:close()
    return root
end

function LoadAccountSync(addon)
    local root = LibAccountSyncRoot()
    local f = assert(io.open(root .. "/LibAccountSync-1.0.xml", "rb"))
    local xml = f:read("*a"):gsub("<!%-%-.-%-%->", "")   -- listed in a comment is not loaded
    f:close()
    local n = 0
    for file in xml:gmatch('<Script%s+file="([^"]+)"') do
        local path = root .. "/" .. file:gsub("\\", "/")
        local chunk, err = loadfile(path)
        if not chunk then error("LibAccountSync checkout at " .. root .. ": " .. tostring(err), 0) end
        chunk(addon, {})
        n = n + 1
    end
    if n == 0 then error("LibAccountSync-1.0.xml at " .. root .. " lists no Script files", 0) end
    return LibStub("LibAccountSync-1.0")
end
