local M = {}

local hl_mod = require("komado.highlights")

local NS = vim.api.nvim_create_namespace("komado")
local snapshots = {} -- bufnr -> { lines = string[], extmarks = table[] }

local function new_buffer(opts)
  opts = opts or {}
  return {
    lines = {},
    extmarks = {}, -- { row, col, end_col, hl }
    line_meta = {}, -- [1-indexed row] = { comp_id, self_ref, ctx }
    vertical_aligns = {}, -- 1-indexed line insertion positions for vertical alignment fillers
    width = opts.width,
    padding_left = opts.padding_left or 0,
    current = nil, -- { text, segs, comp_id, self_ref, ctx }
  }
end

local function new_line(comp_id, self_ref, ctx, mappings)
  return {
    text = "",
    segs = {},
    horizontal_aligns = {}, -- byte positions where horizontal alignment spaces should be inserted
    horizontal_center = false,
    comp_id = comp_id,
    self_ref = self_ref,
    ctx = ctx,
    mappings = mappings,
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

local function resolve_horizontal_center(buf, cur)
  if not cur.horizontal_center or not buf.width or buf.width <= 0 then
    return
  end
  local blanks = buf.width - vim.fn.strdisplaywidth(cur.text)
  if blanks <= 0 then
    return
  end
  insert_spaces(cur, 0, math.floor(blanks / 2))
end

local function flush(buf)
  local cur = buf.current
  if not cur then
    return
  end
  resolve_horizontal_aligns(buf, cur)
  resolve_horizontal_center(buf, cur)
  insert_spaces(cur, 0, buf.padding_left)
  buf.lines[#buf.lines + 1] = cur.text
  local row = #buf.lines - 1
  for _, seg in ipairs(cur.segs) do
    if seg.hl then
      buf.extmarks[#buf.extmarks + 1] = {
        row = row,
        col = seg.col,
        end_col = seg.end_col,
        hl = seg.hl,
      }
    end
  end
  if cur.comp_id then
    local segments = {}
    for _, seg in ipairs(cur.segs) do
      segments[#segments + 1] = {
        col = seg.col,
        end_col = seg.end_col,
        comp_id = seg.comp_id,
        self_ref = seg.self_ref,
        ctx = seg.ctx,
        mappings = seg.mappings,
      }
    end
    buf.line_meta[row + 1] = {
      comp_id = cur.comp_id,
      self_ref = cur.self_ref,
      ctx = cur.ctx,
      mappings = cur.mappings,
      segments = segments,
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
  local hl = seg.hl
  if type(hl) == "table" then
    hl = hl_mod.ensure_hl_group(hl)
  end
  cur.segs[#cur.segs + 1] = {
    col = start,
    end_col = #cur.text,
    hl = hl,
    comp_id = seg.comp,
    self_ref = seg.self_ref,
    ctx = seg.ctx,
    mappings = seg.mappings,
  }
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
        buf.current = new_line(node.comp, node.self_ref, node.ctx, node.mappings)
        buf.current.horizontal_center = node.horizontal_center
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

local function set_extmark(bufnr, m)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, m.row, m.col, {
    end_col = m.end_col,
    hl_group = m.hl,
  })
end

local function set_extmarks_in_range(bufnr, extmarks, start_row, end_row)
  if start_row >= end_row then
    return
  end
  for _, m in ipairs(extmarks) do
    if m.row >= start_row and m.row < end_row then
      set_extmark(bufnr, m)
    end
  end
end

local function extmark_row_keys(extmarks)
  local rows = {}
  for _, m in ipairs(extmarks) do
    local key = table.concat({ m.col, m.end_col, m.hl }, "\31")
    rows[m.row] = rows[m.row] and (rows[m.row] .. "\30" .. key) or key
  end
  return rows
end

local function changed_extmark_rows(prev_extmarks, extmarks, line_count, old_start, old_end, new_end)
  local old_rows = extmark_row_keys(prev_extmarks)
  local new_rows = extmark_row_keys(extmarks)
  local delta = new_end - old_end
  local rows = {}

  for new_row = 0, line_count - 1 do
    if not (new_row >= old_start and new_row < new_end) then
      local old_row = new_row
      if new_row >= new_end then
        old_row = new_row - delta
      end
      if old_rows[old_row] ~= new_rows[new_row] then
        rows[#rows + 1] = new_row
      end
    end
  end

  return rows
end

local function full_flush(bufnr, lines, extmarks)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  for _, m in ipairs(extmarks) do
    set_extmark(bufnr, m)
  end
end

---Apply a render result to the given bufnr.
---After the initial full render, only changed line ranges and highlight rows are updated.
---Caller is responsible for ensuring the buffer is valid.
---@param bufnr integer
---@param lines string[]
---@param extmarks table[]
function M.flush(bufnr, lines, extmarks)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    snapshots[bufnr] = nil
    return
  end

  local prev = snapshots[bufnr]
  if not prev or vim.api.nvim_buf_line_count(bufnr) ~= #prev.lines then
    local prev_modifiable = vim.bo[bufnr].modifiable
    vim.bo[bufnr].modifiable = true
    full_flush(bufnr, lines, extmarks)
    vim.bo[bufnr].modifiable = prev_modifiable
    snapshots[bufnr] = { lines = lines, extmarks = extmarks }
    return
  end

  local old_lines = prev.lines
  local old_len = #old_lines
  local new_len = #lines
  local prefix = 0
  while prefix < old_len and prefix < new_len and old_lines[prefix + 1] == lines[prefix + 1] do
    prefix = prefix + 1
  end

  local suffix = 0
  while
    suffix < old_len - prefix
    and suffix < new_len - prefix
    and old_lines[old_len - suffix] == lines[new_len - suffix]
  do
    suffix = suffix + 1
  end

  local old_start = prefix
  local old_end = old_len - suffix
  local new_end = new_len - suffix
  local line_changed = old_start ~= old_end or old_start ~= new_end
  local extra_rows = changed_extmark_rows(prev.extmarks, extmarks, #lines, old_start, old_end, new_end)

  if not line_changed and #extra_rows == 0 then
    snapshots[bufnr] = { lines = lines, extmarks = extmarks }
    return
  end

  if line_changed and old_start < old_end then
    vim.api.nvim_buf_clear_namespace(bufnr, NS, old_start, old_end)
  end

  if line_changed then
    local replacement = {}
    for i = old_start + 1, new_end do
      replacement[#replacement + 1] = lines[i]
    end
    local prev_modifiable = vim.bo[bufnr].modifiable
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, old_start, old_end, false, replacement)
    vim.bo[bufnr].modifiable = prev_modifiable
  end

  if line_changed then
    set_extmarks_in_range(bufnr, extmarks, old_start, new_end)
  end

  for _, row in ipairs(extra_rows) do
    vim.api.nvim_buf_clear_namespace(bufnr, NS, row, row + 1)
    set_extmarks_in_range(bufnr, extmarks, row, row + 1)
  end

  snapshots[bufnr] = { lines = lines, extmarks = extmarks }
end

function M.namespace()
  return NS
end

return M
