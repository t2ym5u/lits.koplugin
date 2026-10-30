local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local grid_utils = require("grid_utils")
local UndoStack  = require("undo_stack")
local Timer      = require("timer")
local Hint       = require("hint")

-- Loaded by path, not require("solver"): norinori ships a solver.lua too,
-- and package.loaded is shared by every plugin.
local Solver = lrequire("solver")

local emptyGrid = grid_utils.emptyGrid

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

-- No 6x6: a grid that small always falls to the basic rules, so it could
-- never be anything but easy.
local SIZES        = { 7, 8, 10 }
local DEFAULT_N    = 7
local DIFFICULTIES = { "easy", "medium", "hard" }

-- Cell mark values
local MARK_EMPTY = 0
local MARK_SHADE = 1
local MARK_DOT   = 2

-- ---------------------------------------------------------------------------
-- LitsBoard
-- ---------------------------------------------------------------------------

local LitsBoard = {}
LitsBoard.__index = LitsBoard

-- A fresh board holds no puzzle yet: call generate() or load().
function LitsBoard:new(opts)
    opts = opts or {}
    return setmetatable({
        n             = opts.n or DEFAULT_N,
        difficulty    = opts.difficulty or "easy",
        region        = nil,   -- [r][c] region id
        solution      = nil,   -- [r][c] 1 = shaded
        marks         = nil,   -- [r][c] MARK_*
        won           = false,
        show_solution = false,
        selected      = nil,   -- { r, c } the hint is pointing at
        hints_used    = 0,
        undo          = UndoStack:new{ max_size = 500 },
        timer         = Timer:new(),
    }, self)
end

local function toGrid(n, flat)
    local g = emptyGrid(n, n, 0)
    for r = 1, n do
        for c = 1, n do g[r][c] = flat[(r - 1) * n + c] end
    end
    return g
end

