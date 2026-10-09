$stdout.sync = true
$stderr.sync = true
%w[INT TERM].each { |signal| Signal.trap(signal) { exit } }

token = "#{Socket.gethostname}:#{Process.pid}:#{Process.clock_gettime(Process::CLOCK_MONOTONIC).to_i}"

loop do
  client = RecentMeasurements.redis
  begin
    unless RecentMeasurements.acquire_lock!(client, token: token)
      warn "Redis sync: inna instancja trzyma blokadę; czekam."
      sleep RecentMeasurements::LOCK_TTL
      next
    end
    ActiveRecord::Base.uncached { RecentMeasurements.rebuild!(client) }
    puts "Redis: odtworzono ostatnie 72 godziny (#{token})"
    loop do
      break unless RecentMeasurements.renew_lock!(client, token: token)
      # FLUSHDB lub wygaśnięcie znacznika wymaga pełnego odtworzenia.
      ActiveRecord::Base.uncached do
        RecentMeasurements.rebuild!(client) unless client.exists?("#{RecentMeasurements::PREFIX}:built")
        RecentMeasurements.drain!(client)
      end
      sleep 2
    end
    warn "Redis sync: utracono blokadę; ponawiam przejęcie."
  rescue Redis::BaseError, ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid => e
    warn "Redis sync: #{e.class}: #{e.message}; ponowienie za 5 s"
    sleep 5
  ensure
    RecentMeasurements.release_lock!(client, token: token) rescue nil
    client.close
  end
end