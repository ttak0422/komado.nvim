local M = {}

local function apply_buf_options(bufnr, buf_opts)
  local bo = vim.bo[bufnr]
  bo.buftype = "nofile"
  bo.bufhidden = "hide"
  bo.swapfile = false
  bo.modifiable = false
  bo.modeline = false
  bo.buflisted = false
  if buf_opts.filetype then
    bo.filetype = buf_opts.filetype
  end
end

---Return the state's scratch buffer, creating it when missing or invalid.
---@param state table
---@return integer bufnr
function M.get_or_create(state)
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    return state.bufnr
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  local buf_opts = state.spec.buffer or {}

  apply_buf_options(bufnr, buf_opts)

  local base = buf_opts.name or "komado://"
  local bufname = string.format("%s#tab%d", base, state.tabid)
  pcall(vim.api.nvim_buf_set_name, bufnr, bufname)

  state.bufnr = bufnr
  return bufnr
end

---Delete the buffer associated with the given state, if any.
---@param state table
function M.delete(state)
  local bufnr = state.bufnr
  state.bufnr = nil
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

return M
