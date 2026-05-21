local config = require("komado.config")
local state_m = require("komado.state")
local Sidebar = require("komado.sidebar")
local buffer_m = require("komado.buffer")
local window_m = require("komado.window")
local keymap_m = require("komado.keymap")
local render = require("komado.render")
local events = require("komado.events")
local highlights = require("komado.highlights")

local M = {}

local sidebar -- single Sidebar instance, shared across tabs
local LIFECYCLE_AUGROUP = "Komado_lifecycle"
local redraw_pending = false

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

local function schedule_redraw()
  if redraw_pending then
    return
  end
  redraw_pending = true
  vim.schedule(function()
    redraw_pending = false
    local st = state_m.get()
    if st and st.bufnr and vim.api.nvim_buf_is_valid(st.bufnr) then
      M.redraw()
    end
  end)
end

---Open the sidebar window in the current tab using the singleton buffer.
---Shared by user-initiated `M.open` and the TabEnter auto-reattach. `silent = true` skips KomadoWindow* events to avoid spamming listeners on every tab switch.
---@param state table
---@param opts { focus?: boolean, silent?: boolean }
local function attach_window_in_current_tab(state, opts)
  local prior_win = vim.api.nvim_get_current_win()
  local bufnr = buffer_m.get_or_create(state)
  local opened_now = false
  if not window_m.is_open(state) then
    if not opts.silent then
      fire("KomadoWindowBeforeOpen", { bufnr = bufnr })
    end
    window_m.open(state, bufnr)
    opened_now = true
  end

  local tabid = vim.api.nvim_get_current_tabpage()
  if prior_win and prior_win ~= state.winid and vim.api.nvim_win_is_valid(prior_win) then
    state_m.set_prior_win(tabid, prior_win)
  end

  if not opts.focus and prior_win then
    if prior_win ~= state.winid and vim.api.nvim_win_is_valid(prior_win) then
      vim.api.nvim_set_current_win(prior_win)
    end
  end

  M.redraw()

  if opened_now then
    local cursor = state_m.recall_cursor(tabid)
    if cursor and vim.api.nvim_win_is_valid(state.winid) then
      pcall(vim.api.nvim_win_set_cursor, state.winid, cursor)
    end
    if not opts.silent then
      fire("KomadoWindowAfterOpen", { bufnr = bufnr, winid = state.winid })
    end
  end
end

---Save the leaving tab's cursor and close the sidebar window. Buffer + is_open flag are untouched so TabEnter can reattach.
local function detach_window_for_tab_leave()
  local st = state_m.get()
  if not st or not st.winid then
    return
  end
  if vim.api.nvim_win_is_valid(st.winid) then
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, st.winid)
    if ok then
      state_m.save_cursor(vim.api.nvim_get_current_tabpage(), cursor)
    end
  end
  window_m.close(st)
end

local function reattach_window_for_tab_enter()
  if not state_m.is_open() then
    return
  end
  local st = state_m.get_or_create()
  attach_window_in_current_tab(st, { silent = true })
end

local function ensure_lifecycle_autocmds()
  vim.api.nvim_create_augroup(LIFECYCLE_AUGROUP, { clear = true })

  vim.api.nvim_create_autocmd("TabClosed", {
    group = LIFECYCLE_AUGROUP,
    callback = function()
      local live = {}
      for _, t in ipairs(vim.api.nvim_list_tabpages()) do
        live[t] = true
      end
      state_m.gc_tabs(live)
    end,
  })

  -- Re-fit ratio-based sidebars when the outer editor is resized.
  vim.api.nvim_create_autocmd("VimResized", {
    group = LIFECYCLE_AUGROUP,
    callback = function()
      local st = state_m.get()
      if st then
        window_m.refit(st)
      end
      schedule_redraw()
    end,
  })

  vim.api.nvim_create_autocmd("WinResized", {
    group = LIFECYCLE_AUGROUP,
    callback = schedule_redraw,
  })

  vim.api.nvim_create_autocmd("TabLeave", {
    group = LIFECYCLE_AUGROUP,
    callback = detach_window_for_tab_leave,
  })

  vim.api.nvim_create_autocmd("TabEnter", {
    group = LIFECYCLE_AUGROUP,
    callback = reattach_window_for_tab_enter,
  })

  -- A colorscheme reload clears every generated Komado_hl_* group. Drop the
  -- cache so the next render re-issues nvim_set_hl for inline-hl components.
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = LIFECYCLE_AUGROUP,
    callback = function()
      highlights.invalidate()
      schedule_redraw()
    end,
  })
