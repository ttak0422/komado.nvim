local M = {}

local function invoke_on_select(ctx)
  if ctx and type(ctx.on_select) == "function" then
    ctx.on_select(ctx.self_ref, ctx)
  end
end

---Default mapping invoked by `<CR>`.
---Looks up the row's `on_select` (set on its owning Line component) and runs it.
---User mappings registered after the defaults can override the same lhs.
local function dispatch_select(state)
  invoke_on_select(state:get_context())
end

---Mouse variant of dispatch_select.
---Bound to `<LeftMouse>` so the action fires at button-down time (matching common UI expectations) rather than on release.
---Because mapping `<LeftMouse>` steals Neovim's default "cursor-to-click" behaviour, we recover the click target via `vim.fn.getmousepos()` and move the cursor explicitly for visual feedback.
local function dispatch_select_at_mouse(state)
  local mp = vim.fn.getmousepos()
  if not mp or mp.winid ~= state.winid then
    return
  end
  local row = mp.line
  if not row or row < 1 then
    return
  end
  pcall(vim.api.nvim_win_set_cursor, state.winid, { row, 0 })
  invoke_on_select(state.line_meta[row])
end

local function collect_visual_rows()
  local s = vim.fn.getpos("v")[2]
  local e = vim.fn.getpos(".")[2]
  if s > e then
    s, e = e, s
  end
  local rows = {}
  for r = s, e do
    rows[#rows + 1] = r
  end
  return rows
end

local function gather_contexts(state, rows)
  local ctxs = {}
  for _, r in ipairs(rows) do
    local c = state.line_meta[r]
    if c then
      ctxs[#ctxs + 1] = c
    end
  end
  return ctxs
end

local function build_normal_handler(state, rhs)
  if type(rhs) == "string" then
    return function()
      local fn = state.commands[rhs]
      if not fn then
        vim.notify("komado: unknown command " .. rhs, vim.log.levels.WARN)
        return
      end
      fn(state, state:get_context())
    end
  elseif type(rhs) == "function" then
    return function()
      rhs(state, state:get_context())
    end
  end
end

local function build_visual_handler(state, rhs)
  -- Visual variant: only string commands with a `<name>_visual` companion are promoted to visual mode.
  -- Function rhs values stay normal-only — users can always opt in by passing a string command name.
  if type(rhs) ~= "string" then
    return nil
  end
  local v_fn = state.commands[rhs .. "_visual"]
  if type(v_fn) ~= "function" then
    return nil
  end
  return function()
    local rows = collect_visual_rows()
    -- Leave visual mode before invoking the handler so the user's command can safely move the cursor / open windows without interference.
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    vim.schedule(function()
      v_fn(state, gather_contexts(state, rows))
    end)
  end
end

local function set_buffer_keymap(state, mode, lhs, rhs, suffix)
  vim.keymap.set(mode, lhs, rhs, {
    buffer = state.bufnr,
    nowait = true,
    silent = true,
    desc = "komado " .. lhs .. (suffix or ""),
  })
end

---Register the user's mappings on the state's bufnr.
---`<CR>` and `<LeftMouse>` are pre-mapped to dispatch the row's `on_select`; user mappings override them by reusing the same lhs.
---@param state table
function M.attach(state)
  local mappings = state.spec.mappings or {}
  local bufnr = state.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Defaults first; user mappings may overwrite either lhs.
  set_buffer_keymap(state, "n", "<CR>", function()
    dispatch_select(state)
  end)
  set_buffer_keymap(state, "n", "<LeftMouse>", function()
    dispatch_select_at_mouse(state)
  end)

  for lhs, rhs in pairs(mappings) do
    local n_handler = build_normal_handler(state, rhs)
    if n_handler then
      set_buffer_keymap(state, "n", lhs, n_handler)
    end
    local v_handler = build_visual_handler(state, rhs)
    if v_handler then
      set_buffer_keymap(state, "x", lhs, v_handler, " (visual)")
    end
  end
end

return M
