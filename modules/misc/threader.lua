local thread = class:create("thread")
thread.private.coroutines = {}
thread.private.promises = {}
thread.private.exceptions = {}

function thread.public:getThread()
  local currentThread = coroutine.running()
  return (currentThread and thread.private.coroutines[currentThread]) or false
end

function thread.public:create(exec)
  if self ~= thread.public then return false end
  if not exec or (type(exec) ~= "function") then return false end
  local cThread = self:createInstance()
  if cThread then
      cThread.syncRate = {}
      cThread.thread = coroutine.create(exec)
      thread.private.coroutines[(cThread.thread)] = cThread
  end
  return cThread
end

function thread.public:createHeartbeat(conditionExec, exec, rate)
  if self ~= thread.public then return false end
  if not conditionExec or not exec or (type(conditionExec) ~= "function") or (type(exec) ~= "function") then return false end
  rate = math.max(tonumber(rate) or 0, 1)
  local cThread = thread.public:create(function(self)
      while(conditionExec()) do
          thread.public:pause()
      end
      exec()
      conditionExec, exec = nil, nil
  end)
  cThread:resume({executions = 1, frames = rate})
  return cThread
end

function thread.public:createQueue(exec, rate)
  if self ~= thread.public then return false end
  if not exec or (type(exec) ~= "function") then return false end
  rate = math.max(tonumber(rate) or 0, 1)

  local Queue = { }
  local QueuePrivate = {
    items = { },
    items_count = { },
    running = false
  }

  function Queue:add(item_key, item_value)
    QueuePrivate.items_count[item_key] = (QueuePrivate.items_count[item_key] or 0) + 1
    table.insert(QueuePrivate.items, { key = item_key, value = item_value })

    if(not QueuePrivate.running) then
      QueuePrivate.running = true

      thread.public:create(function(threadSelf)
        while(QueuePrivate.items[1]) do
          local itemData = QueuePrivate.items[1]

          if(itemData and (QueuePrivate.items_count[itemData.key] == 1)) then
            await(exec(threadSelf, itemData.key, itemData.value))
          end

          QueuePrivate.items_count[itemData.key] = (QueuePrivate.items_count[itemData.key] or 1) - 1
          if(QueuePrivate.items_count[itemData.key] == 0) then
            QueuePrivate.items_count[itemData.key] = nil
          end

          table.remove(QueuePrivate.items, 1)
        end

        QueuePrivate.running = false
        QueuePrivate.thread = false

        threadSelf:destroy()
      end):resume({ frames = rate })
    end
  end

  return Queue;
end

function thread.public:createPromise(callback, config)
  if self ~= thread.public then return false end
  callback = (callback and (type(callback) == "function") and callback) or false
  config = (config and (type(config) == "table") and config) or {}
  config.isAsync = (config.isAsync and true) or false
  config.timeout = tonumber(config.timeout) or false
  config.timeout = (config.timeout and (config.timeout > 0) and config.timeout) or false
  if not callback and config.isAsync then return false end
  local cHandle, cTimer, isHandled = nil, nil, false
  local cPromise = {
      resolve = function(...) return cHandle(true, ...) end,
      reject = function(...) return cHandle(false, ...) end
  }
  cHandle = function(isResolver, ...)
      if not thread.private.promises[cPromise] or isHandled then return false end
      isHandled = true
      if cTimer then cTimer:destroy() end
      timer:create(function(...)
          for i, j in pairs(thread.private.promises[cPromise]) do
              thread.private.resolve(i, isResolver, ...)
          end
          thread.private.promises[cPromise] = nil
          collectgarbage()
      end, 1, 1, ...)
      return true
  end
  thread.private.promises[cPromise] = {}
  if not config.isAsync then execFunction(callback, cPromise.resolve, cPromise.reject)
  else thread.public:create(function(self) execFunction(callback, self, cPromise.resolve, cPromise.reject) end):resume() end
  if config.timeout then
      cTimer = timer:create(function() cPromise.reject("Promise - Timed Out") end, config.timeout, 1)
  end
  return cPromise
end

function thread.public:destroy()
  if not thread.public:isInstance(self) then return false end
  if self.intervalTimer and timer:isInstance(self.intervalTimer) then self.intervalTimer:destroy() end
  if self.sleepTimer and timer:isInstance(self.sleepTimer) then self.sleepTimer:destroy() end
  thread.private.coroutines[(self.thread)] = nil
  thread.private.exceptions[self] = nil
  self:destroyInstance()
  return true
end

function thread.public:status()
  if not thread.public:isInstance(self) then return false end
  return coroutine.status(self.thread)
end

function thread.public:pause()
  return coroutine.yield()
end

