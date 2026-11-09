-- Difficulty guarantees for LITS (see docs/dev/TESTING.md, "Difficulty
-- specs"): every size x level gives a unique puzzle that the game's own
-- solver finishes without trial (region enumeration only), graded at the
-- requested level; Easy takes one small case analysis at most, the levels
-- are ordered on average work, a seed gives the same puzzle, and the
-- generator never reads the clock. Most of it moved here from
-- test_solver_spec.lua ("generate").
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path

-- Runs fn with os.clock/os.time/os.date counted; returns how many times
-- they were read. The play timer (game-common timer.lua, started when a new
-- round begins) is not part of the generator and is left out.
local function clockReads(fn)
    local oc, ot, od = os.clock, os.time, os.date
    local reads = 0
    local function count()
        local src = debug.getinfo(3, "S").source
        if not src:find("timer%.lua$") then reads = reads + 1 end
    end
    os.clock = function(...) count(); return oc(...) end
    os.time  = function(...) count(); return ot(...) end
    os.date  = function(...) count(); return od(...) end
    local ok, err = pcall(fn)
    os.clock, os.time, os.date = oc, ot, od
    if not ok then error(err, 0) end
    return reads
end

describe("LITS difficulty", function()
    local Solver

    setup(function()
        Solver = require("solver")
    end)

    -- moved from test_solver_spec.lua
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

    it("levels are ordered on average work at 7x7 too", function()
        local sum = { 0, 0, 0 }
        for seed = 1, 5 do
            for lvl, diff in ipairs({ "easy", "medium", "hard" }) do
                math.randomseed(seed * 7919 + 7)
                local p = Solver.generate(7, diff)
                local _, _, _, steps = Solver.logicSolve(Solver.newPuzzle(7, p.region), 3)
                sum[lvl] = sum[lvl] + Solver.score(steps)
            end
        end
        assert.is_true(sum[1] < sum[2] and sum[2] < sum[3],
            ("7x7 work %d/%d/%d"):format(sum[1], sum[2], sum[3]))
    end)

    it("generation never reads the clock", function()
        for _, n in ipairs({ 7, 8 }) do
            for _, diff in ipairs({ "easy", "medium", "hard" }) do
                local reads = clockReads(function()
                    math.randomseed(31 + n)
                    assert.is_truthy(Solver.generate(n, diff))
                end)
                assert.are.equal(0, reads, ("%dx%d %s read the clock"):format(n, n, diff))
            end
        end
    end)
end)
