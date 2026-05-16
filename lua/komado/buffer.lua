local M = {}

local function apply_buf_options(bufnr)
  local bo = vim.bo[bufnr]
  bo.buftype = "nofile"
  bo.bufhidden = "hide"
  bo.swapfile = false
  bo.modifiable = false
  bo.modeline = false
  bo.buflisted = false
  bo.filetype = "komado"
end

---Return the state's scratch buffer, creating it when missing or invalid.
---@param state table
---@return integer bufnr
function M.get_or_create(state)
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    return state.bufnr
  end

  local bufnr = vim.api.nvim_create_buf(false, true)

  apply_buf_options(bufnr)

  local bufname = string.format("komado://#tab%d", state.tabid)
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