function thread.private.resume(cThread, abortTimer)
  if not thread.public:isInstance(cThread) or cThread.isAwaiting then return false end
  if abortTimer then
      if cThread.intervalTimer and timer:isInstance(cThread.intervalTimer) then cThread.intervalTimer:destroy() end
      cThread.syncRate.executions, cThread.syncRate.frames = false, false
  end
  if cThread:status() == "dead" then cThread:destroy(); return false end
  if cThread:status() == "suspended" then coroutine.resume(cThread.thread, cThread) end
  if cThread:status() == "dead" then cThread:destroy() end
  return true
end

function thread.public:resume(syncRate)
  if not thread.public:isInstance(self) then return false end
  syncRate = (syncRate and (type(syncRate) == "table") and syncRate) or false
  local executions, frames = (syncRate and tonumber(syncRate.executions)) or false, (syncRate and tonumber(syncRate.frames)) or false
  if not executions or not frames then return thread.private.resume(self, true) end
  if self.intervalTimer and timer:isInstance(self.intervalTimer) then self.intervalTimer:destroy() end
  self.syncRate.executions, self.syncRate.frames = executions, frames
  timer:create(function(...)
      if not self.isAwaiting then
          for i = 1, self.syncRate.executions, 1 do
              thread.private.resume(self)
              if not thread.public:isInstance(self) then break end
          end
      end
      if thread.public:isInstance(self) then
          self.intervalTimer = timer:create(function()
              if self.isAwaiting then return false end
              for i = 1, self.syncRate.executions, 1 do
                  thread.private.resume(self)
                  if not thread.public:isInstance(self) then break end
              end
          end, self.syncRate.frames, 0)
      end
  end, 1, 1)
  return true
end

function thread.public:sleep(duration)
  duration = math.max(0, tonumber(duration) or 0)
  if not thread.public:isInstance(self) or (self ~= thread.public:getThread()) or self.isAwaiting then return false end
  if self.sleepTimer and timer:isInstance(self.sleepTimer) then return false end
  self.isAwaiting = "sleep"
  self.sleepTimer = timer:create(function()
      self.isAwaiting = nil
      thread.private.resume(self)
  end, duration, 1)
  thread.public:pause()
  return true
end

function thread.public:await(cPromise)
  if not thread.public:isInstance(self) or (self ~= thread.public:getThread()) then return false end
  if not cPromise or not thread.private.promises[cPromise] then return false end
  self.isAwaiting = "promise"
  self.awaitingPromise = cPromise
  thread.private.promises[cPromise][self] = true
  thread.public:pause()
  local resolvedValues = self.resolvedValues
  self.resolvedValues = nil
  if self.isErrored then
      if thread.private.exceptions[self] then
          timer:create(function()
              local exception = thread.private.exceptions[self]
              self:destroy()
              exception.promise.reject(unpack(resolvedValues))
              exception.handles.catch(unpack(resolvedValues))
          end, 1, 1)
          thread.public:pause()
      end
      return
  else return unpack(resolvedValues) end
end

function thread.private.resolve(cThread, isResolved, ...)
  if not thread.public:isInstance(cThread) then return false end
  if not cThread.isAwaiting or (cThread.isAwaiting ~= "promise") or not thread.private.promises[(cThread.awaitingPromise)] then return false end
  timer:create(function(...)
      cThread.isAwaiting, cThread.awaitingPromise = nil, nil
      cThread.isErrored = not isResolved
      cThread.resolvedValues = {...}
      thread.private.resume(cThread)
  end, 1, 1, ...)
  return true
end

function thread.public:try(handles)
  if not thread.public:isInstance(self) or (self ~= thread.public:getThread()) then return false end
  handles = (handles and (type(handles) == "table") and handles) or false
  handles.exec = (handles.exec and (type(handles.exec) == "function") and handles.exec) or false
  handles.catch = (handles.catch and (type(handles.catch) == "function") and handles.catch) or false
  if not handles.exec or not handles.catch then return false end
  local cException, cCatch, resolvedValues = nil, handles.catch, nil
  handles.catch = function(...) resolvedValues = {cCatch(...)} end
  local exceptionBuffer = {
      promise = promise(),
      handles = handles
  }
  cException = thread.public:create(function(self)
      resolvedValues = {exceptionBuffer.handles.exec(self)}
      exceptionBuffer.promise.resolve()
  end)
  thread.private.exceptions[cException] = exceptionBuffer
  cException:resume()
  self:await(exceptionBuffer.promise)
  return unpack(resolvedValues)
end

function async(...) return thread.public:create(...) end
function heartbeat(...) return thread.public:createHeartbeat(...) end
function promise(...) return thread.public:createPromise(...) end

function sleep(...)
  local currentThread = thread.public:getThread()
  if not currentThread then return false end
  return currentThread:sleep(...)
end

function await(...)
  local currentThread = thread.public:getThread()
  if not currentThread then return false end
  return currentThread:await(...)
end

function try(...)
  local currentThread = thread.public:getThread()
  if not currentThread then return false end
  return currentThread:try(...)
end