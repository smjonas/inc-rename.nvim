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
    if char == "~" then
      local got_hl_at_position = vim.iter(actual_hl_positions):any(function(hl_pos)
        return hl_pos.start_col_idx <= i - 1 and i - 1 <= hl_pos.end_col_idx
      end)
      assert.is_true(got_hl_at_position, "Expected highlight at position " .. i)
    end
  end
end

local function make_line_info(start_col, end_col, line)
  return { start_col = start_col, end_col = end_col, is_visible = true, text = line }
end

local function test_rename_and_highlight(before, new_name, line_infos, expected_lines, expected_hls)
  set_buf_lines(0, before)
  local preview_fn_args = { new_name = new_name, preview_ns = ns }
  for line_nr, line_infos_per_line_nr in pairs(line_infos) do
    assert(line_nr >= 1)
    inc_rename.apply_highlights_fn(0, nil, {}, line_nr - 1, line_infos_per_line_nr, preview_fn_args)
    assert.are_same(expected_lines[line_nr], get_buf_lines(0)[line_nr])
  end
  for line_nr, expected_hls_per_line in pairs(expected_hls) do
    local actual_hls = get_hl_positions_for_line(0, line_nr, "Substitute")
    assert_line_hls_match(expected_hls_per_line, actual_hls)
  end
end

describe("Renaming and highlighting should work for single file with", function()
  setup(function()
    inc_rename.setup { hl_group = "Substitute" }
  end)

  it("a single line", function()
    local line = "local x = 1"
    test_rename_and_highlight(
      { line },
      "abc",
      { [1] = { make_line_info(6, 7, line) } },
      { [1] = "local abc = 1" },
      { [1] = "local ~~~ = 1" }
    )
  end)

  it("a single line with multiple highlights ", function()
    local line = "_ = 1; test =test+2;"
    test_rename_and_highlight(
      { line },
      "new_name",
      { [1] = { make_line_info(7, 11, line), make_line_info(13, 17, line) } },
      { [1] = "_ = 1; new_name =new_name+2;" },
      { [1] = "_ = 1; ~~~~~~~~ =~~~~~~~~+2;" }
    )
  end)

  it("multiple lines with multiple highlights ", function()
    local first_line = "-test = 1"
    local second_line = "a =test+2;"
    test_rename_and_highlight(
      { first_line, second_line },
      "new_name",
      { [1] = { make_line_info(1, 5, first_line) }, [2] = { make_line_info(3, 7, second_line) } },
      { [1] = "-new_name = 1", [2] = "a =new_name+2;" },
      { [1] = "-~~~~~~~~ = 1", [2] = "a =~~~~~~~~+2;" }
    )
  end)
end)
