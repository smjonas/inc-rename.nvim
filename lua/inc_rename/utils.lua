local M = {}

---@param bufnr integer
---@param method string?
---@return vim.lsp.Client[]
M.get_active_clients = function(bufnr, method)
  local opts = { bufnr = bufnr }
  local clients = {}
  if vim.lsp.get_clients then
    clients = vim.lsp.get_clients(opts)
  else
    ---@diagnostic disable-next-line: deprecated
    clients = vim.lsp.get_active_clients(opts)
  end
  if not method then
    return clients
  end
  clients = vim.tbl_filter(function(client)
    return client.supports_method(method)
  end, clients)
  return clients
end

M.make_client_position_params = function(win_id, extra)
  win_id = win_id or vim.api.nvim_get_current_win()
  if vim.fn.has("nvim-0.11") == 0 then
    ---@diagnostic disable-next-line: missing-parameter
    local params = vim.lsp.util.make_position_params(win_id)
    if extra then
      params = vim.tbl_extend("force", params, extra)
    end
    return params
  end
  return function(client)
    local params = vim.lsp.util.make_position_params(win_id, client.offset_encoding)
    if extra then
      params = vim.tbl_extend("force", params, extra)
    end
    return params
  end
end

---@param line_nr number
---@param max_line_nr number
M.get_aligned_line_prefix = function(line_nr, max_line_nr)
  local line_nr_length = #tostring(line_nr)
  local max_prefix_length = #tostring(max_line_nr)
  local prefix = ""
  if line_nr_length < max_prefix_length then
    prefix = (" "):rep(max_prefix_length - line_nr_length)
  end
  return ("|%s%s| "):format(prefix, line_nr)
end

return M
