local inc_rename = require("inc_rename")
local ns = vim.api.nvim_create_namespace("inc_rename_test")

local function set_buf_lines(bufnr, lines)
  vim.api.nvim_buf_call(bufnr, function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  end)
end

local function get_buf_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function get_hl_positions_for_line(bufnr, line_nr, hl_group)
  assert(line_nr >= 1)
  local positions = {}
  local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true, type = "highlight" })
  for _, extmark in ipairs(extmarks) do
    local line_idx, col_idx, details = extmark[2], extmark[3], extmark[4]
    if line_idx == line_nr - 1 and details["hl_group"] == hl_group then
      table.insert(positions, { line_idx = line_idx, start_col_idx = col_idx, end_col_idx = details.end_col })
    end
  end
  return positions
end

local function assert_line_hls_match(expected_hls, actual_hl_positions)
  assert(type(expected_hls) == "string")
  for i = 1, #expected_hls do
    local char = expected_hls:sub(i, i)
    local got_hl_at_position = vim.iter(actual_hl_positions):any(function(hl_pos)
      return hl_pos.start_col_idx <= i - 1 and i - 1 < hl_pos.end_col_idx
    end)
    if char == "~" then
      assert.is_true(got_hl_at_position, "Expected highlight at position " .. i)
    else
      assert.is_false(got_hl_at_position, "Expected no highlight at position " .. i .. vim.inspect(actual_hl_positions))
    end
  end
end

local function make_line_info(start_col, end_col, line, is_visible)
  local visible = is_visible == nil and true or is_visible
  return { start_col = start_col, end_col = end_col, is_visible = visible, text = line }
end

