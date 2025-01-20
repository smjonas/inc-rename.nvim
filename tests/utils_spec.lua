local utils = require("inc_rename.utils")
local get_aligned_line_prefix = utils.get_aligned_line_prefix

describe("get_padded_line_prefix", function()
  it("should work", function()
    assert.are_same("|9| ", get_aligned_line_prefix(9, 1))
    assert.are_same("| 9| ", get_aligned_line_prefix(9, 10))
    assert.are_same("|10| ", get_aligned_line_prefix(10, 10))
    assert.are_same("|11| ", get_aligned_line_prefix(11, 10))
    assert.are_same("|  3| ", get_aligned_line_prefix(3, 100))
    assert.are_same("|123| ", get_aligned_line_prefix(123, 999))
    -- Passed line nr. is larger than max. line nr.
    assert.are_same("|123| ", get_aligned_line_prefix(123, 1))
  end)
end)
