local process = require("process")
local shell = require("shell")
local buffer = require("buffer")
local command_result_as_code = require("sh").internal.command_result_as_code

local pipe = {}
local _root_co = assert(process.info(), "process metadata failed to load").data.coroutine_handler

-- root can be a coroutine or a function
function pipe.createCoroutineStack(root, env, name)
  checkArg(1, root, "thread", "function")

  if type(root) == "function" then
    root = assert(process.load(root, env, nil, name or "pipe"), "failed to load proc data for given function")
  end

  local proc = assert(process.list[root], "coroutine must be a process thread else the parent process is corrupted")

  local pco = setmetatable({root=root}, {__index=_root_co})
  proc.data.coroutine_handler = pco

  function pco.yield(...)
    return _root_co.yield(nil, ...)
  end
  function pco.yield_all(...)
    return _root_co.yield(true, ...)
  end
  function pco.resume(co, ...)
    checkArg(1, co, "thread")
    local args = table.pack(...)
    while true do -- for consecutive sysyields
      local result = table.pack(_root_co.resume(co, table.unpack(args, 1, args.n)))
      if not result[1] or _root_co.status(co) == "dead" then
        return table.unpack(result, 1, result.n)
      elseif result[2] and pco.root ~= co then
        args = table.pack(_root_co.yield(table.unpack(result, 2, result.n)))
      else
        return true, table.unpack(result, 3, result.n)
      end
    end
  end
  return pco
end

local pipe_stream = 
{
  continue = function(self, exit)
    local result = table.pack(coroutine.resume(self.next))
    while true do -- repeat resumes if B (A|B) makes a natural yield
      -- if B crashed or closed in the last resume
      -- then we can close the stream
      if coroutine.status(self.next) == "dead" then
        self:close()
        -- always cause os.exit when the pipe closes
        -- this is very important
        -- e.g. cat very_large_file | head
        -- when head is done, cat should stop
        result[1] = nil
      end
      -- the pipe closed or crashed
      if not result[1] then
        if exit then
          os.exit(command_result_as_code(result[2]))
        end
        return self
      end
      -- next is suspended, read_mode indicates why
      if self.read_mode then
        -- B wants A to write again, resume A
        return self
      end
      -- not reading, it is requesting a yield
      result = table.pack(coroutine.yield_all(table.unpack(result, 2, result.n)))
      result = table.pack(coroutine.resume(self.next, table.unpack(result, 1, result.n))) -- the request was for an event
    end
  end,
  close = function(self)
    self.closed = true
    if coroutine.status(self.next) == "suspended" then
      self:continue()
    end
    self.redirect = {}
  end,
  seek = function()
    return nil, "bad file descriptor"
  end,
  write = function(self, value)
    if not self.redirect[1] and self.closed then
      -- if next is dead, ignore all writes
      if coroutine.status(self.next) ~= "dead" then
        io.stderr:write("attempt to use a closed stream\n")
        os.exit(1)
      end
    elseif self.redirect[1] then
      return self.redirect[1]:write(value)
    elseif not self.closed then
      self.buffer = self.buffer .. value
      return self:continue(true)
    end
    os.exit(0) -- abort the current process: SIGPIPE
  end,
  read = function(self, n)
    if self.closed then
      return nil -- eof
    end
    if self.redirect[0] then
      -- popen could be using this code path
      -- if that is the case, it is important to leave stream.buffer alone
      return self.redirect[0]:read(n)
    elseif self.buffer == "" then
      -- the pipe_stream write resume is waiting on this process B (A|B) to yield
      -- yield here requests A to output again. However, B may elsewhere want a
      -- natural yield (i.e. for events). To differentiate this yield from natural
      -- yields we set read_mode here, which the pipe_stream write detects
      self.read_mode = true
      coroutine.yield_all()
      self.read_mode = false
    end
    local result = string.sub(self.buffer, 1, n)
    self.buffer = string.sub(self.buffer, n + 1)
    return result
  end
}

-- prog1 | prog2 | ... | progn
function pipe.buildPipeChain(progs)
  local chain = {}
  local prev_piped_stream
  for i=1,#progs do
    local thread = progs[i]
    -- A needs to be a stack in case any thread in A call write and then B natural yields
    -- B needs to be a stack in case any thread in B calls read
    pipe.createCoroutineStack(thread)
    chain[i] = thread
    local data = process.info(thread).data
    local pio = data.io

    local piped_stream
    if i < #progs then
      local handle = setmetatable({redirect = {rawget(pio, 1)},buffer = ""}, {__index = pipe_stream})
      piped_stream = buffer.new("rw", handle)
      piped_stream:setvbuf("no", 1024)
      pio[1] = piped_stream
      table.insert(data.handles, piped_stream)
    end

    if prev_piped_stream then
      prev_piped_stream.stream.redirect[0] = rawget(pio, 0)
      prev_piped_stream.stream.next = thread
      pio[0] = prev_piped_stream
    end

    prev_piped_stream = piped_stream
  end

  return chain
end

local chain_stream =
{
  read = function(self, value)
    if self.io_stream.closed then return nil end
    -- handler is currently on yield all [else we wouldn't have control here]
    local read_ok, ret = self.pco.resume(self.pco.root, value)
    -- ret can be non string when a process ends
    ret = type(ret) == "string" and ret or nil
    return select(read_ok and 2 or 1, nil, ret)
  end,
  write = function(self, ...)
    return self:read(table.concat({...}))
  end,
  close = function(self)
    self.io_stream:close()
  end,
}

function pipe.popen(prog, mode, env)
  mode = mode or "r"
  if mode ~= "r" and mode ~= "w" then
    return nil, "bad argument #2: invalid mode " .. tostring(mode) .. " must be r or w"
  end

  local r = mode == "r"
  local key = r and "read" or "write"

  -- to simplify the code - shell.execute is run within a function to pass (prog, env)
  -- if cmd_proc where to come second (mode=="w") then the pipe_proc would have to pass
  -- the starting args. which is possible, just more complicated
  local cmd_proc = process.load(function() return shell.execute(prog, env) end, nil, nil, prog)

  -- the chain stream is the popen controller
  local stream = setmetatable({}, { __index = chain_stream })

  -- the stream needs its own process for io
  local pipe_proc = process.load(function()
    local n = r and 0 or ""
    local ios = stream.io_stream
    while not ios.closed do
      n = coroutine.yield_all(ios[key](ios, n))
    end
  end, nil, nil, "pipe_handler")

  local pipe_index = r and 2 or 1
  local cmd_index = r and 1 or 2
  local chain = {[cmd_index]=cmd_proc, [pipe_index]=pipe_proc}

  -- link the cmd and pipe proc io
  pipe.buildPipeChain(chain)
  local cmd_stack = process.info(chain[1]).data.coroutine_handler

  -- store handle to io_stream from easy access later
  stream.io_stream = process.info(chain[1]).data.io[1].stream
  stream.pco = cmd_stack

  -- popen commands start out running, like threads
  cmd_stack.resume(cmd_stack.root)

  local buffered_stream = buffer.new(mode, stream)
  buffered_stream:setvbuf("no", 1024)
  return buffered_stream
end

return pipe
