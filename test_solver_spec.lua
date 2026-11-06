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

    describe("generate", function()
        local function check(n, diff, seed)
            math.randomseed(seed)
            local p = Solver.generate(n, diff)
            assert.is_truthy(p, ("no puzzle for %dx%d %s seed %d"):format(n, n, diff, seed))
            local P = Solver.newPuzzle(n, p.region)
            -- The planted solution follows the rules...
            assert.is_true(Solver.isValid(P, p.solution))
            -- ...and is the only one, by exhaustive search...
            local count, exhausted = Solver.countSolutions(P, 2, 1e6)
            assert.is_false(exhausted)
            assert.are.equal(1, count)
            -- ...and logic alone (no trial and error) finds it.
            local status, _, st, steps = Solver.logicSolve(P, 3)
            assert.are.equal("solved", status)
            assert.are.equal(p.level, Solver.levelOf(status, steps))
            for i = 1, P.N do
                assert.are.equal(p.solution[i] == 1, st[i] == Solver.SHADED)
            end
            -- Regions are connected and each holds exactly one piece.
            local nb = Solver.geometry(n).nb
            for id = 1, P.nregions do
                local cells, shaded = P.cells[id], 0
                local seen, stack, reached = { [cells[1]] = true }, { cells[1] }, 1
                while #stack > 0 do
                    local i = table.remove(stack)
                    for _, j in ipairs(nb[i]) do
                        if not seen[j] and p.region[j] == id then
                            seen[j] = true
                            reached = reached + 1
                            stack[#stack + 1] = j
                        end
                    end
                end
                assert.are.equal(#cells, reached)
                for _, i in ipairs(cells) do shaded = shaded + p.solution[i] end
                assert.are.equal(4, shaded)
            end
            return p
        end

        it("makes unique, logic-solvable 7x7 puzzles at every level", function()
            for seed = 1, 6 do
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    assert.are.equal(Solver.LEVEL[diff], check(7, diff, seed).level)
                end
            end
        end)

        it("makes unique 8x8 and 10x10 puzzles at every level", function()
            for seed = 1, 3 do
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    assert.are.equal(Solver.LEVEL[diff], check(8, diff, seed).level)
                end
            end
            for _, diff in ipairs({ "easy", "medium", "hard" }) do
                assert.are.equal(Solver.LEVEL[diff], check(10, diff, 1).level)
            end
        end)

        it("easy puzzles take one small case analysis at most", function()
            for seed = 1, 3 do
                math.randomseed(seed)
                local p = Solver.generate(8, "easy")
                local status, _, _, steps = Solver.logicSolve(Solver.newPuzzle(8, p.region), 2)
                assert.are.equal("solved", status)
                assert.is_true(Solver.score(steps) <= 1)
            end
        end)

        it("hard puzzles take real work", function()
            math.randomseed(4)
            local p = Solver.generate(8, "hard")
            local _, _, _, steps = Solver.logicSolve(Solver.newPuzzle(8, p.region), 3)
            assert.is_true(Solver.score(steps) >= 5)
        end)

        -- A unique 7x7 that the 1.0.x generator handed out as Medium: it
        -- only falls to "if this cell were shaded, the rules would break",
        -- which the owner counts as guessing. The solver must stop on it.
        it("never uses trial and error", function()
            local R = {
                { 7, 7, 7, 1, 5, 5, 5 },
                { 4, 7, 7, 1, 1, 5, 6 },
                { 4, 4, 3, 1, 1, 6, 6 },
                { 4, 3, 3, 1, 2, 2, 6 },
                { 4, 3, 2, 2, 2, 6, 6 },
                { 4, 3, 2, 2, 2, 8, 6 },
                { 4, 4, 4, 2, 8, 8, 8 },
            }
            local flat = {}
            for r = 1, 7 do for c = 1, 7 do flat[#flat + 1] = R[r][c] end end
            local P = Solver.newPuzzle(7, flat)
            local count = Solver.countSolutions(P, 2, 1e6)
            assert.are.equal(1, count)
            local status = Solver.logicSolve(P, 3)
            assert.are.equal("stuck", status)
        end)

        -- The seeds whose puzzle needed a trial before 1.1.0 (seeded the way
        -- the measurements were), and a sweep: every puzzle falls to logic.
        it("hands out no puzzle that needs trial and error", function()
            local cases = { { 7, "medium", 27 }, { 7, "hard", 20 }, { 8, "hard", 11 }, { 10, "hard", 6 } }
            for seed = 1, 4 do
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    cases[#cases + 1] = { 7, diff, 100 + seed }
                end
            end
            for _, c in ipairs(cases) do
                local n, diff, seed = c[1], c[2], c[3]
                math.randomseed(seed * 7919 + n)
                local p = Solver.generate(n, diff)
                local P = Solver.newPuzzle(n, p.region)
                local status, used, _, steps = Solver.logicSolve(P, 3)
                assert.are.equal("solved", status, ("%dx%d %s seed %d"):format(n, n, diff, seed))
                assert.is_true(used <= 3)
                assert.is_nil(steps[4])
                assert.are.equal(Solver.LEVEL[diff], p.level)
                local count, exhausted = Solver.countSolutions(P, 2, 1e6)
                assert.is_false(exhausted)
                assert.are.equal(1, count)
            end
        end)

        it("levels really differ in the work they take", function()
            local sum = { 0, 0, 0 }
            for seed = 1, 4 do
                for lvl, diff in ipairs({ "easy", "medium", "hard" }) do
                    math.randomseed(seed * 7919 + 8)
                    local p = Solver.generate(8, diff)
                    local _, _, _, steps = Solver.logicSolve(Solver.newPuzzle(8, p.region), 3)
                    sum[lvl] = sum[lvl] + Solver.score(steps)
                end
            end
            assert.is_true(sum[1] < sum[2] and sum[2] < sum[3])
        end)

        -- Generous: the worst seen on a Mac is ~0.4 s at 10x10 (the screen
        -- shows a progress bar while it works).
        it("generates a 10x10 hard puzzle in reasonable time", function()
            for seed = 1, 3 do
                math.randomseed(seed * 7919 + 10)
                local t = os.clock()
                assert.is_truthy(Solver.generate(10, "hard"))
                assert.is_true(os.clock() - t < 3)
            end
        end)

        -- The Daily Challenge builds today's grid from a fixed seed on every
        -- device: the generator must depend on math.random alone (no clock,
        -- no time budget), and reporting progress must not change a thing.
        it("builds the same puzzle from the same seed, progress reported or not", function()
            for _, diff in ipairs({ "easy", "hard" }) do
                math.randomseed(77)
                local plain = Solver.generate(8, diff)
                math.randomseed(77)
                local again = Solver.generate(8, diff)
                local calls, last, monotone = 0, -1, true
                math.randomseed(77)
                local reported = Solver.generate(8, diff, { progress = function(f)
                    calls = calls + 1
                    if f < last or f < 0 or f > 1 then monotone = false end
                    last = f
                end })
                for _, p in ipairs({ again, reported }) do
                    assert.are.same(plain.region, p.region)
                    assert.are.same(plain.solution, p.solution)
                    assert.are.equal(plain.level, p.level)
                end
                -- Called as the work goes on, never backwards, ending at 1.
                assert.is_true(calls >= 2)
                assert.is_true(monotone)
                assert.are.equal(1, last)
            end
        end)

        it("builds different puzzles from different seeds", function()
            math.randomseed(1)
            local a = Solver.generate(8, "medium")
            math.randomseed(2)
            local b = Solver.generate(8, "medium")
            assert.are_not.same(a.region, b.region)
        end)
    end)
end)
