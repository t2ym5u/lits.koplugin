local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template
local time            = require("ui/time")

local ScreenBase          = lrequire("common/screen_base")
local MenuHelper          = lrequire("common/menu_helper")
local LitsBoard       = lrequire("board")
local LitsBoardWidget = lrequire("board_widget")

local GAME_RULES_EN = _([[
LITS — Rules

Shade one tetromino in every outlined region: four cells joined side by side, in the shape of an L, an I, a T or an S (turned or mirrored any way).

• Two tetrominoes of the same shape may not touch side by side across a region border. Mirror images and rotations count as the same shape.
• All the shaded cells together form one connected group.
• No 2×2 square may be entirely shaded.

Tap a cell to cycle: shaded → dot (sure to stay empty) → blank. Hold a cell to blank it.
A shaded cell that already breaks a rule is crossed out.
]])

local GAME_RULES_FR = [[
LITS — Règles

Noircissez un tétromino dans chaque région délimitée : quatre cases reliées par leurs côtés, en forme de L, de I, de T ou de S (tourné ou retourné dans n'importe quel sens).

• Deux tétrominos de même forme ne peuvent pas se toucher par un côté d'une région à l'autre. Les images miroir et les rotations comptent comme la même forme.
• Toutes les cases noires forment un seul groupe d'un seul tenant.
• Aucun carré 2×2 ne peut être entièrement noir.

Touchez une case pour alterner : noire → point (sûrement vide) → vide. Restez appuyé pour la vider.
Une case noire qui enfreint déjà une règle est barrée.
]]

local LitsScreen = ScreenBase:extend{
    -- Generation shows a progress bar only once it has run this long, so
    -- the usual quick one shows nothing.
    progress_delay_ms = 200,
}

-- Generation runs synchronously, so nothing would repaint while it works
-- (seconds for a big grid on an e-reader). As in sudoku-common's
-- base_screen, the generator's progress callback drives a ProgressbarDialog,
-- which forces its own repaints. The callback only reads the clock to decide
-- whether to show the dialog; the generator never does, so the grid (and the
-- Daily Challenge's) does not depend on how fast the device is.
function LitsScreen:generateBoard(board)
    local start = time.now()
    local dialog
    board:generate(function(fraction)
        if not dialog then
            if time.to_ms(time.since(start)) < self.progress_delay_ms then return end
            dialog = ProgressbarDialog:new{
                title                = _("Generating puzzle…"),
                progress_max         = 1,
                refresh_time_seconds = 0.15,
                dismissable          = false,
            }
            dialog:show()
        end
        dialog:reportProgress(fraction)
    end)
    if dialog then dialog:close() end
end

function LitsScreen:init()
    local state = self.plugin:loadState()
    self.board  = LitsBoard:new{
        n          = self.plugin:getSetting("grid_n", LitsBoard.DEFAULT_N),
        difficulty = self.plugin:getSetting("difficulty", "easy"),
    }
    if not self.board:load(state) then
        self:generateBoard(self.board)
    end
    ScreenBase.init(self)
end

function LitsScreen:serializeState()
    return self.board:serialize()
end

function LitsScreen:buildLayout()
    local is_landscape = self:isLandscape()

    local title_bar = self:buildTitleBar(_("LITS"), function()
        return {
            { text = _("New game"),               callback = function() self:onNewGame() end },
            self:makeDailyButtonConfig(),
            { text = self:getSizeButtonText(),    callback = function() self:openSizeMenu() end },
            { text = self:getDiffButtonText(),    callback = function() self:openDifficultyMenu() end },
            { text = self:getRevealButtonText(),  callback = function() self:toggleSolution() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    -- Controls first: the board is sized from whatever room they leave.
    self.status_text:setMaxWidth(self:getControlsWidth())
    local action_bar = self:buildActionBar({
        { id = "undo_button", text = _("Undo"), callback = function() self:onUndo() end },
        { text = _("Hint"),    callback = function() self:onHint() end },
        { text = _("Restart"), callback = function() self:onRestart() end },
    })
    self.undo_button = action_bar:getButtonById("undo_button")
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        action_bar,
    }

    -- The widget draws its own thick outer border, so the frame only pads.
    local frame_pad   = Size.padding.large
    local frame_extra = 2 * frame_pad
    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    self.board_widget = LitsBoardWidget:new{
        board        = self.board,
        max_size     = math.min(budget_w, budget_h) - frame_extra,
        onCellAction = function(r, c, is_hold) self:onCellAction(r, c, is_hold) end,
    }
    local board_frame = FrameContainer:new{
        padding    = frame_pad,
        margin     = 0,
        bordersize = 0,
        self.board_widget,
    }
    self:_updateUndoButton()

    if is_landscape then
        local content = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        }
        self:buildLandscapeLayout(title_bar, content)
    else
        self:buildPortraitLayout(title_bar, board_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
    self:updateStatus()
end

-- Anything that changed the marks: save, redraw, and let the action bar
-- swap to "New game" if the puzzle just got solved.
function LitsScreen:_afterMove()
    self.plugin:saveState(self.board:serialize())
    self:_updateUndoButton()
    self.board_widget:refresh()
    self:updateStatus()
    self:refreshActionBar()
end

function LitsScreen:onCellAction(r, c, is_hold)
    if self.board:isShowingSolution() then
        self:updateStatus(_("Hide the solution to keep playing."))
        return
    end
    local ok
    if is_hold then
        ok = self.board:setMark(r, c, LitsBoard.MARK_EMPTY)
    else
        ok = self.board:cycleCell(r, c)
    end
    if ok then self:_afterMove() end
end

function LitsScreen:onUndo()
    if self.board:undoMove() then self:_afterMove() end
end

function LitsScreen:onRestart()
    if self.board:clearAll() then self:_afterMove() end
end

function LitsScreen:isRoundOver()
    return self.board:isSolved()
end

-- A hint can place the last cell, so the round may end here.
function LitsScreen:onHint()
    ScreenBase.onHint(self)
    self:_updateUndoButton()
    self:refreshActionBar()
end

function LitsScreen:onNewGame()
    self.board = LitsBoard:new{
        n          = self.plugin:getSetting("grid_n", LitsBoard.DEFAULT_N),
        difficulty = self.plugin:getSetting("difficulty", "easy"),
    }
    self:generateBoard(self.board)
    self.hint_cell = nil
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function LitsScreen:toggleSolution()
    self.board:toggleSolution()
    self.board_widget:refresh()
    self:_updateUndoButton()
    self:updateStatus()
end

function LitsScreen:openSizeMenu()
    local sizes = {}
    for _, n in ipairs(LitsBoard.SIZES) do
        sizes[#sizes + 1] = { id = n, text = n .. "\xC3\x97" .. n }
    end
    MenuHelper.openSizeMenu{
        title     = _("Select size"),
        sizes     = sizes,
        current   = self.plugin:getSetting("grid_n", LitsBoard.DEFAULT_N),
        parent    = self,
        on_select = function(n)
            self.plugin:saveSetting("grid_n", n)
            self:onNewGame()
        end,
    }
end

function LitsScreen:openDifficultyMenu()
    MenuHelper.openDifficultyMenu{
        current   = self.plugin:getSetting("difficulty", "easy"),
        parent    = self,
        on_select = function(id)
            self.plugin:saveSetting("difficulty", id)
            self:onNewGame()
        end,
    }
end

function LitsScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    elseif self.board:isShowingSolution() then
        status = _("Solution is shown; editing is disabled.")
    elseif self.board:isSolved() then
        status = T(_("Solved! Time: %1"), self.board.timer:format())
    else
        local diff = self.board.difficulty
        status = self:joinStatus(
            T("%1×%1", self.board.n),
            MenuHelper.DIFFICULTY_LABELS[diff] or diff,
            T(_("Shaded: %1/%2"), self.board:countShaded(), self.board:totalShaded()))
    end
    ScreenBase.updateStatus(self, status)
end

function LitsScreen:getSizeButtonText()
    return T(_("Size: %1"), self.board.n .. "\xC3\x97" .. self.board.n)
end

function LitsScreen:getDiffButtonText()
    local diff = self.plugin:getSetting("difficulty", "easy")
    return T(_("Difficulty: %1"), MenuHelper.DIFFICULTY_LABELS[diff] or diff)
end

function LitsScreen:getRevealButtonText()
    return self.board:isShowingSolution() and _("Hide solution") or _("Show solution")
end

function LitsScreen:_updateUndoButton()
    if not self.undo_button then return end
    self.undo_button:enableDisable(self.board:canUndo())
end

return LitsScreen
