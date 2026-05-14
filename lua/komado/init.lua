local config = require("komado.config")
local state_m = require("komado.state")
local Sidebar = require("komado.sidebar")
local buffer_m = require("komado.buffer")
local window_m = require("komado.window")
local keymap_m = require("komado.keymap")
local render = require("komado.render")
local events = require("komado.events")

local M = {}

local sidebar -- single Sidebar instance, shared across tabs
local LIFECYCLE_AUGROUP = "Komado_lifecycle"

---Fire a `User` autocmd with komado-specific pattern.
---Users can listen via `vim.api.nvim_create_autocmd("User", { pattern = "KomadoWindowAfterOpen", ... })`.
---@param pattern string
---@param data table
local function fire(pattern, data)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = pattern,
    modeline = false,
    data = data,
  })
end

local function ensure_lifecycle_autocmds()
  vim.api.nvim_create_augroup(LIFECYCLE_AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = LIFECYCLE_AUGROUP,
    callback = function()
      -- TabClosed.args.match is "<tabnr>" (1-indexed), but we key on tabid (handle).
      -- After close that mapping isn't recoverable, so just walk live tabs and dispose anything that's no longer in the list.
      local valid = {}
      for _, t in ipairs(vim.api.nvim_list_tabpages()) do
        valid[t] = true
      end
      state_m.foreach(function(tabid, st)
        if not valid[tabid] then
          window_m.close(st)
          buffer_m.delete(st)
          state_m.dispose(tabid)
        end
      end)
    end,
  })
  -- Re-fit ratio-based sidebars when the outer editor is resized.
  vim.api.nvim_create_autocmd("VimResized", {
    group = LIFECYCLE_AUGROUP,
    callback = function()
      state_m.foreach(function(_, st)
        window_m.refit(st)
      end)
    end,
  })
end

---@param opts table  { window, buffer, mappings, commands, root }
function M.setup(opts)
  -- Tear down any prior instance: close all open sidebar windows / buffers and drop registered update autocmds.
  -- Otherwise repeated `setup` calls (lazy reload, :luafile %, plugin manager re-source) would leak orphans.
  if sidebar then
    local tabids = {}
    state_m.foreach(function(tabid, _)
      tabids[#tabids + 1] = tabid
    end)
    for _, tabid in ipairs(tabids) do
      M.close({ tabid = tabid })
    end
  end
  events.clear_augroup()
  state_m._reset()
  sidebar = nil

  local spec = config.normalize(opts)
  state_m.register(spec)

  sidebar = Sidebar.new(spec)
  sidebar._on_update = function()
    vim.schedule(function()
      for _, tabid in ipairs(vim.api.nvim_list_tabpages()) do
        local st = state_m.get(tabid)
        if st and st.bufnr and vim.api.nvim_buf_is_valid(st.bufnr) then
          M.redraw(tabid)
        end
      end
    end)
  end

  ensure_lifecycle_autocmds()
end

---Render the sidebar for the current tab, creating the buffer/window if needed.
---`open` is intentionally restricted to the current tab: opening a sidebar on a different tab while the user is sitting elsewhere would create a window outside the actual target.
---Use `redraw(tabid)` / `close({ tabid = ... })` for cross-tab operations instead.
---@param open_opts? { focus?: boolean }
function M.open(open_opts)
  open_opts = open_opts or {}
  if not sidebar then
    error("komado: sidebar not configured (call komado.setup first)")
  end
  local tabid = vim.api.nvim_get_current_tabpage()
  local state = state_m.get_or_create(tabid)

  local prior_win = vim.api.nvim_get_current_win()

  local bufnr = buffer_m.get_or_create(state)
  local opened_now = false
  if not window_m.is_open(state) then
    fire("KomadoWindowBeforeOpen", { tabid = tabid, bufnr = bufnr })
    window_m.open(state, bufnr)
    opened_now = true
  end

  -- Remember the user's "home" window so subsequent redraws (especially the ones triggered by autocmds while the user is on a different tab) can evaluate providers in that window's context via nvim_win_call.
  if prior_win and prior_win ~= state.winid and vim.api.nvim_win_is_valid(prior_win) then
    state.prior_win = prior_win
  end

  -- Restore focus to the user's window *before* the first render so providers that read `vim.bo.*` / `vim.fn.bufname()` see the user's buffer rather than the sidebar buffer they were just dropped into.
  if not open_opts.focus and prior_win then
    if prior_win ~= state.winid and vim.api.nvim_win_is_valid(prior_win) then
      vim.api.nvim_set_current_win(prior_win)
    end
  end

  M.redraw(tabid)

  if opened_now then
    local cursor = state_m.recall_cursor(tabid)
    if cursor and vim.api.nvim_win_is_valid(state.winid) then
      pcall(vim.api.nvim_win_set_cursor, state.winid, cursor)
    end
    fire("KomadoWindowAfterOpen", {
      tabid = tabid,
      bufnr = bufnr,
      winid = state.winid,
    })
  end
  return state
end

---Close the window and dispose the buffer for the current (or given) tab.
---@param close_opts? { tabid?: integer, keep_buffer?: boolean }
function M.close(close_opts)
  close_opts = close_opts or {}
  local tabid = close_opts.tabid or vim.api.nvim_get_current_tabpage()
  local state = state_m.get(tabid)
  if not state then
    return
  end
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, state.winid)
    if ok then
      state_m.save_cursor(tabid, cursor)
    end
  end
  fire("KomadoWindowBeforeClose", {
    tabid = tabid,
    bufnr = state.bufnr,
    winid = state.winid,
  })
  window_m.close(state)
  if not close_opts.keep_buffer then
    buffer_m.delete(state)
    state_m.dispose(tabid)
  end
  fire("KomadoWindowAfterClose", { tabid = tabid })
