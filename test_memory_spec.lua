local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.preload["gettext"] = package.preload["gettext"] or function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("LITS solver cache", function()
    it("builds geometry only when needed and release() drops it", function()
        local Solver = dofile(DIR .. "solver.lua")
        assert.are.same({}, Solver.cachedSizes())
        Solver.geometry(7)
        assert.are.same({ 7 }, Solver.cachedSizes())
        Solver.release()
        assert.are.same({}, Solver.cachedSizes())
    end)

    it("generates the same puzzle after a release", function()
        local Board = dofile(DIR .. "board.lua")
        local function gen()
            math.randomseed(42)
            local b = Board:new{ n = 7, difficulty = "medium" }
            b:generate()
            return { b.region, b.solution }
        end
        local first = gen()
        assert.is_true(#Board.Solver.cachedSizes() > 0)
        Board.release()
        assert.are.same({}, Board.Solver.cachedSizes())
        assert.are.same(first, gen())
    end)
end)
