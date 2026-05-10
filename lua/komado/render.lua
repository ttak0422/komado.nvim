local M = {}

local NS = vim.api.nvim_create_namespace("komado")

local function new_buffer(opts)
  opts = opts or {}
  return {
    lines = {},
    extmarks = {}, -- { row, col, end_col, hl }
    line_meta = {}, -- [1-indexed row] = { comp_id, self_ref, ctx }
    vertical_aligns = {}, -- 1-indexed line insertion positions for vertical alignment fillers
    width = opts.width,
    current = nil, -- { text, segs, comp_id, self_ref, ctx }
  }
end

local function new_line(comp_id, self_ref, ctx, on_select)
  return {
    text = "",
    segs = {},
    horizontal_aligns = {}, -- byte positions where horizontal alignment spaces should be inserted
    comp_id = comp_id,
    self_ref = self_ref,
    ctx = ctx,
    on_select = on_select,
  }
end

local function shift_cols(cur, start, amount)
  if amount <= 0 then
    return
  end
  for _, seg in ipairs(cur.segs) do
    if seg.col >= start then
      seg.col = seg.col + amount
      seg.end_col = seg.end_col + amount
    end
  end
end

local function insert_spaces(cur, pos, count)
  if count <= 0 then
    return
  end
  local spaces = string.rep(" ", count)
  cur.text = cur.text:sub(1, pos) .. spaces .. cur.text:sub(pos + 1)
  shift_cols(cur, pos, count)
end

---Distribute `total` units across `positions` and call `place(position, units)` for each.
---Positions are applied right-to-left so earlier inserts don't shift later insertion points.
---Any remainder from integer division is assigned one extra unit to the leading positions.
local function distribute_fill(positions, total, place)
  local n = #positions
  if n == 0 or total <= 0 then
    return
  end
  local base = math.floor(total / n)
  local extra = total % n
  for i = n, 1, -1 do
    local count = base + (i <= extra and 1 or 0)
    place(positions[i], count)
  end
end

local function resolve_horizontal_aligns(buf, cur)
  if not buf.width or buf.width <= 0 then
    return
  end
  local blanks = buf.width - vim.fn.strdisplaywidth(cur.text)
  distribute_fill(cur.horizontal_aligns, blanks, function(pos, count)
    insert_spaces(cur, pos, count)
  end)
end

local function flush(buf)
  local cur = buf.current
  if not cur then
    return
  end
  resolve_horizontal_aligns(buf, cur)
  buf.lines[#buf.lines + 1] = cur.text
  local row = #buf.lines - 1
  for _, seg in ipairs(cur.segs) do
    buf.extmarks[#buf.extmarks + 1] = {
      row = row,
      col = seg.col,
      end_col = seg.end_col,
      hl = seg.hl,
    }
  end
  if cur.comp_id then
    buf.line_meta[row + 1] = {
      comp_id = cur.comp_id,
      self_ref = cur.self_ref,
      ctx = cur.ctx,
      on_select = cur.on_select,
    }
  end
  buf.current = nil
end

local function ensure_current(buf)
  if not buf.current then
    buf.current = new_line()
  end
  return buf.current
end

local function append_segment(buf, seg)
  local cur = ensure_current(buf)
  local start = #cur.text
  cur.text = cur.text .. seg.text
  if seg.hl then
    cur.segs[#cur.segs + 1] = {
      col = start,
      end_col = #cur.text,
      hl = seg.hl,
    }
  end
end

local function shift_rows(buf, start, amount)
  if amount <= 0 then
    return
  end
  for _, m in ipairs(buf.extmarks) do
    if m.row >= start - 1 then
      m.row = m.row + amount
    end
  end

  local shifted = {}
  for row, meta in pairs(buf.line_meta) do
    if row >= start then
      shifted[row + amount] = meta
    else
      shifted[row] = meta
    end
  end
  buf.line_meta = shifted
end

local function insert_blank_lines(buf, pos, count)
  if count <= 0 then
    return
  end
  for _ = 1, count do
    table.insert(buf.lines, pos, "")
  end
  shift_rows(buf, pos, count)
end

local function resolve_vertical_aligns(buf, height)
  if not height or height <= 0 then
    return
  end
  local blanks = height - #buf.lines
  distribute_fill(buf.vertical_aligns, blanks, function(pos, count)
    insert_blank_lines(buf, pos, count)
  end)
end

local function traverse(tree, buf)
  if not tree then
    return
  end
  for _, node in ipairs(tree) do
    if type(node) == "table" then
      if node._komado_open then
        if buf.current then
          flush(buf)
        end
        buf.current = new_line(node.comp, node.self_ref, node.ctx, node.on_select)
      elseif node._komado_close then
        ensure_current(buf)
        flush(buf)
      elseif node._komado_break then
        if buf.current then
          flush(buf)
        end
      elseif node._komado_v_align then
        if buf.current then
          flush(buf)
        end
        buf.vertical_aligns[#buf.vertical_aligns + 1] = #buf.lines + 1
      elseif node._komado_h_align then
        if buf.current then
          buf.current.horizontal_aligns[#buf.current.horizontal_aligns + 1] = #buf.current.text
        end
      elseif node.text ~= nil then
        append_segment(buf, node)
      else
        -- nested array (a child's _tree)
        traverse(node, buf)
      end
    end
  end
end

---Walk the evaluated component tree and produce buffer lines + extmarks + line_meta (row → context for keymap dispatch).
---@param root table top-level component (must have been _eval()'d already)
---@param opts? { height?: integer, width?: integer } target render size; align markers expand to fill remaining cells/rows
---@return string[] lines, table extmarks, table<integer, table> line_meta
function M.collect(root, opts)
  local buf = new_buffer(opts)
  traverse(rawget(root, "_tree"), buf)
  if buf.current then
    flush(buf)
  end
  resolve_vertical_aligns(buf, opts and opts.height)
  return buf.lines, buf.extmarks, buf.line_meta
end

---Apply a render result to the given bufnr, replacing all lines and extmarks.
---Caller is responsible for ensuring the buffer is valid.
---@param bufnr integer
---@param lines string[]
---@param extmarks table[]
function M.flush(bufnr, lines, extmarks)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local prev_modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  for _, m in ipairs(extmarks) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, m.row, m.col, {
      end_col = m.end_col,
      hl_group = m.hl,
    })
  end
  vim.bo[bufnr].modifiable = prev_modifiable
end

function M.namespace()
  return NS
end

return M