end

---@param toggle_opts? { focus?: boolean }
function M.toggle(toggle_opts)
  toggle_opts = toggle_opts or {}
  local tabid = vim.api.nvim_get_current_tabpage()
  local state = state_m.get(tabid)
  if state and window_m.is_open(state) then
    M.close({ tabid = tabid })
  else
    M.open({ focus = toggle_opts.focus })
  end
end

---Pick the window whose buffer should drive provider evaluation for `state`.
---Resolution order:
---  1. current tab → user's current non-sidebar window (and remember it as `state.prior_win` so a later non-current redraw reuses it)
---  2. non-current tab → that tab's most recently active window via `nvim_tabpage_get_win`, unless it points at the sidebar itself
---  3. saved `state.prior_win`, if it still belongs to the target tab
---  4. any other non-sidebar window in the target tab (last resort)
local function find_provider_win(state, tabid)
  if tabid == vim.api.nvim_get_current_tabpage() then
    local cur = vim.api.nvim_get_current_win()
    if cur ~= state.winid and vim.api.nvim_win_is_valid(cur) then
      -- Persist so subsequent redraws of *this* tab from another tab still evaluate against the user's actual home window.
      state.prior_win = cur
      return cur
    end
  else
    local recent = vim.api.nvim_tabpage_get_win(tabid)
    if recent ~= state.winid and vim.api.nvim_win_is_valid(recent) then
      return recent
    end
  end
  if state.prior_win and vim.api.nvim_win_is_valid(state.prior_win) then
    local ok, owner = pcall(vim.api.nvim_win_get_tabpage, state.prior_win)
    if ok and owner == tabid and state.prior_win ~= state.winid then
      return state.prior_win
    end
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tabid)) do
    if w ~= state.winid and vim.api.nvim_win_is_valid(w) then
      return w
    end
  end
  return nil
end

---Re-evaluate the component tree and write the result to the buffer.
---No-op if the state has no buffer yet.
---@param tabid? integer
function M.redraw(tabid)
  tabid = tabid or vim.api.nvim_get_current_tabpage()
  local state = state_m.get(tabid)
  if not sidebar or not state or not state.bufnr then
    return
  end
  if not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end
  fire("KomadoRenderPre", { tabid = tabid, bufnr = state.bufnr })

  -- Evaluate providers in the tab's "current non-sidebar" window so reads of `vim.bo.*` / `vim.fn.bufname("%")` follow the user's split focus and the right tab.
  -- nvim_win_call avoids firing TabEnter/Leave autocmds.
  local lines, extmarks, line_meta
  local function do_eval()
    lines, extmarks, line_meta = sidebar:eval(state)
  end
  local target = find_provider_win(state, tabid)
  if target then
    vim.api.nvim_win_call(target, do_eval)
  else
    do_eval()
  end

  state.line_meta = line_meta
  render.flush(state.bufnr, lines, extmarks)
  keymap_m.attach(state)
  fire("KomadoRenderPost", {
    tabid = tabid,
    bufnr = state.bufnr,
    n_lines = #lines,
  })
end

---@param tabid? integer
---@return table?
function M.get_state(tabid)
  return state_m.get(tabid)
end

return M
