# frozen_string_literal: true

# Link simulator between one site and central (stands in for Toxiproxy).
#
#   ruby link_proxy.rb LISTEN_PORT TARGET_PORT STATE_FILE
#
# STATE_FILE holds one line, re-read for every connection:
#   up              pass traffic through
#   down            refuse traffic (the site is offline)
#   drop_acks       deliver the request to central, then drop central's answer
#                   (central commits, the site never hears back)
#   slow <kbit/s>   pass traffic through at the given bandwidth
require 'socket'

listen_port, target_port, state_file = ARGV
server = TCPServer.new('127.0.0.1', Integer(listen_port))
$stdout.sync = true
puts "link #{listen_port} -> #{target_port} (state: #{state_file})"

def link_state(file)
  File.exist?(file) ? File.read(file).strip.split : ['up']
rescue StandardError
  ['up']
end

# Copy from one socket to another, at most `kbps` kbit/s when given.
def pipe(from, to, kbps)
  chunk = kbps ? [kbps * 128 / 10, 512].max : 16_384 # ~0.1 s of data per chunk
  loop do
    data = from.readpartial(chunk)
    to.write(data) if to
    sleep(data.bytesize * 8.0 / (kbps * 1000)) if kbps
  end
rescue EOFError, IOError, SystemCallError
  nil
ensure
  begin
    to&.close_write
  rescue StandardError
    nil
  end
end

loop do
  client = server.accept
  Thread.new(client) do |c|
    mode, arg = link_state(state_file)
    if mode == 'down'
      c.close
      next
    end
    kbps = mode == 'slow' ? Integer(arg || 256) : nil
    upstream = TCPSocket.new('127.0.0.1', Integer(target_port))
    up = Thread.new { pipe(c, upstream, kbps) }
    if mode == 'drop_acks'
      pipe(upstream, nil, nil) # read central's answer and throw it away
      c.close
    else
      pipe(upstream, c, kbps)
    end
    up.join(1)
  rescue SystemCallError
    nil
  ensure
    [c, upstream].each do |s|
      s&.close
    rescue StandardError
      nil
    end
  end
end
