------------------------------------------------------------
-- harness.lua - the shared check/eq/finish helpers for tests/test_*.lua
--
--   dofile("tests/wow_stubs.lua")   -- the kit, the mock, the game model
--   dofile("tests/harness.lua")
--   check("name", ok, detail); eq("name", got, want); finish("test_area")
--
-- The assertions are WowTestKit's (counts, the exit code, and in done() the
-- stray "|" and swallowed-secret checks). This repo's tests call them NAME
-- FIRST, 2,800 times (check(name, ok, detail), eq(name, got, want)); the
-- kit's are CONDITION FIRST (check(ok, msg), eq(got, want, msg)). These
-- globals are the name-first form over the kit's, printing the same
-- "  FAIL: name  -- detail" line as before. The kit's own functions (done,
-- Kit.checkToc, Kit.checkMethods) call the global check/eq cond-first, so
-- they run through kit(), which puts the kit's back for the call.
------------------------------------------------------------

if not rawget(_G, "Kit") then dofile("tests/kit.lua") end   -- a test that never loads the stubs

if not rawget(_G, "kit") then
    local kitCheck, kitEq = check, eq

    function check(name, ok, detail)
        kitCheck(ok, name .. (detail and ("  -- " .. detail) or ""))
    end

    function eq(name, got, want)
        kitCheck(got == want, name .. "  -- got " .. tostring(got) .. ", want " .. tostring(want))
    end

    -- kit(fn, ...): run one of the kit's functions with its own check/eq.
    function kit(fn, ...)
        local mine, myEq = check, eq
        check, eq = kitCheck, kitEq
        local r = { pcall(fn, ...) }
        check, eq = mine, myEq
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2)
    end
end

function finish(label)
    kit(done, label)
end

-- finish(), then `marker` as the very last line when nothing failed (a
-- child session's pass signal, tests/flavour_session.lua).
function finishWith(label, marker)
    local realExit = os.exit
    os.exit = function(code)
        os.exit = realExit
        if code == 0 then io.write(marker .. "\n") end
        realExit(code)
    end
    kit(done, label)
end
