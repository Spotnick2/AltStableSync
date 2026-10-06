------------------------------------------------------------
-- harness.lua - the shared check/eq/finish helpers for tests/test_*.lua
--
--   dofile("tests/harness.lua")
--   check("name", ok, detail); eq("name", got, want); finish("test_area")
------------------------------------------------------------

local passed, failed = 0, 0

function check(name, ok, detail)
    if ok then passed = passed + 1
    else failed = failed + 1; print("  FAIL: " .. name .. (detail and ("  -- " .. detail) or "")) end
end

function eq(name, got, want)
    check(name, got == want, "got " .. tostring(got) .. ", want " .. tostring(want))
end

function finish(label)
    print(("%s: %d passed, %d failed"):format(label, passed, failed))
    os.exit(failed == 0 and 0 or 1)
end
