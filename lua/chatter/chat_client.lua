---@alias chatter.JobStderrHandler fun(job_id: integer, data: string[])

---@class chatter.ChatClient
---@field private job_id? integer
local M = {}

---@type table<string, thread>
local pending = {}

---@type string?
local OPENROUTER_API_KEY = assert(
  os.getenv("OPENROUTER_API_KEY"),
  "OPENROUTER_API_KEY environment variable is required"
)

---@class chatter.CompletionRequest
---@field messages chatter.ChatCompletionMessage[]
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

local stdout_buffer = ""

---Handle stdout from the server
---@param _ any
---@param data string[]
local function handle_stdout(_, data)
  for _, line in ipairs(data) do
    if line ~= "" then
      -- Large json responses may be split into multiple lines.
      -- Accumulate received data and try to decode it.
      -- If decoding fails, simply wait for more data.
      stdout_buffer = stdout_buffer .. line
      local ok, response = pcall(vim.fn.json_decode, stdout_buffer)
      if ok then
        stdout_buffer = ""
        response = assert_jsonrpc_response(response)
        if pending[response.id] then
          local thread = pending[response.id]
          pending[response.id] = nil
          coroutine.resume(thread, response)
        end
      end
    end
  end
end

---Handle server process exit
local function handle_exit(_, code)
  for _, thread in pairs(pending) do
    coroutine.resume(thread, { error = { message = "Server exited with code " .. code } })
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

---@async
--- Send a chat completion request to the server
---@param completion_req chatter.CompletionRequest
---@return string? stream_id The stream id to use to stream the responses
---@return string? error
function M.chat_stream_init(completion_req)
  local job_id = M.assert_job_id()
  local stream_id = next_stream_id()

  local rpc_params = {
    id = stream_id,
    completion = completion_req,
  }

  local response = send_request(job_id, "chat/stream/init", rpc_params)
  if response.error then
    return nil, response.error.message
  end

  if response.result ~= "ack" then
    return nil, "invalid response from server: " .. vim.inspect(response.result)
  end

  return stream_id, nil
end

---@class chatter.ChatCompletionMessage
---@field role string
---@field content string
---@field tool_calls? chatter.ToolCall[]
---@field tool_call_id? string

---@class chatter.ToolCall
---@field index integer
---@field id string
---@field type string
---@field function chatter.Function

---@class chatter.Function
---@field name string
---@field arguments string

---@class chatter.StreamResponse
---@field done boolean
---@field error? string
---@field message chatter.ChatCompletionMessage

---@async
--- Get the next chunk from a chat response stream
---@param stream_id string
---@return chatter.StreamResponse?
---@return string? error
function M.chat_stream_continue(stream_id)
  local job_id = M.assert_job_id()

  local params = { id = stream_id }
  local reply = send_request(job_id, "chat/stream/continue", params)
  if reply.error then
    return nil, reply.error.message or reply.error
  end

  if reply.result and type(reply.result.done) ~= "boolean" then
    return nil, "Invalid result from server"
  end
  return reply.result, nil
end

---@class chatter.ToolContent
---@field type string Can be "text" or ...
---@field text string The content of the call tool result

---@class chatter.CallToolResult
---@field content chatter.ToolContent[]
---@field isError boolean?

--- Assert and return the job id of the chat server.
--- Also asserts that the function is called in a coroutine.
---@return integer job_id
function M.assert_job_id()
  assert(coroutine.running(), "must be called in a coroutine")
  return assert(M.job_id, "Chat server not started")
end

--- Call a tool with the given parameters
---@param tool_call chatter.ToolCall
---@return boolean success
---@return chatter.CallToolResult? result
---@return string? error
function M.tool_call(tool_call)
  local job_id = M.assert_job_id()

  local params = { tool_call = tool_call }
  local reply = send_request(job_id, "tool/call", params)
  if reply.error then
    return false, nil, reply.error.message
  end

  return true, reply.result
end

--- Check if the tool is safe to call without user confirmation
---@param tool_name string The name of the tool
---@return boolean safe Whether the tool is safe to call
function M.tool_safe(tool_name)
  local job_id = M.assert_job_id()
  local params = { tool_name = tool_name }

  local reply = send_request(job_id, "tool/safe", params)
  if reply.error then
    return false
  end

  return type(reply.result) == "boolean" and reply.result
end

---Stop the server process, if running
function M.stop()
  if M.job_id then
    vim.fn.jobstop(M.job_id)
    M.job_id = nil
  end
end

---@class chatter.ChatClientStartOptions
---@field command string[] The command to start the server
---@field on_stderr chatter.JobStderrHandler The handler for stderr output
---@field on_exit fun(job_id: integer, code: integer) The handler for process exit

--- Start the server process, if not already running
---@param opts chatter.ChatClientStartOptions
---@return boolean success
---@return string? error
function M.start(opts)
  if M.job_id then
    return true
  end

  M.job_id = vim.fn.jobstart(
    opts.command,
    {
      env = { OPENROUTER_API_KEY = OPENROUTER_API_KEY },
      on_stdout = handle_stdout,
      on_stderr = opts.on_stderr,
      on_exit = function(_, code)
        handle_exit(_, code)
        opts.on_exit(M.job_id, code)
      end,
    }
  )

  if M.job_id <= 0 then
    return false, "Failed to start server process"
  end

  return true
end

return M
