local M = {}
local state_m = require("komado.state")

local function is_editor(winid, tabid, sidebar_buf, incoming_buf)
  if not winid or not vim.api.nvim_win_is_valid(winid) or vim.api.nvim_win_get_tabpage(winid) ~= tabid then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(winid)
  local config = vim.api.nvim_win_get_config(winid)
  return buf ~= sidebar_buf
    and vim.bo[buf].buftype == ""
    and (not vim.bo[buf].modified or buf == incoming_buf)
    and config.relative == ""
    and not config.external
    and not vim.wo[winid].previewwindow
    and (vim.fn.exists("+winfixbuf") == 0 or not vim.wo[winid].winfixbuf)
end

---Move a buffer opened in the owned sidebar window into an editing window.
---Run after the opener finishes so its cursor/view changes travel with the buffer.
function M.restore_buffer(state, prior_win)
  local winid, sidebar_buf = state.winid, state.bufnr
  if
    not winid
    or not vim.api.nvim_win_is_valid(winid)
    or not sidebar_buf
    or not vim.api.nvim_buf_is_valid(sidebar_buf)
  then
    return
  end
  local buf = vim.api.nvim_win_get_buf(winid)
  if buf == sidebar_buf then
    return
  end

  local tabid = vim.api.nvim_win_get_tabpage(winid)
  local focused = vim.api.nvim_get_current_win() == winid
  local view = vim.api.nvim_win_call(winid, vim.fn.winsaveview)
  local target = prior_win or state_m.get_prior_win(tabid)
  if target == winid or not is_editor(target, tabid, sidebar_buf, buf) then
    target = nil
    for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(tabid)) do
      if candidate ~= winid and is_editor(candidate, tabid, sidebar_buf, buf) then
        target = candidate
        break
      end
    end
  end
  if not target then
    vim.api.nvim_win_call(winid, function()
      local side = state.spec.window.position == "right" and "leftabove" or "rightbelow"
      vim.cmd(side .. " vnew")
      target = vim.api.nvim_get_current_win()
    end)
    M.refit(state)
  end

  -- Keep even bufhidden=wipe buffers displayed while restoring the sidebar.
  vim.api.nvim_win_set_buf(target, buf)
  vim.api.nvim_win_call(target, function()
    vim.fn.winrestview(view)
  end)
  vim.api.nvim_win_set_buf(winid, sidebar_buf)
  state_m.set_prior_win(tabid, target)
  if focused then
    vim.api.nvim_set_current_win(target)
  end
end

local function apply_win_options(winid)
  local wo = vim.wo[winid]
  wo.number = false
  wo.relativenumber = false
  wo.wrap = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.list = false
  wo.spell = false
  wo.cursorline = true
  -- Keep the current width during equalization; explicit resizing still works.
  wo.winfixwidth = true
end

---Resolve a normalized `size` table into the integer column count to apply.
---Either `columns` or `ratio` is the base value (config.normalize guarantees exactly one is set); `min` / `max` clamp the result.
---@param size { columns?: number, ratio?: number, min?: number, max?: number }
---@return integer
function M.resolve_width(size)
  size = size or {}
  local base
  if size.ratio then
    base = math.floor(vim.o.columns * size.ratio)
  else
    base = size.columns or 40
  end
  if size.min then
    base = math.max(base, size.min)
  end
  if size.max then
    base = math.min(base, size.max)
  end
  return math.max(1, math.floor(base))
end

---Open the sidebar window for `state` as a vertical split on the left or right and return the resulting winid.
---@param state table
---@param bufnr integer
---@return integer winid
function M.open(state, bufnr)
  local win_opts = state.spec.window or {}
  local size = M.resolve_width(win_opts.size)
  local cmd
  if win_opts.position == "right" then
    cmd = string.format("botright %dvsplit", size)
  else
    cmd = string.format("topleft %dvsplit", size)
  end
  vim.cmd(cmd)
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  apply_win_options(winid)
  state.winid = winid
  return winid
end

---Re-apply the configured size to an already-open sidebar.
---Used by VimResized so ratio-driven layouts follow the new editor width.
---@param state table
function M.refit(state)
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return
  end
  local target = M.resolve_width((state.spec.window or {}).size)
  pcall(vim.api.nvim_win_set_width, state.winid, target)
end

---Close the window owned by the state, if any.
---Buffer is NOT deleted here; callers control buffer lifetime via buffer.delete.
---@param state table
function M.close(state)
  local winid = state.winid
  state.winid = nil
  if winid and vim.api.nvim_win_is_valid(winid) then
    pcall(vim.api.nvim_win_close, winid, true)
  end
end

function M.is_open(state)
  return state.winid ~= nil and vim.api.nvim_win_is_valid(state.winid)
end

return M
