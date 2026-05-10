local M = {}

---Mark a component as a line. Children of a Line render as horizontal segments.
---@generic T: table
---@param spec T
---@return T
function M.Line(spec)
  spec = spec or {}
  spec._kind = "line"
  return spec
end

return M