local function test_rename_and_highlight(before, new_name, line_infos, expected_lines, expected_hls)
  set_buf_lines(0, before)
  local preview_fn_args = { new_name = new_name, preview_ns = ns }
  assert.are_same(#expected_lines, #line_infos)
  for line_nr, line_infos_per_line_nr in pairs(line_infos) do
    assert(line_nr >= 1)
    inc_rename._apply_highlights_fn(0, line_nr - 1, line_infos_per_line_nr, preview_fn_args)
    assert.are_same(expected_lines[line_nr], get_buf_lines(0)[line_nr])
  end
  assert.are_same(#line_infos, #expected_hls)
  for line_nr, expected_hls_per_line in pairs(expected_hls) do
    local actual_hls = get_hl_positions_for_line(0, line_nr, "Substitute")
    assert_line_hls_match(expected_hls_per_line, actual_hls)
  end
end

local function test_rename_and_highlight_with_preview_buf(
  buf_name,
  buf_is_visible,
  before,
  new_name,
  line_infos,
  expected_lines,
  expected_hls,
  expected_preview_buf_lines,
  expected_preview_hls
)
  set_buf_lines(0, before)
  local preview_fn_args = { new_name = new_name, preview_ns = ns }
  vim.api.nvim_buf_set_name(0, buf_name)
  local preview_buf = vim.api.nvim_create_buf(false, true)
  assert(preview_buf > 0)
  local preview_buf_infos = vim.defaulttable()
  assert.are_same(#expected_lines, #line_infos)
  for line_nr, line_infos_per_line_nr in pairs(line_infos) do
    assert(line_nr >= 1)
    line_infos_per_line_nr.bufnr = 0
    inc_rename._apply_highlights_fn_with_preview_buf(
      0,
      buf_is_visible,
      preview_buf,
      preview_buf_infos,
      line_nr - 1,
      line_infos_per_line_nr,
      preview_fn_args
    )
    assert.are_same(expected_lines[line_nr], get_buf_lines(0)[line_nr])
  end

  inc_rename._populate_preview_buf(preview_buf, preview_buf_infos, ns)
  local preview_buf_lines = get_buf_lines(preview_buf)
  for line_nr = 1, #preview_buf_lines do
    assert.are_same(expected_preview_buf_lines[line_nr], preview_buf_lines[line_nr])
  end

  assert.are_same(#line_infos, #expected_hls)
  for line_nr, expected_hls_per_line in pairs(expected_hls) do
    local actual_hls = get_hl_positions_for_line(0, line_nr, "Substitute")
    assert_line_hls_match(expected_hls_per_line, actual_hls)
  end
  for line_nr, expected_preview_hls_per_line in pairs(expected_preview_hls) do
    local actual_preview_hls = get_hl_positions_for_line(preview_buf, line_nr, "Substitute")
    assert_line_hls_match(expected_preview_hls_per_line, actual_preview_hls)
  end
end

describe("Renaming and highlighting should work for single file and inccommand=nosplit with", function()
  setup(function()
    inc_rename.setup { hl_group = "Substitute" }
    vim.opt.inccommand = "nosplit"
  end)

  it("a single line", function()
    local line = "local x = 1"
    test_rename_and_highlight(
      { line },
      "abc",
      { { make_line_info(6, 7, line) } },
      { "local abc = 1" },
      { "local ~~~ = 1" }
    )
  end)

  it("a single line with multiple highlights ", function()
    local line = "_ = 1; test =test+2;"
    test_rename_and_highlight(
      { line },
      "new_name",
      { { make_line_info(7, 11, line), make_line_info(13, 17, line) } },
      { "_ = 1; new_name =new_name+2;" },
      { "_ = 1; ~~~~~~~~ =~~~~~~~~+2;" }
    )
  end)

  it("multiple lines with multiple highlights ", function()
    local first_line = "-test = 1"
    local second_line = "a =test+2;"
    test_rename_and_highlight(
      { first_line, second_line },
      "new_name",
      { { make_line_info(1, 5, first_line) }, { make_line_info(3, 7, second_line) } },
      { "-new_name = 1", "a =new_name+2;" },
      { "-~~~~~~~~ = 1", "a =~~~~~~~~+2;" }
    )
  end)
end)

describe("Renaming and highlighting should work with inccommand=split", function()
  setup(function()
    inc_rename.setup { hl_group = "Substitute" }
    vim.opt.inccommand = "split"
  end)

  it("with single file", function()
    local line = "local x = 1"
    local buf_name = "bufname"
    local buf_full_name = vim.fn.getcwd() .. "/" .. buf_name
    test_rename_and_highlight_with_preview_buf(
      buf_name,
      true,
      { line },
      "abc",
      { { make_line_info(6, 7, line) } },
      { "local abc = 1" },
      { "local ~~~ = 1" },
      { ("%s (1 instance):"):format(buf_full_name), "|1| local abc = 1" },
      { ("%s (1 instance):"):format(buf_full_name), "|1| local ~~~ = 1" }
    )
  end)

  it("with single visible file (multiple lines)", function()
    local lines = { "local x = 1", "x = y" }
    local buf_name = "bufname"
    local buf_full_name = vim.fn.getcwd() .. "/" .. buf_name
    test_rename_and_highlight_with_preview_buf(
      buf_name,
      true,
      lines,
      "abc",
      { { make_line_info(6, 7, lines[1], true) }, { make_line_info(0, 1, lines[2], true) } },
      { "local abc = 1", "abc = y" },
      { "local ~~~ = 1", "~~~ = y" },
      { ("%s (2 instances):"):format(buf_full_name), "|1| local abc = 1", "|2| abc = y" },
      { ("%s (2 instances):"):format(buf_full_name), "|1| local ~~~ = 1", "|2| ~~~ = y" }
    )
  end)

  it("with single invisible file (multiple lines)", function()
    local lines = { "local x = 1", "x = y" }
    local buf_name = "bufname"
    local buf_full_name = vim.fn.getcwd() .. "/" .. buf_name
    test_rename_and_highlight_with_preview_buf(
      buf_name,
      false,
      lines,
      "abc",
      { { make_line_info(6, 7, lines[1], false) }, { make_line_info(0, 1, lines[2], false) } },
      { "local x = 1", "x = y" },
      -- No highlights should be applied since the buffer is invisible
      { "local x = 1", "x = y" },
      -- But preview should still be correct
      { ("%s (2 instances):"):format(buf_full_name), "|1| local abc = 1", "|2| abc = y" },
      { ("%s (2 instances):"):format(buf_full_name), "|1| local ~~~ = 1", "|2| ~~~ = y" }
    )
  end)
end)
