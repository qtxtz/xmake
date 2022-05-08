--!A cross-platform build utility based on Lua
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Copyright (C) 2015-present, TBOOX Open Source Group.
--
-- @author      ruki
-- @file        stream.lua
--

-- imports
import("core.base.object")
import("core.base.socket")
import("core.base.bytes")
import("private.service.message")

-- define module
local stream = stream or object()

-- max data buffer size
local STREAM_DATA_MAXN = 10 * 1024 * 1024

-- init stream
function stream:init(sock)
    self._SOCK = sock
    self._BUFF = bytes(65536)
    self._RCACHE = bytes(8192)
    self._RCACHE_SIZE = 0
    self._WCACHE = bytes(8192)
    self._WCACHE_SIZE = 0
end

-- get socket
function stream:sock()
    return self._SOCK
end

-- flush data
function stream:flush()
    local cache = self._WCACHE
    local cache_size = self._WCACHE_SIZE
    if cache_size > 0 then
        local sock = self._SOCK
        local real = sock:send(cache, {block = true, last = cache_size})
        if real > 0 then
            self._WCACHE_SIZE = 0
            return true
        end
    else
        return true
    end
end

-- send the given bytes (small data)
function stream:send(data, start, last)
    start = start or 1
    last = last or data:size()
    local size = last + 1 - start
    assert(size <= data:size())

    -- write data to cache first
    local cache = self._WCACHE
    local cache_size = self._WCACHE_SIZE
    local cache_maxn = cache:size()
    local cache_left = cache_maxn - cache_size
    if size <= cache_left then
        cache:copy2(cache_size + 1, data, start, last)
        cache_size = cache_size + size
        self._WCACHE_SIZE = cache_size
        return true
    elseif cache_left > 0 then
        cache:copy2(cache_size + 1, data, start, start + cache_left - 1)
        cache_size = cache_size + cache_left
        start = start + cache_left
        size = last + 1 - start
    end
    assert(cache_size == cache_maxn)

    -- send data to socket
    local sock = self._SOCK
    local real = sock:send(cache, {block = true})
    if real > 0 then
        -- copy left data to cache
        assert(size <= cache_maxn)
        cache:copy2(1, data, start, last)
        self._WCACHE_SIZE = size
        return true
    end
end

-- send message
function stream:send_msg(msg)
    return self:send_object(msg:body())
end

-- send object
function stream:send_object(obj)
    local str, errors = string.serialize(obj, {strip = true, indent = false})
    if errors then
        raise(errors)
    end
    if str then
        return self:send_string(str)
    end
end

-- send data
function stream:send_data(data)
    local buff = self._BUFF
    local size = data:size()
    assert(size < STREAM_DATA_MAXN, "too large data size(%d)", size)
    buff:u32be_set(1, size)
    if self:send(buff, 1, 4) then
        local send = 0
        local cache = self._WCACHE
        local cache_maxn = cache:size()
        while send < size do
            local left = math.min(cache_maxn, size - send)
            if self:send(data, send + 1, send + left) then
                send = send + left
            else
                break
            end
        end
        if send == size then
            return true
        end
    end
end

-- send string
function stream:send_string(str)
    return self:send_data(bytes(str))
end

-- send file
function stream:send_file(filepath)

    -- send size
    local buff = self._BUFF
    local size = os.filesize(filepath)
    buff:u32be_set(1, size)
    if not self:send(buff, 1, 4) then
        return
    end

    -- flush cache data first
    if not self:flush() then
        return
    end

    -- send file
    local ok = false
    local sock = self._SOCK
    local file = io.open(filepath, 'rb')
    if file then
        local send = sock:sendfile(file, {block = true})
        if send > 0 then
            ok = true
        end
        file:close()
    end
    return ok
end

-- recv the given bytes
function stream:recv(buff, size)
    assert(size <= buff:size(), "too large size(%d)", size)

    -- read data from cache first
    local buffsize = 0
    local cache = self._RCACHE
    local cache_size = self._RCACHE_SIZE
    local cache_maxn = cache:size()
    if size <= cache_size then
        buff:copy(cache, 1, size)
        cache:move(size + 1, cache_size)
        cache_size = cache_size - size
        self._RCACHE_SIZE = cache_size
        return buff:slice(1, size)
    elseif cache_size > 0 then
        buff:copy(cache, 1, cache_size)
        buffsize = cache_size
        cache_size = 0
    end
    assert(cache_size == 0)

    -- recv data from socket
    local real = 0
    local data = nil
    local wait = false
    local sock = self._SOCK
    while buffsize < size do
        real, data = sock:recv(cache)
        if real > 0 then
            -- append data to buffer
            local leftsize = size - buffsize
            if real < leftsize then
                buff:copy2(buffsize + 1, data)
                buffsize = buffsize + real
            else
                buff:copy2(buffsize + 1, data, 1, leftsize)
                buffsize = buffsize + leftsize

                -- move left cache to head
                cache_size = real - leftsize
                if cache_size > 0 then
                    cache:move(leftsize + 1, real)
                end
                self._RCACHE_SIZE = cache_size
                return buff:slice(1, buffsize)
            end
            wait = false
        elseif real == 0 and not wait then
            if sock:wait(socket.EV_RECV, -1) == socket.EV_RECV then
                wait = true
            else
                break
            end
        else
            break
        end
    end
end

-- recv u32be
function stream:recv_u32be()
    local data = self:recv(self._BUFF, 4)
    if data then
        return data:u32be(1)
    end
end

-- recv message
function stream:recv_msg()
    local body = self:recv_object()
    if body then
        return message(body)
    end
end

-- recv object
function stream:recv_object()
    local str = self:recv_string()
    if str then
        local obj, errors = str:deserialize()
        if errors then
            raise(errors)
        end
        return obj
    end
end

-- recv data
function stream:recv_data()
    local size = self:recv_u32be()
    if size then
        local recv = 0
        assert(size < STREAM_DATA_MAXN, "too large data size(%d)", size)
        local buff = bytes(size)
        while recv < size do
            local data = self:recv(buff:slice(recv + 1), size - recv)
            if data then
                recv = recv + data:size()
            else
                break
            end
        end
        if recv == size then
            return buff
        end
    end
end

-- recv string
function stream:recv_string()
    local data = self:recv_data()
    if data then
        return data:str()
    end
end

-- recv file
function stream:recv_file(filepath)
    local size = self:recv_u32be()
    if size then
        local buff = self._BUFF
        local recv = 0
        local file = io.open(filepath, "wb")
        while recv < size do
            local data = self:recv(buff, math.min(buff:size(), size - recv))
            if data then
                file:write(data)
                recv = recv + data:size()
            end
        end
        file:close()
        if recv == size then
            return true
        end
    end
end

function main(sock)
    local instance = stream()
    instance:init(sock)
    return instance
end