end

---@param opts table  { window, buffer, mappings, commands, root }
function M.setup(opts)
  -- Tear down any prior instance so repeat setup (lazy reload, :luafile %, plugin manager re-source) does not leak the existing window/buffer/autocmds.
  if sidebar then
    M.close()
  end
  events.clear_augroup()
  state_m._reset()
  sidebar = nil

  local spec = config.normalize(opts)
  state_m.register(spec)

  sidebar = Sidebar.new(spec)
  sidebar._on_update = schedule_redraw

  ensure_lifecycle_autocmds()
end

---Open the singleton sidebar in the current tab and mark it as "logically open" so subsequent TabEnter events re-attach it automatically.
---@param open_opts? { focus?: boolean }
function M.open(open_opts)
  open_opts = open_opts or {}
  if not sidebar then
    error("komado: sidebar not configured (call komado.setup first)")
  end
  local state = state_m.get_or_create()
  state_m.set_open(true)
  attach_window_in_current_tab(state, { focus = open_opts.focus, silent = false })
  return state
end

---Close the sidebar globally: tear down the current tab's window, drop the buffer, and clear is_open so TabEnter no longer auto-attaches.
---@param close_opts? { keep_buffer?: boolean }
function M.close(close_opts)
  close_opts = close_opts or {}
  local state = state_m.get()
  if not state then
    state_m.set_open(false)
    return
  end
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, state.winid)
    if ok then
      state_m.save_cursor(vim.api.nvim_get_current_tabpage(), cursor)
    end
  end
  fire("KomadoWindowBeforeClose", { bufnr = state.bufnr, winid = state.winid })
  window_m.close(state)
  if not close_opts.keep_buffer then
    buffer_m.delete(state)
    state_m.dispose()
  end
  state_m.set_open(false)
  fire("KomadoWindowAfterClose", {})
end

---@param toggle_opts? { focus?: boolean }
function M.toggle(toggle_opts)
  toggle_opts = toggle_opts or {}
  local state = state_m.get()
  if state and window_m.is_open(state) then
    M.close()
  else
    M.open({ focus = toggle_opts.focus })
  end
end

---Pick the window whose buffer should drive provider evaluation for the singleton state.
---Resolution order (within the current tab):
---  1. user's current non-sidebar window — also memoized as that tab's prior_win
---  2. the tab's saved prior_win, if still valid and in this tab
---  3. any non-sidebar window in the current tab (last resort)
local function find_provider_win(state)
  local tabid = vim.api.nvim_get_current_tabpage()
  local cur = vim.api.nvim_get_current_win()
  if cur ~= state.winid and vim.api.nvim_win_is_valid(cur) then
    state_m.set_prior_win(tabid, cur)
    return cur
  end
  local saved = state_m.get_prior_win(tabid)
  if saved and vim.api.nvim_win_is_valid(saved) then
    local ok, owner = pcall(vim.api.nvim_win_get_tabpage, saved)
    if ok and owner == tabid and saved ~= state.winid then
      return saved
    end
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tabid)) do
    if w ~= state.winid and vim.api.nvim_win_is_valid(w) then
      return w
    end
  end
  return nil
end

---Re-evaluate the component tree against the current tab and write the result to the singleton buffer.
function M.redraw()
  local state = state_m.get()
  if not sidebar or not state or not state.bufnr then
    return
  end
  if not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end
  fire("KomadoRenderPre", { bufnr = state.bufnr })

  -- Evaluate providers in the current tab's "user" window so reads of `vim.bo.*` / `vim.fn.bufname("%")` reflect the user's split focus, not the sidebar buffer.
  -- nvim_win_call avoids firing TabEnter/Leave autocmds.
  local lines, extmarks, line_meta
  local function do_eval()
    lines, extmarks, line_meta = sidebar:eval(state)
  end
  local target = find_provider_win(state)
  if target then
    vim.api.nvim_win_call(target, do_eval)
  else
    do_eval()
  end

  state.line_meta = line_meta
  render.flush(state.bufnr, lines, extmarks)
  keymap_m.attach(state)
  fire("KomadoRenderPost", {
    bufnr = state.bufnr,
    n_lines = #lines,
  })
end

---@return table?
function M.get_state()
  return state_m.get()
end

return M
