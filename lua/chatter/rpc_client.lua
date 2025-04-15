local co = coroutine

---@class chat.RpcClient
local M = {}

---@type integer?
local job_id = nil

---@type integer
local req_id = 0

---@type table<string, thread>
local pending = {}

---@type string?
local OPENROUTER_API_KEY = assert(
  os.getenv("OPENROUTER_API_KEY"),
  "OPENROUTER_API_KEY environment variable is required"
)

---@class chat.CompletionRequest
---@field messages chat.Message[]
---@field model string
---@field temperature? number

---@param system_prompt string?
---@param user_prompt string?
---@return chat.CompletionRequest
function M.new_completion_request(system_prompt, user_prompt)
  local default_system_prompt = "You are a helpful assistant."
  if not system_prompt or system_prompt == "" then
    system_prompt = default_system_prompt
  end
  return {
    messages = {
      { role = "system", content = system_prompt },
      { role = "user",   content = user_prompt or "" },
    },
    model = "meta-llama/llama-4-maverick:free",
  }
end

---Get the next request id
---@return integer
local function next_id()
  req_id = req_id + 1
  return req_id
end

---Send raw data to the server's stdin
---@param data string
local function send_raw(data)
  if job_id then
    io.stderr:write(string.format("Sending data to server: %s\n", data))
    vim.fn.chansend(job_id, { data, "" })
  end
end

---@class chat.JsonRpcResponse
---@field jsonrpc string
---@field id string
---@field result? any
---@field error? chat.JsonRpcError

---@class chat.JsonRpcError
---@field code integer
---@field message string
---@field data any

--- Assert that the response is a valid JSON-RPC response
---@param resp any
---@return chat.JsonRpcResponse
local function assert_jsonrpc_response(resp)
  assert(type(resp) == "table", "Invalid JSON-RPC response, expecting table: " .. vim.inspect(resp))
  assert(resp.jsonrpc == "2.0", "Invalid JSON-RPC version: " .. vim.inspect(resp.jsonrpc))
  return resp
end

---Handle stdout from the server
---@param _ any
---@param data string[]
local function handle_stdout(_, data)
  io.stderr:write(string.format("Server output: %s\n", vim.inspect(data)))
  for _, line in ipairs(data) do
    if line ~= "" then
      local ok, response = pcall(vim.fn.json_decode, line)
      if not ok then
        io.stderr:write("Failed to decode JSON: " .. line .. "\n")
        return
      end
      response = assert_jsonrpc_response(response)
      if pending[response.id] then
        local thread = pending[response.id]
        pending[response.id] = nil
        co.resume(thread, response)
      end
    end
  end
end

---Handle stderr from the server
---@param _ any
---@param data string[]
local function handle_stderr(_, data)
  io.stderr:write(string.format("Server error: %s\n", vim.inspect(data)))
end

---Handle server process exit
local function handle_exit(_, code)
  job_id = nil
  for _, thread in pairs(pending) do
    co.resume(thread, { error = { message = "Server exited with code " .. code } })
  end
  pending = {}
end

---Start the JSON-RPC server process
---@param command string[] The command to start the chat server
function M.start(command)
  if job_id then return end
  job_id = vim.fn.jobstart(
    command,
    {
      env = { OPENROUTER_API_KEY = OPENROUTER_API_KEY },
      on_stdout = handle_stdout,
      on_stderr = handle_stderr,
      on_exit = handle_exit,
    }
  )
  if job_id <= 0 then
    error("Failed to start server process")
  end
end

---@async
---Send a JSON-RPC request and yield until response
---@param method string
---@param params table
---@return chat.JsonRpcResponse
local function send_request(method, params)
  assert(job_id, "Server not started. Call require('rpc_client').start() first.")
  local thread = assert(coroutine.running(), "send_request must be called in a coroutine")
  local id = tostring(next_id())
  local req = {
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params,
  }
  pending[id] = thread
  send_raw(vim.fn.json_encode(req))
  local resp = coroutine.yield()
  return assert_jsonrpc_response(resp)
end

---@class chat.Message
---@field role string
---@field content string


---@async
---Initialize a chat stream
---@param stream_id string
---@param completion_req chat.CompletionRequest
---@return boolean success
function M.init_stream(stream_id, completion_req)
  assert(coroutine.running(), "init_stream must be called in a coroutine")
  local params = {
    id = stream_id,
    completion = completion_req,
  }
  -- vim.api.nvim_echo({ { "params: " .. vim.inspect(params) } }, false, { err = true })
  local response = send_request("Chat/InitStream", params)
  return response and response.result == "ack"
end

---@class chat.StreamResponse
---@field done boolean
---@field response string

---@async
---Continue a chat stream
---@param stream_id string
---@return boolean success
---@return chat.StreamResponse?
---@return string? error
function M.continue_stream(stream_id)
  assert(coroutine.running(), "continue_stream must be called in a coroutine")
  local params = { id = stream_id }
  local reply = send_request("Chat/ContinueStream", params)
  if reply.error then
    return false, nil, reply.error.message
  end
  -- assert(resp.result, "Invalid response from server")
  if reply.result and type(reply.result.done) ~= "boolean" then
    return false, nil, "Invalid result from server"
  end
  return true, reply.result
end

---Stop the server process
function M.stop()
  if job_id then
    vim.fn.jobstop(job_id)
    job_id = nil
  end
end

return M