local function toFlat(n, grid)
    local flat = {}
    for r = 1, n do
        for c = 1, n do flat[#flat + 1] = grid[r][c] end
    end
    return flat
end

-- `progress`: optional function(fraction), called as the generator works
-- (see Solver.generate); the screen drives a progress bar with it.
function LitsBoard:generate(progress)
    local p
    -- Solver.generate only gives up after dozens of failed restarts: never
    -- seen in testing, but loop rather than hand out nothing.
    repeat
        p = Solver.generate(self.n, self.difficulty, { progress = progress })
    until p
    self.region     = toGrid(self.n, p.region)
    self.solution   = toGrid(self.n, p.solution)
    self.level      = p.level
    self.marks      = emptyGrid(self.n, self.n, MARK_EMPTY)
    self.won        = false
    self.show_solution = false
    self.selected   = nil
    self.hints_used = 0
    self.undo:clear()
    self.timer:reset()
    self.timer:start()
    self._puzzle    = nil
end

-- The solver's view of the grid (flat region array), built on demand.
function LitsBoard:_getPuzzle()
    if not self._puzzle then
        self._puzzle = Solver.newPuzzle(self.n, toFlat(self.n, self.region))
    end
    return self._puzzle
end

-- ---------------------------------------------------------------------------
-- Moves
-- ---------------------------------------------------------------------------

function LitsBoard:canEdit()
    return not self.won and not self.show_solution
end

function LitsBoard:setMark(r, c, mark)
    if not self:canEdit() then return false end
    local cur = self.marks[r][c]
    if cur == mark then return true end
    self.undo:push{ r = r, c = c, old = cur }
    self.marks[r][c] = mark
    self.selected = nil
    self:_checkWin()
    return true
end

-- Tap: empty -> shaded -> dot -> empty.
function LitsBoard:cycleCell(r, c)
    local cur = self.marks[r][c]
    local nxt
    if     cur == MARK_EMPTY then nxt = MARK_SHADE
    elseif cur == MARK_SHADE then nxt = MARK_DOT
    else                          nxt = MARK_EMPTY
    end
    return self:setMark(r, c, nxt)
end

-- Wipes every mark, as one undoable step.
function LitsBoard:clearAll()
    if not self:canEdit() then return false end
    local old, any = {}, false
    for r = 1, self.n do
        old[r] = {}
        for c = 1, self.n do
            old[r][c] = self.marks[r][c]
            if old[r][c] ~= MARK_EMPTY then any = true end
        end
    end
    if not any then return false end
    self.undo:push{ all = old }
    self.marks = emptyGrid(self.n, self.n, MARK_EMPTY)
    self.selected = nil
    return true
end

function LitsBoard:canUndo()
    return self:canEdit() and self.undo:canUndo()
end

function LitsBoard:undoMove()
    if not self:canEdit() then return false end
    local entry = self.undo:pop()
    if not entry then return false end
    if entry.all then
        self.marks = entry.all
    else
        self.marks[entry.r][entry.c] = entry.old
    end
    self.selected = nil
    return true
end

function LitsBoard:setSelection(r, c)
    self.selected = { r, c }
end

-- ---------------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------------

-- Won when the shaded cells satisfy every rule. The generator proved the
-- solution unique, so that is the same as matching it; dots are notes.
function LitsBoard:_checkWin()
    local flat = {}
    for r = 1, self.n do
        for c = 1, self.n do flat[#flat + 1] = self.marks[r][c] == MARK_SHADE end
    end
    self.won = Solver.isValid(self:_getPuzzle(), flat)
    if self.won then
        self.selected = nil
        self.timer:stop()
    end
end

function LitsBoard:isSolved()
    return self.won
end

-- Shaded cells that already break a rule: a region holding more than four,
-- a region's four that are not a tetromino (split, or the square), a fully
-- shaded 2x2 block, two finished pieces of the same shape side by side, or a
-- shaded cell walled in by dots and the edge.
function LitsBoard:getConflicts()
    local n = self.n
    local conflict = emptyGrid(n, n, false)
    local function shaded(r, c)
        return r >= 1 and r <= n and c >= 1 and c <= n and self.marks[r][c] == MARK_SHADE
    end
    local function open(r, c)
        return r >= 1 and r <= n and c >= 1 and c <= n and self.marks[r][c] ~= MARK_DOT
    end
    local pieces = {}
    for r = 1, n do
        for c = 1, n do
            if shaded(r, c) then
                local id = self.region[r][c]
                pieces[id] = pieces[id] or {}
                local p = pieces[id]
                p[#p + 1] = (r - 1) * n + c
            end
        end
    end
    local shape = {}
    for id, cells in pairs(pieces) do
        if #cells == 4 then shape[id] = Solver.shapeOf(n, cells) end
        if #cells > 4 or (#cells == 4 and not shape[id]) then
            for _, i in ipairs(cells) do
                conflict[math.floor((i - 1) / n) + 1][(i - 1) % n + 1] = true
            end
        end
    end
    local DIRS = { {-1,0}, {1,0}, {0,-1}, {0,1} }
    for r = 1, n do
        for c = 1, n do
            if shaded(r, c) then
                if r < n and c < n and shaded(r, c + 1) and shaded(r + 1, c) and shaded(r + 1, c + 1) then
                    conflict[r][c], conflict[r][c + 1] = true, true
                    conflict[r + 1][c], conflict[r + 1][c + 1] = true, true
                end
                local id = self.region[r][c]
                local possible = 0
                for _, d in ipairs(DIRS) do
                    local rr, cc = r + d[1], c + d[2]
                    if open(rr, cc) then possible = possible + 1 end
                    if shaded(rr, cc) then
                        local other = self.region[rr][cc]
                        if other ~= id and shape[id] and shape[id] == shape[other] then
                            conflict[r][c], conflict[rr][cc] = true, true
                        end
                    end
                end
                if possible == 0 then conflict[r][c] = true end
            end
        end
    end
    return conflict
end

function LitsBoard:countShaded()
    local count = 0
    for r = 1, self.n do
        for c = 1, self.n do
            if self.marks[r][c] == MARK_SHADE then count = count + 1 end
        end
    end
    return count
end

-- Four per region.
function LitsBoard:totalShaded()
    return 4 * self:_getPuzzle().nregions
end

function LitsBoard:toggleSolution()
    self.show_solution = not self.show_solution
    self.selected = nil
end

function LitsBoard:isShowingSolution()
    return self.show_solution
end

-- ---------------------------------------------------------------------------
-- Hint
-- ---------------------------------------------------------------------------

-- A dot is a note that the cell stays empty, so only shading decides the
-- puzzle: equals() compares shaded-ness, and a dot on a cell the solution
-- shades is reported (and cleared) as a mistake.
Hint.install(LitsBoard, {
    getUser     = function(b, r, c) return b.marks[r][c] end,
    getSolution = function(b, r, c) return b.solution[r][c] == 1 and MARK_SHADE or MARK_EMPTY end,
    isEmpty     = function(v) return v == MARK_EMPTY end,
    equals      = function(u, s) return (u == MARK_SHADE) == (s == MARK_SHADE) end,
    setCell     = function(b, r, c, v) return b:setMark(r, c, v) end,
    blank       = MARK_EMPTY,
})

-- ---------------------------------------------------------------------------
-- Serialization
-- ---------------------------------------------------------------------------

function LitsBoard:serialize()
    local n = self.n
    -- game-common up to 1.6.0 stops the clock in Timer:serialize(), which
    -- would freeze it at the first saved move: restart it (a no-op with a
    -- Timer that reads without stopping).
    local timer = self.timer:serialize()
    if timer.was_running then self.timer:start() end
    return {
        n          = n,
        difficulty = self.difficulty,
        level      = self.level,
        region     = toFlat(n, self.region),
        solution   = toFlat(n, self.solution),
        marks      = toFlat(n, self.marks),
        won        = self.won,
        hints_used = self.hints_used,
        timer      = timer,
        undo       = self.undo:serialize(),
    }
end

function LitsBoard:load(data)
    if type(data) ~= "table" or type(data.region) ~= "table"
            or type(data.solution) ~= "table" or type(data.marks) ~= "table" then
        return false
    end
    local n = tonumber(data.n)
    if not n or #data.region ~= n * n or #data.solution ~= n * n or #data.marks ~= n * n then
        return false
    end
    self.n          = n
    self.difficulty = data.difficulty or "easy"
    self.level      = data.level
    self.region     = toGrid(n, data.region)
    self.solution   = toGrid(n, data.solution)
    self.marks      = toGrid(n, data.marks)
    self.won        = data.won and true or false
    self.hints_used = tonumber(data.hints_used) or 0
    self.show_solution = false
    self.selected   = nil
    self._puzzle    = nil
    self.undo:load(data.undo)
    self.timer:load(data.timer)
    if self.won then self.timer:stop() end
    return true
end

LitsBoard.MARK_EMPTY   = MARK_EMPTY
LitsBoard.MARK_SHADE   = MARK_SHADE
LitsBoard.MARK_DOT     = MARK_DOT
LitsBoard.SIZES        = SIZES
LitsBoard.DEFAULT_N    = DEFAULT_N
LitsBoard.DIFFICULTIES = DIFFICULTIES
LitsBoard.Solver       = Solver

return LitsBoard
