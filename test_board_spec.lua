local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("LitsBoard", function()
    local Board

    setup(function()
        Board = require("board")
    end)

    local function newBoard(n, diff, seed)
        math.randomseed(seed or 42)
        local b = Board:new{ n = n or 7, difficulty = diff or "easy" }
        b:generate()
        return b
    end

    -- Shades exactly the solution (dots everywhere else when `dots`).
    local function solve(b, dots)
        for r = 1, b.n do
            for c = 1, b.n do
                if b.solution[r][c] == 1 then
                    b:setMark(r, c, Board.MARK_SHADE)
                elseif dots then
                    b:setMark(r, c, Board.MARK_DOT)
                end
            end
        end
    end

    describe("generate", function()
        it("honours the requested size and difficulty", function()
            for _, n in ipairs({ 7, 8 }) do
                local b = newBoard(n, "medium", n)
                assert.are.equal(n, b.n)
                assert.are.equal("medium", b.difficulty)
                assert.are.equal(2, b.level)
                assert.are.equal(n, #b.region)
                assert.are.equal(n, #b.solution)
            end
        end)

        it("passes the generator's progress on to the caller", function()
            math.randomseed(9)
            local b = Board:new{ n = 7, difficulty = "easy" }
            local last
            b:generate(function(f) last = f end)
            assert.are.equal(1, last)
            assert.is_false(b:isSolved())
        end)

        it("starts blank, unsolved, with an empty undo stack", function()
            local b = newBoard()
            assert.are.equal(0, b:countShaded())
            assert.is_false(b:isSolved())
            assert.is_false(b:canUndo())
        end)
    end)

    describe("cycleCell", function()
        it("cycles empty -> shaded -> dot -> empty", function()
            local b = newBoard()
            assert.are.equal(Board.MARK_EMPTY, b.marks[1][1])
            b:cycleCell(1, 1)
            assert.are.equal(Board.MARK_SHADE, b.marks[1][1])
            b:cycleCell(1, 1)
            assert.are.equal(Board.MARK_DOT, b.marks[1][1])
            b:cycleCell(1, 1)
            assert.are.equal(Board.MARK_EMPTY, b.marks[1][1])
        end)

        it("is refused while the solution is shown", function()
            local b = newBoard()
            b:toggleSolution()
            assert.is_false(b:cycleCell(1, 1))
            assert.are.equal(Board.MARK_EMPTY, b.marks[1][1])
            b:toggleSolution()
            assert.is_true(b:cycleCell(1, 1))
        end)
    end)

    describe("win detection", function()
        it("is won once the solution is shaded, dots or not", function()
            local b = newBoard()
            solve(b, false)
            assert.is_true(b:isSolved())
            assert.are.equal(b:totalShaded(), b:countShaded())

            local b2 = newBoard()
            solve(b2, true)
            assert.is_true(b2:isSolved())
        end)

        it("is not won with one shaded cell missing", function()
            local b2 = newBoard()
            local first = true
            for r = 1, b2.n do
                for c = 1, b2.n do
                    if b2.solution[r][c] == 1 then
                        if first then first = false else b2:setMark(r, c, Board.MARK_SHADE) end
                    end
                end
            end
            assert.is_false(b2:isSolved())
        end)

        it("locks the board once won", function()
            local b = newBoard()
            solve(b, false)
            assert.is_false(b:cycleCell(1, 1))
            assert.is_false(b:canUndo())
        end)
    end)

    describe("getConflicts", function()
        -- A board whose regions are given by hand: rows of a 7x7 grid,
        -- regions 1..7 one per row.
        local function rowsBoard()
            local b = newBoard()
            for r = 1, b.n do
                for c = 1, b.n do
                    b.region[r][c] = r
                    b.marks[r][c] = Board.MARK_EMPTY
                end
            end
            b._puzzle = nil
            return b
        end

        it("flags a region with five shaded cells", function()
            local b = rowsBoard()
            for c = 1, 5 do b.marks[1][c] = Board.MARK_SHADE end
            local conf = b:getConflicts()
            for c = 1, 5 do assert.is_true(conf[1][c]) end
        end)

        it("flags a fully shaded 2x2 block", function()
            local b = rowsBoard()
            b.marks[1][1], b.marks[1][2] = Board.MARK_SHADE, Board.MARK_SHADE
            b.marks[2][1], b.marks[2][2] = Board.MARK_SHADE, Board.MARK_SHADE
            local conf = b:getConflicts()
            assert.is_true(conf[1][1] and conf[1][2] and conf[2][1] and conf[2][2])
        end)

        it("flags four cells that are no tetromino", function()
            local b = rowsBoard()
            b.marks[1][1], b.marks[1][2] = Board.MARK_SHADE, Board.MARK_SHADE
            b.marks[1][4], b.marks[1][5] = Board.MARK_SHADE, Board.MARK_SHADE
            assert.is_true(b:getConflicts()[1][1])
        end)

        it("flags two same-shaped pieces side by side, not two different ones", function()
            local b = rowsBoard()
            for c = 1, 4 do b.marks[1][c] = Board.MARK_SHADE end   -- I
            for c = 1, 4 do b.marks[2][c] = Board.MARK_SHADE end   -- I, touching
            -- (also 2x2 blocks; use a clean pair below for the shape rule)
            assert.is_true(b:getConflicts()[1][1])

            b = rowsBoard()
            for c = 1, 4 do b.marks[1][c] = Board.MARK_SHADE end   -- I in row 1
            for c = 4, 7 do b.marks[2][c] = Board.MARK_SHADE end   -- I in row 2
            local conf = b:getConflicts()
            assert.is_true(conf[1][4])
            assert.is_true(conf[2][4])
            assert.is_false(conf[1][1])   -- not touching the other I

            b = rowsBoard()
            for c = 1, 4 do b.marks[1][c] = Board.MARK_SHADE end   -- I in row 1
            for c = 4, 6 do b.marks[2][c] = Board.MARK_SHADE end   -- with (3,6): an L,
            b.marks[3][6] = Board.MARK_SHADE                       -- touching at (1,4)
            b.region[3][6] = 2
            b._puzzle = nil
            assert.is_false(b:getConflicts()[1][4])
        end)

        it("flags a shaded cell walled in by dots", function()
            local b = rowsBoard()
            b.marks[1][1] = Board.MARK_SHADE
            assert.is_false(b:getConflicts()[1][1])
            b.marks[1][2] = Board.MARK_DOT
            b.marks[2][1] = Board.MARK_DOT
            assert.is_true(b:getConflicts()[1][1])
        end)

        it("flags nothing on the solution", function()
            local b = newBoard()
            solve(b, true)
            local conf = b:getConflicts()
            for r = 1, b.n do
                for c = 1, b.n do assert.is_false(conf[r][c]) end
            end
        end)
    end)

    describe("undo", function()
        it("restores the previous mark", function()
            local b = newBoard()
            b:cycleCell(2, 3)
            assert.is_true(b:canUndo())
            assert.is_true(b:undoMove())
            assert.are.equal(Board.MARK_EMPTY, b.marks[2][3])
            assert.is_false(b:undoMove())
        end)

        it("restores everything wiped by clearAll in one step", function()
            local b = newBoard()
            b:cycleCell(1, 1)
            b:cycleCell(2, 2); b:cycleCell(2, 2)
            assert.is_true(b:clearAll())
            assert.are.equal(0, b:countShaded())
            assert.is_true(b:undoMove())
            assert.are.equal(Board.MARK_SHADE, b.marks[1][1])
            assert.are.equal(Board.MARK_DOT, b.marks[2][2])
        end)
    end)

    describe("serialize / load", function()
        it("round-trips the puzzle, the marks and the progress", function()
            local b = newBoard(8, "hard", 7)
            b:cycleCell(1, 1)
            b:cycleCell(3, 4); b:cycleCell(3, 4)
            b:noteHintUsed()
            local data = b:serialize()
            assert.is_true(b.timer:isRunning())   -- saving must not stop the clock

            local b2 = Board:new()
            assert.is_true(b2:load(data))
            assert.are.equal(8, b2.n)
            assert.are.equal("hard", b2.difficulty)
            assert.are.equal(b.level, b2.level)
            assert.are.same(b.region, b2.region)
            assert.are.same(b.solution, b2.solution)
            assert.are.same(b.marks, b2.marks)
            assert.are.equal(1, b2:getHintsUsed())
            assert.is_true(b2:undoMove())
            assert.are.equal(Board.MARK_SHADE, b2.marks[3][4])
        end)

        it("keeps a won game won", function()
            local b = newBoard()
            solve(b, false)
            local b2 = Board:new()
            assert.is_true(b2:load(b:serialize()))
            assert.is_true(b2:isSolved())
            assert.is_false(b2.timer:isRunning())
        end)

        it("rejects invalid data", function()
            local b = Board:new()
            assert.is_false(b:load(nil))
            assert.is_false(b:load({}))
            assert.is_false(b:load({ n = 7, region = {}, solution = {}, marks = {} }))
        end)
    end)

    describe("hint", function()
        it("points at a shaded cell of the solution on a blank board", function()
            local b = newBoard()
            local step = b:findHint()
            assert.are.equal("fill", step.kind)
            assert.are.equal(1, b.solution[step.r][step.c])
        end)

        it("reports a mistake before filling anything, and clears it", function()
            local b = newBoard()
            -- A dot where the solution shades: a mistake, not a note.
            local mr, mc
            for r = b.n, 1, -1 do
                for c = b.n, 1, -1 do
                    if not mr and b.solution[r][c] == 1 then mr, mc = r, c end
                end
            end
            b:setMark(mr, mc, Board.MARK_DOT)
            local step = b:findHint()
            assert.are.equal("mistake", step.kind)
            assert.are.equal(mr, step.r)
            assert.are.equal(mc, step.c)
            assert.is_true(b:applyHint(step))
            assert.are.equal(Board.MARK_EMPTY, b.marks[mr][mc])
        end)

        it("treats correct dots as notes, not mistakes", function()
            local b = newBoard()
            for r = 1, b.n do
                for c = 1, b.n do
                    if b.solution[r][c] == 0 then b:setMark(r, c, Board.MARK_DOT) end
                end
            end
            assert.are.equal("fill", b:findHint().kind)
        end)

        it("solves the whole grid hint by hint", function()
            local b = newBoard(8, "medium", 3)
            b:cycleCell(1, 1)   -- maybe wrong: the hints must cope
            for _ = 1, 200 do
                if b:isSolved() then break end
                local step = b:findHint()
                assert.is_truthy(step)
                assert.is_true(b:applyHint(step))
            end
            assert.is_true(b:isSolved())
        end)
    end)
end)
