local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path

describe("LITS solver", function()
    local Solver

    setup(function()
        Solver = require("solver")
    end)

    -- Random connected regions of a small grid: grow from k random seeds.
    local function randomRegions(n, k)
        local N, region, frontier = n * n, {}, {}
        local nb = Solver.geometry(n).nb
        local ids = 0
        while ids < k do
            local i = math.random(N)
            if not region[i] then
                ids = ids + 1
                region[i] = ids
                frontier[#frontier + 1] = i
            end
        end
        while #frontier > 0 do
            local f = math.random(#frontier)
            local i = frontier[f]
            local open = {}
            for _, j in ipairs(nb[i]) do if not region[j] then open[#open + 1] = j end end
            if #open == 0 then
                table.remove(frontier, f)
            else
                local j = open[math.random(#open)]
                region[j] = region[i]
                frontier[#frontier + 1] = j
            end
        end
        return region
    end

    -- Every combination of one placement per region, checked by the plain
    -- rule checker: the reference the counter and the logical solver are
    -- held to.
    local function bruteSolutions(P)
        local sols, shaded = {}, {}
        for i = 1, P.N do shaded[i] = false end
        local function rec(id)
            if id > P.nregions then
                if Solver.isValid(P, shaded) then
                    local t = {}
                    for i = 1, P.N do t[i] = shaded[i] end
                    sols[#sols + 1] = t
                end
                return
            end
            for _, c in ipairs(P.cands[id]) do
                for k = 1, 4 do shaded[c.cells[k]] = true end
                rec(id + 1)
                for k = 1, 4 do shaded[c.cells[k]] = false end
            end
        end
        rec(1)
        return sols
    end

    describe("shapes", function()
        it("names the four tetromino shapes in any orientation, and rejects O", function()
            -- 5x5 grid, flat indices.
            local function idx(r, c) return (r - 1) * 5 + c end
            assert.are.equal(2, Solver.shapeOf(5, { idx(1,1), idx(2,1), idx(3,1), idx(4,1) }))   -- I
            assert.are.equal(2, Solver.shapeOf(5, { idx(2,1), idx(2,2), idx(2,3), idx(2,4) }))   -- I
            assert.are.equal(1, Solver.shapeOf(5, { idx(1,1), idx(2,1), idx(3,1), idx(3,2) }))   -- L
            assert.are.equal(1, Solver.shapeOf(5, { idx(1,2), idx(2,2), idx(3,2), idx(3,1) }))   -- J = L
            assert.are.equal(3, Solver.shapeOf(5, { idx(1,1), idx(1,2), idx(1,3), idx(2,2) }))   -- T
            assert.are.equal(4, Solver.shapeOf(5, { idx(1,2), idx(1,3), idx(2,1), idx(2,2) }))   -- S
            assert.are.equal(4, Solver.shapeOf(5, { idx(1,1), idx(1,2), idx(2,2), idx(2,3) }))   -- Z = S
            assert.is_nil(Solver.shapeOf(5, { idx(1,1), idx(1,2), idx(2,1), idx(2,2) }))         -- O
            assert.is_nil(Solver.shapeOf(5, { idx(1,1), idx(1,2), idx(1,4), idx(1,5) }))         -- split
        end)
    end)

    -- Half planted layouts (always solvable, often ambiguous), half random
    -- regions (mostly unsolvable): both kinds of answer get exercised.
    local function sampleRegions(k)
        if k % 2 == 0 then
            local region = Solver.plantedLayout(5, 13)
            if region then return region end
        end
        return randomRegions(5, 4)
    end

    describe("rule checker and counter", function()
        it("agree with brute force on small grids", function()
            math.randomseed(21)
            local nonzero = 0
            for k = 1, 30 do
                local P = Solver.newPuzzle(5, sampleRegions(k))
                local brute = bruteSolutions(P)
                local count = Solver.countSolutions(P, 100000, 1e7)
                assert.are.equal(#brute, count)
                if #brute > 0 then nonzero = nonzero + 1 end
            end
            assert.is_true(nonzero > 5)
        end)
    end)

    describe("logical solver", function()
        it("never deduces a value some solution contradicts", function()
            math.randomseed(22)
            for k = 1, 30 do
                local P = Solver.newPuzzle(5, sampleRegions(k))
                local brute = bruteSolutions(P)
                local status, _, st = Solver.logicSolve(P, 3)
                if #brute == 0 then
                    assert.are_not.equal("solved", status)
                else
                    assert.are_not.equal("contra", status)
                    for i = 1, P.N do
                        if st[i] ~= Solver.UNKNOWN then
                            for _, s in ipairs(brute) do
                                assert.are.equal(st[i] == Solver.SHADED, s[i])
                            end
                        end
                    end
                end
            end
        end)
    end)
end)
