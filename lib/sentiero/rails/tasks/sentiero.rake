# frozen_string_literal: true

require "time"

namespace :sentiero do
  desc "Purge sessions older than config.retention_period (destructive, irreversible)"
  task purge: :environment do
    deleted = Sentiero.purge_expired!
    if deleted.nil?
      puts "Sentiero: retention_period not configured; nothing purged."
    else
      puts "Sentiero: purged #{deleted} session(s)."
    end
  end

  desc "Erase sessions by ID or time range (GDPR Art. 17; destructive, irreversible)"
  task erase: :environment do
    ids_env = ENV["SESSION_IDS"] || ENV["SESSION_ID"]
    if ids_env
      deleted = Sentiero.erase_sessions(ids_env.split(","))
      puts "Sentiero: erased #{deleted} session(s)."
    elsif ENV["SINCE"] || ENV["UNTIL"]
      since = ENV["SINCE"] ? Time.parse(ENV["SINCE"]) : nil
      until_time = ENV["UNTIL"] ? Time.parse(ENV["UNTIL"]) : nil
      deleted = Sentiero.erase_where(since: since, until_time: until_time)
      puts "Sentiero: erased #{deleted} session(s)."
    else
      abort "Usage: rake sentiero:erase SESSION_IDS=id1,id2  OR  SINCE=YYYY-MM-DD UNTIL=YYYY-MM-DD"
    end
  end
end
