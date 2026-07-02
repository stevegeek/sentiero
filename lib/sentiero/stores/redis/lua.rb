# frozen_string_literal: true

module Sentiero
  module Stores
    class Redis
      # EVAL scripts for operations that need atomicity a MULTI/EXEC pipeline
      # can't give a read-modify-write (or delete-if-empty) across keys.
      module Lua
        SAVE_METADATA = <<~LUA
          local key = KEYS[1]
          if redis.call("EXISTS", key) == 0 then
            return 0
          end
          local existing_json = redis.call("HGET", key, "metadata")
          local existing = existing_json and cjson.decode(existing_json) or {}
          local new_data = cjson.decode(ARGV[1])
          for k, v in pairs(new_data) do
            existing[k] = v
          end
          redis.call("HSET", key, "metadata", cjson.encode(existing))
          return 1
        LUA

        # Atomic so a concurrent save_events adding a new window mid-delete can't
        # orphan its events key (which a read-then-pipeline sequence would miss).
        EVICT_SESSION = <<~LUA
          local windows_key = KEYS[1]
          local session_key = KEYS[2]
          local sessions_key = KEYS[3]
          local session_id = ARGV[1]
          local prefix = ARGV[2]

          for _, window_id in ipairs(redis.call("SMEMBERS", windows_key)) do
            redis.call("DEL", prefix .. "events:" .. session_id .. ":" .. window_id)
          end
          redis.call("DEL", windows_key)
          redis.call("DEL", session_key)
          redis.call("ZREM", sessions_key, session_id)
        LUA

        DELETE_WINDOW = <<~LUA
          local events_key = KEYS[1]
          local windows_key = KEYS[2]
          local session_key = KEYS[3]
          local sessions_key = KEYS[4]
          local window_id = ARGV[1]
          local session_id = ARGV[2]
          local now = ARGV[3]

          redis.call("DEL", events_key)
          redis.call("SREM", windows_key, window_id)

          local remaining = redis.call("SCARD", windows_key)
          if remaining == 0 then
            redis.call("DEL", session_key)
            redis.call("DEL", windows_key)
            redis.call("ZREM", sessions_key, session_id)
          else
            redis.call("HSET", session_key, "updated_at", now)
            redis.call("ZADD", sessions_key, tonumber(now), session_id)
          end
          return remaining
        LUA

        # Atomic problem upsert: a read-then-write in Ruby lost concurrent
        # count/last_seen updates for the same fingerprint. The count+1 / min
        # first_seen / max last_seen / reopen-if-resolved logic mirrors
        # ErrorStore#touched_problem_attrs (kept in Ruby for Memory/File); the new
        # record is built in Ruby (new_problem_attrs) and passed in pre-serialized.
        # Returns 1 when it created a new problem, 0 when it updated an existing one.
        PROBLEM_UPSERT = <<~LUA
          local prob_key, problems_key, proj_key = KEYS[1], KEYS[2], KEYS[3]
          local fp, ts, message, new_json = ARGV[1], tonumber(ARGV[2]), ARGV[3], ARGV[4]

          local existing_json = redis.call("GET", prob_key)
          if existing_json then
            local p = cjson.decode(existing_json)
            p.count = (p.count or 0) + 1
            if ts < p.first_seen then p.first_seen = ts end
            if ts > p.last_seen then p.last_seen = ts end
            p.message = message
            if p.status == "resolved" then
              p.status = "open"
              p.resolved_at = nil
            end
            redis.call("SET", prob_key, cjson.encode(p))
            redis.call("ZADD", problems_key, p.last_seen, fp)
            return 0
          else
            redis.call("SET", prob_key, new_json)
            redis.call("ZADD", problems_key, ts, fp)
            redis.call("SADD", proj_key, fp)
            return 1
          end
        LUA

        UPDATE_TIMESTAMPS = <<~LUA
          local key = KEYS[1]
          local batch_min = ARGV[1]
          local batch_max = ARGV[2]

          if batch_min ~= "" then
            local current = redis.call("HGET", key, "first_event_at")
            if not current or tonumber(batch_min) < tonumber(current) then
              redis.call("HSET", key, "first_event_at", batch_min)
            end
          end

          if batch_max ~= "" then
            local current = redis.call("HGET", key, "last_event_at")
            if not current or tonumber(batch_max) > tonumber(current) then
              redis.call("HSET", key, "last_event_at", batch_max)
            end
          end
        LUA
      end
    end
  end
end
