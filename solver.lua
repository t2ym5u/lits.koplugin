-- ---------------------------------------------------------------------------
-- solver.lua — LITS rules engine: logical solver (graded), solution counter
-- and generator. Pure Lua, no KOReader dependency, so the specs can drive it
-- headless.
--
-- Rules: shade one tetromino (four orthogonally connected cells) in every
-- outlined region; two tetrominoes of the same shape (L, I, T or S, mirror
-- images and rotations included) may not touch side-on across a region
-- border; all shaded cells form one orthogonally connected group; no 2x2
-- block is entirely shaded.
--
-- Cells are addressed by a flat index i = (r - 1) * n + c. A solving state is
-- a flat array of UNKNOWN / SHADED / EMPTY.
-- ---------------------------------------------------------------------------

local Solver = {}

local UNKNOWN, SHADED, EMPTY = 0, 1, 2
Solver.UNKNOWN, Solver.SHADED, Solver.EMPTY = UNKNOWN, SHADED, EMPTY

-- The logical solver climbs a ladder of techniques, cheapest first:
--   tier 1: per-region piece fitting (cells every remaining placement covers
--           are shaded, cells none covers are empty), the 2x2 and same-shape
--           rules, and cells that can no longer join the shaded group;
--   tier 2: case analysis on a region down to two placements: place each,
--           propagate, keep what both outcomes agree on;
--   tier 3: the same on a region with more placements left, or a
--           single-cell trial ("if this cell were shaded, the rules above
--           would break"), one step deep.
-- Anything that needs more than that is never handed out as a puzzle. The
-- difficulty level is set by how much tier 2-3 work a puzzle takes (see
-- Solver.score below): easy is tier 1 plus one small case analysis at most.
Solver.LEVEL = { easy = 1, medium = 2, hard = 3 }

-- Shape ids, in the order of the name.
local L, I, T, S = 1, 2, 3, 4
Solver.SHAPE_NAMES = { "L", "I", "T", "S" }

local function shuffle(t)
    for i = #t, 2, -1 do
        local j = math.random(i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

local function copy(t)
    local c = {}
    for i = 1, #t do c[i] = t[i] end
    return c
end

-- ---------------------------------------------------------------------------
-- Tetromino orientations: every rotation and mirror image of L, I, T, S,
-- normalised to a top-left origin and deduplicated (I has 2, T and S 4, L 8).
-- ---------------------------------------------------------------------------

local BASE = {
    [L] = { {0,0}, {1,0}, {2,0}, {2,1} },
    [I] = { {0,0}, {1,0}, {2,0}, {3,0} },
    [T] = { {0,0}, {0,1}, {0,2}, {1,1} },
    [S] = { {0,1}, {0,2}, {1,0}, {1,1} },
}

local function normalise(cells)
    local mr, mc = math.huge, math.huge
    for _, p in ipairs(cells) do
        if p[1] < mr then mr = p[1] end
        if p[2] < mc then mc = p[2] end
    end
    local out = {}
    for k, p in ipairs(cells) do out[k] = { p[1] - mr, p[2] - mc } end
    table.sort(out, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)
    return out
end

local function key(cells)
    local parts = {}
    for k, p in ipairs(cells) do parts[k] = p[1] .. "," .. p[2] end
    return table.concat(parts, ";")
end

local ORIENTS = {}       -- list of { shape, offsets }
local SHAPE_OF_KEY = {}  -- normalised key -> shape id
for shape = 1, 4 do
    local cur = BASE[shape]
    for mirror = 1, 2 do
        for _ = 1, 4 do
            local nrm = normalise(cur)
            local k = key(nrm)
            if not SHAPE_OF_KEY[k] then
                SHAPE_OF_KEY[k] = shape
                ORIENTS[#ORIENTS + 1] = { shape = shape, cells = nrm }
            end
            local rot = {}
            for j, p in ipairs(cur) do rot[j] = { p[2], -p[1] } end
            cur = rot
        end
        local mir = {}
        for j, p in ipairs(cur) do mir[j] = { p[1], -p[2] } end
        cur = mir
    end
end

-- Shape id of a set of four flat cell indices, or nil (not connected, or the
-- square O, which LITS does not use).
function Solver.shapeOf(n, cells)
    if #cells ~= 4 then return nil end
    local pts = {}
    for k, i in ipairs(cells) do
        pts[k] = { math.floor((i - 1) / n), (i - 1) % n }
    end
    return SHAPE_OF_KEY[key(normalise(pts))]
end

-- ---------------------------------------------------------------------------
-- Puzzle geometry
-- ---------------------------------------------------------------------------

local geo_cache = {}

-- Neighbours, 2x2 blocks and every tetromino placement on an n x n grid.
local function geometry(n)
    if geo_cache[n] then return geo_cache[n] end
    local nb, blocks, blocks_of = {}, {}, {}
    for r = 1, n do
        for c = 1, n do
            local list = {}
            if r > 1 then list[#list + 1] = (r - 2) * n + c end
            if r < n then list[#list + 1] = r * n + c end
            if c > 1 then list[#list + 1] = (r - 1) * n + c - 1 end
            if c < n then list[#list + 1] = (r - 1) * n + c + 1 end
            local i = (r - 1) * n + c
            nb[i] = list
            blocks_of[i] = {}
        end
    end
    for r = 1, n - 1 do
        for c = 1, n - 1 do
            local i = (r - 1) * n + c
            local b = { i, i + 1, i + n, i + n + 1 }
            blocks[#blocks + 1] = b
            for _, x in ipairs(b) do
                blocks_of[x][#blocks_of[x] + 1] = b
            end
        end
    end
    -- Each placement carries what the filters need, precomputed once per
    -- grid size: its cells as a set, the cells touching it from outside,
    -- and the 2x2 blocks it overlaps.
    local placements = {}
    for r = 1, n do
        for c = 1, n do
            for _, o in ipairs(ORIENTS) do
                local cells, ok = {}, true
                for k, p in ipairs(o.cells) do
                    local rr, cc = r + p[1], c + p[2]
                    if rr > n or cc > n then ok = false; break end
                    cells[k] = (rr - 1) * n + cc
                end
                if ok then
                    local own, around, seen_a, plist, seen_b = {}, {}, {}, {}, {}
                    for _, x in ipairs(cells) do own[x] = true end
                    for _, x in ipairs(cells) do
                        for _, j in ipairs(nb[x]) do
                            if not own[j] and not seen_a[j] then
                                seen_a[j] = true
                                around[#around + 1] = j
                            end
                        end
                        for _, b in ipairs(blocks_of[x]) do
                            if not seen_b[b] then seen_b[b] = true; plist[#plist + 1] = b end
                        end
                    end
                    placements[#placements + 1] = { cells = cells, shape = o.shape,
                        own = own, around = around, blocks = plist }
                end
            end
        end
    end
    local placements_of = {}
    for i = 1, n * n do placements_of[i] = {} end
    for _, p in ipairs(placements) do
        for _, x in ipairs(p.cells) do
            local l = placements_of[x]
            l[#l + 1] = p
        end
    end
    -- box[x]: x and the cells around it, diagonals included -- the cells
    -- whose region's candidates can read x (a piece's cells, the cells
    -- touching it and its 2x2 blocks all lie within one step of it).
    local box = {}
    for r = 1, n do
        for c = 1, n do
            local list = {}
            for rr = math.max(1, r - 1), math.min(n, r + 1) do
                for cc = math.max(1, c - 1), math.min(n, c + 1) do
                    list[#list + 1] = (rr - 1) * n + cc
                end
            end
            box[(r - 1) * n + c] = list
        end
    end
    local g = { nb = nb, blocks = blocks, blocks_of = blocks_of, placements = placements,
                placements_of = placements_of, box = box }
    geo_cache[n] = g
    return g
end
Solver.geometry = geometry

-- region: flat array of region ids, 1..R with no gaps.
function Solver.newPuzzle(n, region)
    local g = geometry(n)
    local cells, nregions = {}, 0
    for i = 1, n * n do
        local id = region[i]
        if id > nregions then nregions = id end
        cells[id] = cells[id] or {}
        cells[id][#cells[id] + 1] = i
    end
    -- Candidate pieces per region: the placements lying wholly inside it.
    local cands = {}
    for id = 1, nregions do cands[id] = {} end
    for _, p in ipairs(g.placements) do
        local pc = p.cells
        local id = region[pc[1]]
        if region[pc[2]] == id and region[pc[3]] == id and region[pc[4]] == id then
            local list = cands[id]
            list[#list + 1] = p
        end
    end
    -- hits / mark / stack: scratch space for propagate and connectivity.
    local hits, mark = {}, {}
    for i = 1, n * n do hits[i], mark[i] = 0, 0 end
    return { n = n, N = n * n, region = region, cells = cells, cands = cands,
             nregions = nregions, nb = g.nb, blocks = g.blocks, blocks_of = g.blocks_of,
             box = g.box, hits = hits, mark = mark, stamp = 0, stack = {} }
end

-- ---------------------------------------------------------------------------
-- Tier 1: propagation. Returns false on a contradiction, else true and the
-- list of candidates still alive per region. `no_conn` leaves the
-- connectivity rule out (the grader applies it as a step of its own). Sound: every value it writes
-- holds in every solution consistent with the input state.
-- ---------------------------------------------------------------------------

local function fits(P, st, c, shaded_in_region, kshape)
    local cells = c.cells
    local covered = 0
    for k = 1, 4 do
        local v = st[cells[k]]
        if v == EMPTY then return false end
        if v == SHADED then covered = covered + 1 end
    end
    -- Every cell already shaded in the region must belong to the piece.
    if covered ~= shaded_in_region then return false end
    -- No 2x2 block made entirely of this piece and shaded cells.
    local own = c.own
    for _, b in ipairs(c.blocks) do
        local full = true
        for k = 1, 4 do
            local x = b[k]
            if not own[x] and st[x] ~= SHADED then full = false; break end
        end
        if full then return false end
    end
    -- No side contact with a shaded cell of a known same-shaped piece.
    do
        local region = P.region
        local around = c.around
        for k = 1, #around do
            local j = around[k]
            if st[j] == SHADED and kshape[region[j]] == c.shape then return false end
        end
    end
    return true
end

-- Cells that can no longer be joined to the shaded group are empty; a
-- shaded cell cut off from the others is a contradiction. Returns ok, and
-- the list of cells it emptied (nil if none).
local function connectivity(P, st)
    local N = P.N
    local start
    for i = 1, N do
        if st[i] == SHADED then start = i; break end
    end
    if not start then return true, nil end
    local nb = P.nb
    -- mark[i] == stamp: reached. One array per puzzle, never cleared.
    P.stamp = P.stamp + 1
    local stamp, mark, stack = P.stamp, P.mark, P.stack
    mark[start] = stamp
    stack[1] = start
    local top = 1
    while top > 0 do
        local i = stack[top]
        top = top - 1
        local ni = nb[i]
        for k = 1, #ni do
            local j = ni[k]
            if mark[j] ~= stamp and st[j] ~= EMPTY then
                mark[j] = stamp
                top = top + 1
                stack[top] = j
            end
        end
    end
    local cut
    for i = 1, N do
        if mark[i] ~= stamp then
            local v = st[i]
            if v == SHADED then return false end
            if v == UNKNOWN then
                st[i] = EMPTY
                cut = cut or {}
                cut[#cut + 1] = i
            end
        end
    end
    return true, cut
end

-- `alive0`: candidate lists to start from (those of an earlier, weaker
-- state of the same puzzle). `seeds`: when st was a propagation fixpoint
-- (for alive0) before some cells were written, those cells; only the
-- regions near them are re-filtered at first. Either way the result is the
-- same fixpoint as a run from scratch, which re-filters every region until
-- nothing changes: the rules only ever remove options, so the order they
-- run in does not matter.
local function propagate(P, st, no_conn, alive0, seeds)
    local cells, region, N = P.cells, P.region, P.N
    local R = P.nregions
    local box, nb, hits = P.box, P.nb, P.hits
    local alive, kshape, shaded, dirty = {}, {}, {}, {}
    for id = 1, R do
        local a = alive0 and alive0[id] or P.cands[id]
        alive[id] = a
        shaded[id] = 0
        dirty[id] = not seeds
        -- A region whose remaining placements all share one shape holds
        -- its neighbours to the shape rule.
        local sh = a[1] and a[1].shape
        for k = 2, #a do
            if a[k].shape ~= sh then sh = nil; break end
        end
        kshape[id] = sh
    end
    for i = 1, N do
        if st[i] == SHADED then shaded[region[i]] = shaded[region[i]] + 1 end
    end
    -- 2x2 blocks to look at: all of them (or those around the seeds) on the
    -- first pass, then only those around newly shaded cells.
    local blocks_todo
    if seeds then
        blocks_todo = {}
        local seen = {}
        for _, x in ipairs(seeds) do
            local bx = box[x]
            for k = 1, #bx do dirty[region[bx[k]]] = true end
            for _, blk in ipairs(P.blocks_of[x]) do
                if not seen[blk] then seen[blk] = true; blocks_todo[#blocks_todo + 1] = blk end
            end
        end
    else
        blocks_todo = P.blocks
    end
    local first = true
    while true do
        local changed = false
        local fresh = {}
        for id = 1, R do
            if dirty[id] then
                dirty[id] = false
                local prev, a = alive[id], {}
                local sh_id = shaded[id]
                for k = 1, #prev do
                    if fits(P, st, prev[k], sh_id, kshape) then a[#a + 1] = prev[k] end
                end
                local na = #a
                if na == 0 then return false end
                alive[id] = a
                if na < #prev and not kshape[id] then
                    local sh = a[1].shape
                    for k = 2, na do
                        if a[k].shape ~= sh then sh = nil; break end
                    end
                    if sh then
                        kshape[id] = sh
                        changed = true
                        -- The regions touching this one.
                        local list = cells[id]
                        for k = 1, #list do
                            local nx = nb[list[k]]
                            for m = 1, #nx do dirty[region[nx[m]]] = true end
                        end
                    end
                end
                -- Covered by every placement: shaded. By none: empty.
                for k = 1, na do
                    local cc = a[k].cells
                    for m = 1, 4 do hits[cc[m]] = hits[cc[m]] + 1 end
                end
                local list = cells[id]
                for k = 1, #list do
                    local x = list[k]
                    if st[x] == UNKNOWN then
                        local h = hits[x]
                        if h == na then
                            st[x] = SHADED; changed = true
                            shaded[id] = shaded[id] + 1
                            fresh[#fresh + 1] = x
                        elseif h == 0 then
                            st[x] = EMPTY; changed = true
                        end
                        if h == na or h == 0 then
                            local bx = box[x]
                            for m = 1, #bx do dirty[region[bx[m]]] = true end
                        end
                    end
                    hits[x] = 0
                end
            end
        end
        -- 2x2: three shaded cells empty the fourth.
        if not first then
            blocks_todo = {}
            local seen = {}
            for _, x in ipairs(fresh) do
                for _, b in ipairs(P.blocks_of[x]) do
                    if not seen[b] then seen[b] = true; blocks_todo[#blocks_todo + 1] = b end
                end
            end
        end
        for b = 1, #blocks_todo do
            local blk = blocks_todo[b]
            local sc, unk = 0, nil
            for k = 1, 4 do
                local v = st[blk[k]]
                if v == SHADED then sc = sc + 1 elseif v == UNKNOWN then unk = blk[k] end
            end
            if sc == 4 then return false end
            if sc == 3 and unk then
                st[unk] = EMPTY; changed = true
                local bx = box[unk]
                for m = 1, #bx do dirty[region[bx[m]]] = true end
            end
        end
        -- Connectivity can only change when a cell was emptied (or shaded:
        -- a shaded cell must be reachable too).
        if not no_conn and (first or changed) then
            local ok, cut = connectivity(P, st)
            if not ok then return false end
            if cut then
                changed = true
                for _, x in ipairs(cut) do
                    local bx = box[x]
                    for m = 1, #bx do dirty[region[bx[m]]] = true end
                end
            end
        end
        first = false
        if not changed then return true, alive end
    end
end
Solver.propagate = propagate

local function isComplete(st)
    for i = 1, #st do
        if st[i] == UNKNOWN then return false end
    end
    return true
end

-- Places candidate c in its region: its cells shaded, the region's other
-- cells empty.
local function place(P, st, id, c)
    local list = P.cells[id]
    for k = 1, #list do
        if st[list[k]] == UNKNOWN then st[list[k]] = EMPTY end
    end
    for k = 1, 4 do st[c.cells[k]] = SHADED end
end

-- ---------------------------------------------------------------------------
-- Tiers 2-3: region case analysis. For one region with more than one
-- placement left (and at most max_ways), place each in turn, propagate, and
-- keep every cell on which all surviving placements agree.
-- Returns "contra", true (progress) or false.
-- ---------------------------------------------------------------------------

local function regionStep(P, st, alive, max_ways)
    local N = P.N
    for id = 1, P.nregions do
        local a = alive[id]
        if #a > 1 and #a <= max_ways then
            -- st is a propagation fixpoint here (every caller propagates
            -- first), so each case propagates from the cells it wrote.
            local list = P.cells[id]
            local seeds = {}
            for k = 1, #list do
                if st[list[k]] == UNKNOWN then seeds[#seeds + 1] = list[k] end
            end
            -- agree: the first surviving case, then the cells every later
            -- one agrees with (the rest reset to UNKNOWN). Once nothing is
            -- left to agree on, the region can only fail to progress.
            local agree, left = nil, 0
            for k = 1, #a do
                if agree and left == 0 then break end
                local t = copy(st)
                place(P, t, id, a[k])
                if propagate(P, t, false, alive, seeds) then
                    if not agree then
                        agree = t
                        for i = 1, N do
                            if st[i] == UNKNOWN and t[i] ~= UNKNOWN then left = left + 1 end
                        end
                    else
                        for i = 1, N do
                            local v = agree[i]
                            if v ~= UNKNOWN and st[i] == UNKNOWN and t[i] ~= v then
                                agree[i] = UNKNOWN
                                left = left - 1
                            end
                        end
                    end
                end
            end
            if not agree then return "contra" end
            if left > 0 then
                local changed = {}
                for i = 1, N do
                    if st[i] == UNKNOWN and agree[i] ~= UNKNOWN then
                        st[i] = agree[i]
                        changed[#changed + 1] = i
                    end
                end
                return true, changed
            end
        end
    end
    return false
end

-- Case analysis up to this many placements is tier 2, beyond it tier 3.
local SMALL_CASES = 2

-- Propagation plus the small case analyses, to a fixpoint. `alive` and
-- `seeds` as for propagate (nil: from scratch).
local function closure(P, st, max_ways, alive, seeds)
    while true do
        local ok
        ok, alive = propagate(P, st, false, alive, seeds)
        if not ok then return false end
        local r, changed = regionStep(P, st, alive, max_ways)
        if r == "contra" then return false end
        if not r then return true, alive end
        seeds = changed
    end
end

-- ---------------------------------------------------------------------------
-- Tier 3: single-cell trial with propagation and the small case analyses.
-- st is a fixpoint of every cheaper technique here, so a trial propagates
-- from the one cell it wrote.
-- ---------------------------------------------------------------------------

local function trialStep(P, st, alive)
    for i = 1, P.N do
        if st[i] == UNKNOWN then
            local t = copy(st)
            t[i] = SHADED
            if not closure(P, t, SMALL_CASES, alive, { i }) then st[i] = EMPTY; return true, { i } end
            t = copy(st)
            t[i] = EMPTY
            if not closure(P, t, SMALL_CASES, alive, { i }) then st[i] = SHADED; return true, { i } end
        end
    end
    return false
end

-- Which tier each technique belongs to (see the ladder above).
local TIER = { conn = 1, small = 2, full = 3, trial = 3 }

-- Solve by logic alone, cheapest technique first, going back to the start of
-- the ladder after every deduction; `max_level` caps the tier. Returns status
-- ("solved" / "stuck" / "contra"), the highest tier that was needed, the
-- final state, and how many deductions each tier made ({ [1] = .., [2] = ..,
-- [3] = .. }).
function Solver.logicSolve(P, max_level, st)
    st = st and copy(st) or {}
    if #st == 0 then for i = 1, P.N do st[i] = UNKNOWN end end
    local used, steps = 1, { 0, 0, 0 }
    local function note(tier)
        steps[tier] = steps[tier] + 1
        if tier > used then used = tier end
    end
    -- After the first pass, propagation restarts from the cells the last
    -- deduction wrote, with the candidates it had left.
    local alive, seeds
    while true do
        local ok
        ok, alive = propagate(P, st, true, alive, seeds)
        if not ok then return "contra", used, st, steps end
        if isComplete(st) then return "solved", used, st, steps end
        local progress = false
        if TIER.conn <= max_level then
            local ok2, cut = connectivity(P, st)
            if not ok2 then return "contra", used, st, steps end
            if cut then progress = true; seeds = cut; note(TIER.conn) end
        end
        if not progress and TIER.small <= max_level then
            local r, changed = regionStep(P, st, alive, SMALL_CASES)
            if r == "contra" then return "contra", used, st, steps end
            if r then progress = true; seeds = changed; note(TIER.small) end
        end
        if not progress and TIER.full <= max_level then
            local r, changed = regionStep(P, st, alive, math.huge)
            if r == "contra" then return "contra", used, st, steps end
            if r then progress = true; seeds = changed; note(TIER.full) end
        end
        if not progress and TIER.trial <= max_level then
            local r, changed = trialStep(P, st, alive)
            if r then progress = true; seeds = changed; note(TIER.trial) end
        end
        if not progress then return "stuck", used, st, steps end
    end
end

-- ---------------------------------------------------------------------------
-- Rule check on a finished shading (flat array of booleans or 1/0).
-- ---------------------------------------------------------------------------

function Solver.isValid(P, shaded)
    local function on(i) return shaded[i] == true or shaded[i] == 1 end
    local n, N = P.n, P.N
    local piece, shape = {}, {}
    for id = 1, P.nregions do piece[id] = {} end
    local total, start = 0, nil
    for i = 1, N do
        if on(i) then
            local p = piece[P.region[i]]
            p[#p + 1] = i
            total = total + 1
            start = start or i
        end
    end
    for id = 1, P.nregions do
        shape[id] = Solver.shapeOf(n, piece[id])
        if not shape[id] then return false end
    end
    for _, b in ipairs(P.blocks) do
        if on(b[1]) and on(b[2]) and on(b[3]) and on(b[4]) then return false end
    end
    for i = 1, N do
        if on(i) then
            for _, j in ipairs(P.nb[i]) do
                if on(j) and P.region[j] ~= P.region[i]
                        and shape[P.region[j]] == shape[P.region[i]] then
                    return false
                end
            end
        end
    end
    local seen, stack, reached = { [start] = true }, { start }, 1
    while #stack > 0 do
        local i = table.remove(stack)
        for _, j in ipairs(P.nb[i]) do
            if not seen[j] and on(j) then
                seen[j] = true
                reached = reached + 1
                stack[#stack + 1] = j
            end
        end
    end
    return reached == total
end

-- ---------------------------------------------------------------------------
-- Solution counter: propagation + branching on the region with the fewest
-- placements left. Counts up to `limit` solutions, giving up after `budget`
-- nodes, from `start` (a partial state) or from scratch.
-- Returns count, exhausted, solutions.
-- ---------------------------------------------------------------------------

function Solver.countSolutions(P, limit, budget, start, start_alive)
    limit  = limit or 2
    budget = budget or 20000
    local count, nodes, exhausted = 0, 0, false
    local sols = {}

    -- A child differs from its propagated parent only by the piece placed,
    -- so it propagates from that region's cells.
    local function dfs(st, parent_alive, seeds)
        if count >= limit or exhausted then return end
        nodes = nodes + 1
        if nodes > budget then exhausted = true; return end
        local ok, alive = propagate(P, st, false, parent_alive, seeds)
        if not ok then return end
        local best, best_n = nil, math.huge
        for id = 1, P.nregions do
            local k = #alive[id]
            if k > 1 and k < best_n then best, best_n = id, k end
        end
        if not best then
            -- Every region is down to one piece, so propagation has shaded
            -- it and emptied the rest -- and checked the 2x2, shape and
            -- connectivity rules on the finished grid on the way.
            count = count + 1
            sols[#sols + 1] = st
            return
        end
        local seeds = {}
        local list = P.cells[best]
        for k = 1, #list do
            if st[list[k]] == UNKNOWN then seeds[#seeds + 1] = list[k] end
        end
        for _, c in ipairs(alive[best]) do
            local t = copy(st)
            place(P, t, best, c)
            dfs(t, alive, seeds)
            if count >= limit or exhausted then return end
        end
    end

    local st = start and copy(start) or {}
    if not start then for i = 1, P.N do st[i] = UNKNOWN end end
    dfs(st, start_alive)
    return count, exhausted, sols
end

-- ---------------------------------------------------------------------------
-- Generator
--
-- Solution first: grow a connected shading one tetromino at a time (each new
-- piece touches the group, makes no 2x2 block and touches no piece of its own
-- shape), give every piece a region grown over the empty cells, and the
-- planted shading is valid by construction. Uniqueness is then forced by
-- region surgery: while the counter finds several solutions, move a cell on
-- which two of them disagree into a neighbouring region (see makeUnique).
-- Last, reshape toward the requested difficulty with moves that keep the
-- solution, checked by the logical solver.
-- ---------------------------------------------------------------------------

-- Placements weighed per piece when planting (see snug below), and
-- plantings per attempt (see generateBest).
local PLANT_SAMPLE = 200
local PLANT_TRIES = 2

local function plantPieces(n, max_cells)
    local g = geometry(n)
    local N = n * n
    local sol, piece_of, shapes = {}, {}, {}
    for i = 1, N do sol[i] = 0 end
    local order = {}
    for k = 1, #g.placements do order[k] = k end
    local count = 0

    -- p.around / p.blocks are precomputed per placement (see geometry).
    local function ok(p)
        local pc = p.cells
        for k = 1, 4 do
            if sol[pc[k]] ~= 0 then return false end
        end
        local touches = (count == 0)
        local around = p.around
        for k = 1, #around do
            local j = around[k]
            if sol[j] ~= 0 then
                touches = true
                if shapes[piece_of[j]] == p.shape then return false end
            end
        end
        if not touches then return false end
        local own, blocks = p.own, p.blocks
        for k = 1, #blocks do
            local b = blocks[k]
            local full = true
            for m = 1, 4 do
                if not own[b[m]] and sol[b[m]] == 0 then full = false; break end
            end
            if full then return false end
        end
        return true
    end

    -- Snug placements first: a piece hugging the group leaves fewer thin gaps
    -- that nothing fits in later, so the shading packs denser (about 60%,
    -- Nikoli's own LITS density) -- and dense shading means small regions,
    -- which is where uniqueness comes from. Hugging the grid edge as well
    -- packs denser still, but shades nearly the whole border: a giveaway.
    local function snug(p)
        local own, score = p.own, 0
        local pc = p.cells
        for k = 1, 4 do
            local ni = g.nb[pc[k]]
            for m = 1, #ni do
                local j = ni[m]
                if not own[j] and sol[j] ~= 0 then score = score + 1 end
            end
        end
        return score
    end
    while count * 4 + 4 <= max_cells do
        shuffle(order)
        local best, best_score
        local seen = 0
        for _, k in ipairs(order) do
            local p = g.placements[k]
            if ok(p) then
                local sc = snug(p)
                if not best or sc > best_score then best, best_score = p, sc end
                -- The snuggest of a random sample is snug enough.
                seen = seen + 1
                if seen >= PLANT_SAMPLE then break end
            end
        end
        if not best then break end
        count = count + 1
        shapes[count] = best.shape
        for _, x in ipairs(best.cells) do sol[x] = 1; piece_of[x] = count end
    end
    return sol, piece_of, count
end

-- One region per piece, grown over the empty cells. Each step gives one
-- empty cell next to the regions to the neighbouring region where it opens
-- the fewest new tetromino placements (random tie-break): a region that only
-- fits its own piece is what makes a LITS unique, and a careless cell is
-- enough to let a second placement in.
local function buildRegions(n, sol, piece_of, count)
    local g = geometry(n)
    local nb, placements_of = g.nb, g.placements_of
    local N = n * n
    local region = {}
    for i = 1, N do
        if sol[i] == 1 then region[i] = piece_of[i] end
    end
    -- Placements through x lying inside region id once x joins it.
    local function opened(x, id)
        local k = 0
        for _, p in ipairs(placements_of[x]) do
            local inside = true
            for _, y in ipairs(p.cells) do
                if y ~= x and region[y] ~= id then inside = false; break end
            end
            if inside then k = k + 1 end
        end
        return k
    end
    while true do
        local best_x, best_id, best_k, ties = nil, nil, math.huge, 0
        for x = 1, N do
            if not region[x] then
                local seen = {}
                for _, j in ipairs(nb[x]) do
                    local id = region[j]
                    if id and not seen[id] then
                        seen[id] = true
                        local k = opened(x, id)
                        if k < best_k then
                            best_x, best_id, best_k, ties = x, id, k, 1
                        elseif k == best_k then
                            ties = ties + 1
                            if math.random(ties) == 1 then best_x, best_id = x, id end
                        end
                    end
                end
            end
        end
        if not best_x then break end
        region[best_x] = best_id
    end
    for i = 1, N do
        if not region[i] then return nil end
    end
    return region
end

-- A planted layout before any uniqueness work: valid, usually ambiguous.
-- Returns the flat region and solution arrays (for the specs, which need
-- grids that do have solutions to hold the solvers to brute force).
function Solver.plantedLayout(n, max_cells)
    local sol, piece_of, count = plantPieces(n, max_cells or n * n)
    local region = count >= 1 and buildRegions(n, sol, piece_of, count)
    return region, sol
end

-- Solution-keeping surgery, for the difficulty climb: x, empty in the
-- solution, leaves its region for a neighbouring one, taking along any empty
-- dead end it was holding on, so no region splits and no piece is touched.
-- Returns the cells that would move and the candidate target regions, or nil
-- if x cannot move.
local function planMove(n, sol, region, x)
    if sol[x] ~= 0 then return nil end
    local nb = geometry(n).nb
    local id, N = region[x], n * n
    local anchor
    for i = 1, N do
        if region[i] == id and sol[i] == 1 then anchor = i; break end
    end
    local seen, stack = { [anchor] = true, [x] = true }, { anchor }
    while #stack > 0 do
        local i = table.remove(stack)
        for _, j in ipairs(nb[i]) do
            if not seen[j] and region[j] == id then
                seen[j] = true
                stack[#stack + 1] = j
            end
        end
    end
    local group = { x }
    for i = 1, N do
        if region[i] == id and not seen[i] then
            if sol[i] == 1 then return nil end
            group[#group + 1] = i
        end
    end
    local targets, have = {}, {}
    for _, gc in ipairs(group) do
        for _, j in ipairs(nb[gc]) do
            local t = region[j]
            if t ~= id and not have[t] then
                have[t] = true
                targets[#targets + 1] = t
            end
        end
    end
    if #targets == 0 then return nil end
    return group, targets
end

local function moveOneOf(n, sol, region, cells)
    for _, x in ipairs(cells) do
        local group, targets = planMove(n, sol, region, x)
        if group then
            local t, old = targets[math.random(#targets)], region[x]
            for _, gc in ipairs(group) do region[gc] = t end
            return function()
                for _, gc in ipairs(group) do region[gc] = old end
            end
        end
    end
    return nil
end

local function emptyCells(sol, extra)
    local list = {}
    for i = 1, #sol do
        if sol[i] == 0 and (not extra or extra(i)) then list[#list + 1] = i end
    end
    return shuffle(list)
end

-- Progress report: generate() points `progress` at the caller's callback
-- for its duration, and every layout measured (one solution count or one
-- grading) is a unit of work. How many units a puzzle takes is not known in
-- advance, so the fraction reported approaches 1 without reaching it: half
-- way after PROGRESS_HALF units, about the average at 10x10 hard (7x7 takes
-- ~90, the worst seen ~700). It only reads a counter -- never the clock,
-- never math.random -- so reporting cannot change the puzzle (the Daily
-- Challenge needs every device to build the same grid from the same seed).
local PROGRESS_HALF = 150
local progress, work = nil, 0

local function tick()
    if progress then
        work = work + 1
        progress(1 - 0.5 ^ (work / PROGRESS_HALF))
    end
end

-- Uniqueness climb: the measure is the number of solutions counted up to
-- CAP from the state propagation reaches (ties broken by the slack, the
-- placements beyond the one each region needs); a move is kept unless it
-- made things worse (with a little slack, to get off plateaus).
local ACCEPT_WORSE = 0.1
local BUDGET = 400
local CAP = 8

-- Uniqueness surgery. Unlike norinori, any cell may change region, shaded
-- ones included, so the solution itself may change along the way: moving
-- only the planted solution's empty cells (norinori's way) stalls here, a
-- LITS region being loose enough to fit several pieces whatever its empty
-- cells do. The climb keeps the layout solvable and walks the solution count
-- down to one.
--
-- If taking x out would split its region, the smaller parts go along with x
-- (the largest part stays, and must keep four cells). Without that, a cell
-- that is a region's only way through could never move -- and that is just
-- the cell a two-way piece slides over, at the end of a corridor: about a
-- third of the attempts used to stall on two solutions that way.
local function freeMove(n, region, cells)
    local nb = geometry(n).nb
    local N = n * n
    for _, x in ipairs(cells) do
        local id = region[x]
        local targets = {}
        for _, j in ipairs(nb[x]) do
            if region[j] ~= id then targets[#targets + 1] = region[j] end
        end
        if #targets > 0 then
            -- The parts the region falls into without x.
            local part, parts = {}, {}
            for i = 1, N do
                if region[i] == id and i ~= x and not part[i] then
                    local p = { i }
                    part[i] = true
                    local k = 1
                    while k <= #p do
                        local ni = nb[p[k]]
                        k = k + 1
                        for m = 1, #ni do
                            local j = ni[m]
                            if not part[j] and j ~= x and region[j] == id then
                                part[j] = true
                                p[#p + 1] = j
                            end
                        end
                    end
                    parts[#parts + 1] = p
                end
            end
            local big = 1
            for k = 2, #parts do
                if #parts[k] > #parts[big] then big = k end
            end
            if parts[big] and #parts[big] >= 4 then
                local group = { x }
                for k = 1, #parts do
                    if k ~= big then
                        for _, c in ipairs(parts[k]) do group[#group + 1] = c end
                    end
                end
                local t = targets[math.random(#targets)]
                for _, c in ipairs(group) do region[c] = t end
                return function()
                    for _, c in ipairs(group) do region[c] = id end
                end
            end
        end
    end
    return nil
end

-- Returns the measure (lower is better) and the solutions found, or nil
-- when the layout has no solution at all.
local function freeMeasure(n, region, budget)
    tick()
    local P = Solver.newPuzzle(n, region)
    local st = {}
    for i = 1, P.N do st[i] = UNKNOWN end
    local ok, alive = closure(P, st, SMALL_CASES)
    if not ok then return nil end
    local count, exhausted, sols = Solver.countSolutions(P, CAP, budget, st, alive)
    if count == 0 and not exhausted then return nil end
    if exhausted then count = CAP end
    local total = 0
    for id = 1, P.nregions do total = total + #P.cands[id] - 1 end
    return count * 10000 + total, sols
end

local function makeUnique(n, region, max_moves, budget)
    local N = n * n
    local cur, sols = freeMeasure(n, region, budget)
    if not cur then return nil end
    for _ = 1, max_moves do
        if cur < 20000 and #sols == 1 then
            local sol = {}
            for i = 1, N do sol[i] = sols[1][i] == SHADED and 1 or 0 end
            return sol
        end
        local diff = {}
        if #sols >= 2 then
            local a, b = sols[1], sols[math.random(2, #sols)]
            for i = 1, N do if a[i] ~= b[i] then diff[#diff + 1] = i end end
        else
            for i = 1, N do diff[#diff + 1] = i end
        end
        local undo = freeMove(n, region, shuffle(diff))
        if not undo then
            local all = {}
            for i = 1, N do all[i] = i end
            undo = freeMove(n, region, shuffle(all))
        end
        if not undo then return nil end
        local nc, nsols = freeMeasure(n, region, budget)
        if nc and (nc <= cur or math.random() < ACCEPT_WORSE) then
            cur, sols = nc, nsols
        else
            undo()
        end
    end
    return nil
end

-- The grade counts the work rather than only naming the hardest technique
-- (a LITS of any size usually needs a case analysis or two somewhere): each
-- case analysis on a region down to two placements scores 1, each bigger
-- analysis or trial 3. Easy allows one small analysis at most, hard takes a
-- score of HARD_SCORE or more; measured over unique 7x7-10x10 layouts this
-- splits them roughly into thirds.
local EASY_MAX   = 1
local HARD_SCORE = 5

function Solver.score(steps)
    return steps[2] + 3 * steps[3]
end

function Solver.levelOf(status, steps)
    if status ~= "solved" then return nil end
    local score = Solver.score(steps)
    if score <= EASY_MAX then return 1 end
    return score < HARD_SCORE and 2 or 3
end

local function countOpen(st)
    local open = 0
    for i = 1, #st do
        if st[i] == UNKNOWN then open = open + 1 end
    end
    return open
end

-- How far the puzzle is from the wanted level, 0 = on target, nil = not
-- acceptable (no longer unique, or beyond the tier-3 solver).
local function distance(n, region, want, budget)
    tick()
    local P = Solver.newPuzzle(n, region)
    -- Tiers 1-2 first: trials are by far the dearest step.
    local status, _, st, steps = Solver.logicSolve(P, 2)
    if status == "contra" then return nil end
    if status ~= "solved" then
        -- Stuck before trials: still unique at all?
        local count, exhausted = Solver.countSolutions(P, 2, budget, st)
        if count ~= 1 or exhausted then return nil end
        -- Far from easy; the cells left open give the climb a slope.
        if want == 1 then return 10 + countOpen(st) end
        local more
        status, _, _, more = Solver.logicSolve(P, 3, st)
        if status ~= "solved" then return nil end
        steps = { steps[1], steps[2] + more[2], steps[3] + more[3] }
    end
    local score = Solver.score(steps)
    if want == 1 then return math.max(0, score - EASY_MAX) end
    if want == 2 then
        if score <= EASY_MAX then return EASY_MAX + 1 - score end
        return math.max(0, score - HARD_SCORE + 1)
    end
    return math.max(0, HARD_SCORE - score)
end

local function climb(n, sol, region, want, moves, budget)
    local d = distance(n, region, want, budget)
    for _ = 1, moves do
        if d == 0 then break end
        local undo = moveOneOf(n, sol, region, emptyCells(sol))
        if not undo then break end
        local nd = distance(n, region, want, budget)
        if nd and (not d or nd <= d) then d = nd else undo() end
    end
    return d
end

local function generateBest(n, difficulty, opts)
    local want = Solver.LEVEL[difficulty] or 1
    local max_attempts = opts.max_attempts or math.floor(4000 / (n * n))
    local best, best_d
    for _ = 1, max_attempts do
        -- The denser of two plantings: denser shading means smaller
        -- regions, and the surgery reaches uniqueness more often.
        local sol, piece_of, count = plantPieces(n, n * n)
        for _ = 2, PLANT_TRIES do
            local s2, p2, c2 = plantPieces(n, n * n)
            if c2 > count then sol, piece_of, count = s2, p2, c2 end
        end
        local region = count >= 2 and buildRegions(n, sol, piece_of, count)
        local unique = region and makeUnique(n, region, 8 * n, BUDGET)
        if unique then
            local d = climb(n, unique, region, want, 10 * n, BUDGET)
            if d and (not best or d < best_d) then
                best, best_d = { n = n, region = region, solution = unique }, d
            end
            if d == 0 then break end
        end
    end
    if best then
        local status, _, _, steps = Solver.logicSolve(Solver.newPuzzle(n, best.region), 3)
        best.level, best.difficulty = Solver.levelOf(status, steps) or 3, difficulty
    end
    return best
end

-- Returns { n, region = flat, solution = flat 1/0, level, difficulty }, or
-- nil if every attempt failed (callers retry). `opts.max_attempts` bounds
-- the restarts; the closest unique puzzle found is used if none hits the
-- requested level exactly. `opts.progress(fraction)`, if given, is called as
-- the work goes on (see tick), and with 1 at the end. Planting packs pieces
-- until none fits, which lands near 60% shaded. Every budget is counted in
-- moves or search nodes, never in time: the puzzle is a pure function of the
-- math.random sequence.
function Solver.generate(n, difficulty, opts)
    opts = opts or {}
    progress, work = opts.progress, 0
    local best = generateBest(n, difficulty, opts)
    local report = progress
    progress = nil
    if report then report(1) end
    return best
end

return Solver
