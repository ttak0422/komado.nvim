local M = {}

local function each_lhs(lhs, fn)
  if type(lhs) == "table" then
    for _, one in ipairs(lhs) do
      if type(one) == "string" then
        fn(one)
      end
    end
  elseif type(lhs) == "string" then
    fn(lhs)
  end
end

local function iter_line_mappings(ctx, fn)
  local mappings = ctx and ctx.mappings
  if type(mappings) ~= "table" then
    return
  end

  for key, spec in pairs(mappings) do
    if type(key) == "table" or type(spec) == "function" or type(spec) == "string" then
      fn(key, spec)
    elseif type(spec) == "table" then
      fn(spec.lhs or key, spec.callback or spec[1])
    end
  end
end

local function find_line_rhs(ctx, lhs)
  local found
  iter_line_mappings(ctx, function(candidate_lhs, rhs)
    if found then
      return
    end
    each_lhs(candidate_lhs, function(one)
      if one == lhs then
        found = rhs
      end
    end)
  end)
  if found then
    return found
  end
  return nil
end

local function invoke_rhs(state, rhs, ctx)
  if type(rhs) == "string" then
    local fn = state.commands[rhs]
    if not fn then
      vim.notify("komado: unknown command " .. rhs, vim.log.levels.WARN)
      return
    end
    fn(state, ctx)
  elseif type(rhs) == "function" then
    rhs(ctx and ctx.self_ref, ctx)
  end
end

local function dispatch_line_mapping(state, lhs, ctx)
  ctx = ctx or state:get_context()
  local rhs = find_line_rhs(ctx, lhs)
  if rhs then
    invoke_rhs(state, rhs, ctx)
  end
end

---Mouse variant of the row-local mapping dispatcher.
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
  dispatch_line_mapping(state, "<LeftMouse>", state.line_meta[row])
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

---Register sidebar-wide mappings and row-local mapping dispatchers on the state's bufnr.
---User setup mappings are registered last and may override row-local dispatch for the same lhs.
---@param state table
function M.attach(state)
  local mappings = state.spec.mappings or {}
  local bufnr = state.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local line_lhs = {}
  for _, ctx in pairs(state.line_meta or {}) do
    iter_line_mappings(ctx, function(lhs, _)
      each_lhs(lhs, function(one)
        line_lhs[one] = true
      end)
    end)
  end

  for lhs, _ in pairs(line_lhs) do
    if lhs == "<LeftMouse>" then
      set_buffer_keymap(state, "n", lhs, function()
        dispatch_select_at_mouse(state)
      end)
    else
      set_buffer_keymap(state, "n", lhs, function()
        dispatch_line_mapping(state, lhs)
      end)
    end
  end

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
