local co = coroutine

---@class chatter.ChatClient
local M = {}

---@class chatter.ChatClientState
---@field job_id integer?

---@class chatter.ChatClientStateDict : { [chatter.ChatClient]: chatter.ChatClientState? }
local _state = setmetatable({}, { __mode = "k", })

---@type table<string, thread>
local pending = {}

---@type string?
local OPENROUTER_API_KEY = assert(
  os.getenv("OPENROUTER_API_KEY"),
  "OPENROUTER_API_KEY environment variable is required"
)

---@class chatter.CompletionRequest
---@field messages chatter.Message[]
---@field model string
---@field temperature? number

--- Return the next available request id
---@type fun(): string
local next_stream_id = (function()
  local id = 0
  return function()
    id = id + 1
    return tostring(id)
  end
end)()

---Send raw data to the server's stdin
---@param job_id integer
---@param data string
local function send_raw(job_id, data)
  -- io.stderr:write(string.format("Sending data to server: %s\n", data))
  -- vim.notify("Sending data to server: " .. data, vim.log.levels.DEBUG)
  vim.fn.chansend(job_id, { data, "" })
end

---@class chatter.JsonRpcResponse
---@field jsonrpc string
---@field id string
---@field result? any
---@field error? chatter.JsonRpcError

---@class chatter.JsonRpcError
---@field code integer
---@field message string
---@field data any

--- Assert that the response is a valid JSON-RPC response
---@param resp any
---@return chatter.JsonRpcResponse
local function assert_jsonrpc_response(resp)
  assert(type(resp) == "table", "Invalid JSON-RPC response, expecting table: " .. vim.inspect(resp))
  assert(resp.jsonrpc == "2.0", "Invalid JSON-RPC version: " .. vim.inspect(resp.jsonrpc))
  return resp
end

---Handle stdout from the server
---@param _ any
---@param data string[]
local function handle_stdout(_, data)
  -- io.stderr:write(string.format("Server output: %s\n", vim.inspect(data)))
  -- vim.notify("Server output: " .. vim.inspect(data), vim.log.levels.DEBUG)
  for _, line in ipairs(data) do
    if line ~= "" then
      local ok, response = pcall(vim.fn.json_decode, line)
      if not ok then
        -- io.stderr:write("Failed to decode JSON: " .. line .. "\n")
        vim.notify("Failed to decode JSON: " .. line, vim.log.levels.ERROR)
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
  -- io.stderr:write(string.format("Server error: %s\n", vim.inspect(data)))
  vim.notify("Server error: " .. vim.inspect(data), vim.log.levels.ERROR)
end

---Handle server process exit
local function handle_exit(_, code)
  for _, thread in pairs(pending) do
    co.resume(thread, { error = { message = "Server exited with code " .. code } })
  end
  pending = {}
end

---@async
---Send a JSON-RPC request and yield until response
---@param job_id integer
---@param method string
---@param params table
---@return chatter.JsonRpcResponse
local function send_request(job_id, method, params)
  local thread = assert(coroutine.running(), "send_request must be called in a coroutine")
  local id = tostring(next_stream_id())
  local req = {
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params,
  }
  pending[id] = thread
  send_raw(job_id, vim.fn.json_encode(req))
  local resp = coroutine.yield()
  return assert_jsonrpc_response(resp)
end

---@class chatter.Message
---@field role string
---@field content string


---@async
--- Send a chat completion request to the server
---@param completion_req chatter.CompletionRequest
---@return string? stream_id The stream id to use to stream the responses
---@return string? error
function M:request_completion(completion_req)
  local job_id = _state[self].job_id
  if not job_id then
    return nil, "chat server not started"
  end

  local stream_id = next_stream_id()

  assert(coroutine.running(), "init_stream must be called in a coroutine")

  local rpc_params = {
    id = stream_id,
    completion = completion_req,
  }

  local response = send_request(job_id, "Chat/InitStream", rpc_params)
  if response.error then
    return nil, response.error.message
  end

  if response.result ~= "ack" then
    return nil, "invalid response from server: " .. vim.inspect(response.result)
  end

  return stream_id, nil
end

---@class chatter.StreamResponse
---@field done boolean
---@field type string
---@field content string Can be string or tool response (TODO)

---@async
--- Get the next chunk from a chat response stream
---@param stream_id string
---@return boolean success
---@return chatter.StreamResponse?
---@return string? error
function M:stream_chat(stream_id)
  local job_id = _state[self].job_id
  if not job_id then
    return false, nil, "Chat server not started"
  end
  assert(coroutine.running(), "continue_stream must be called in a coroutine")
  local params = { id = stream_id }
  local reply = send_request(job_id, "Chat/ContinueStream", params)
  if reply.error then
    return false, nil, reply.error.message
  end

  if reply.result and type(reply.result.done) ~= "boolean" then
    return false, nil, "Invalid result from server"
  end
  return true, reply.result
end

---Stop the server process, if running
function M:stop()
  local job_id = _state[self].job_id
  if job_id then
    vim.fn.jobstop(job_id)
    _state[self].job_id = nil
  end
end

---Create a new chat rpc client
---@param command string[] The command to start the chat server
---@return boolean success
---@return chatter.ChatClient?
---@return string? error
local function new(command)
  local job_id = vim.fn.jobstart(
    command,
    {
      env = { OPENROUTER_API_KEY = OPENROUTER_API_KEY },
      on_stdout = handle_stdout,
      on_stderr = handle_stderr,
      on_exit = handle_exit,
    }
  )
  if job_id <= 0 then
    return false, nil, "Failed to start server process"
  end

  ---@type chatter.ChatClient
  local self = setmetatable({}, { __index = M })

  local state = {
    job_id = job_id,
  }

  _state[self] = state

  return true, self, nil
end

return {
  new = new
}
