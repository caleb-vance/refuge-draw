#!/usr/bin/ruby
# Serves the site and keeps CDFW data fresh. Usage: ruby server.rb [port]
Encoding.default_external = 'UTF-8'
require 'webrick'
require 'socket'
require_relative 'lib/cdfw'

PORT = (ARGV[0] || ENV['PORT'] || 8080).to_i
ROOT = __dir__
MAX_AGE = 15 * 60
HEAD = '<!doctype html><html lang="en"><head><meta charset="utf-8">' \
       '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"></head><body>'.freeze

$live = nil
$live_at = Time.at(0)
$lock = Mutex.new

def live_json
  $lock.synchronize do
    if Time.now - $live_at > MAX_AGE
      snap = Cdfw.snapshot
      # Keep the last good data if CDFW is unreachable.
      if snap[:draws].any? || $live.nil?
        $live = JSON.generate(snap)
        File.write(File.join(ROOT, 'data/snapshot.json'), $live) if snap[:draws].any?
      end
      $live_at = Time.now
    end
    $live
  end
end

server = WEBrick::HTTPServer.new(Port: PORT, BindAddress: '0.0.0.0', AccessLog: [], Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN))

server.mount_proc('/snapshot.json') do |_req, res|
  res['Content-Type'] = 'application/json'
  res['Cache-Control'] = 'no-store'
  res.body = live_json
end

server.mount('/overlays', WEBrick::HTTPServlet::FileHandler, File.join(ROOT, 'public/overlays'))
server.mount('/facilities.json', WEBrick::HTTPServlet::FileHandler, File.join(ROOT, 'public/facilities.json'))
server.mount('/boundaries.json', WEBrick::HTTPServlet::FileHandler, File.join(ROOT, 'public/boundaries.json'))

server.mount_proc('/') do |req, res|
  if req.path == '/'
    res['Content-Type'] = 'text/html; charset=utf-8'
    res['Cache-Control'] = 'no-cache'
    res.body = HEAD + File.read(File.join(ROOT, 'public/index.html'))
  else
    res.status = 404
    res.body = 'Not found'
  end
end

trap('INT') { server.shutdown }
trap('TERM') { server.shutdown }
ip = Socket.ip_address_list.find { |a| a.ipv4_private? }&.ip_address
puts "Open http://localhost:#{PORT}"
puts "On a phone on the same Wi-Fi: http://#{ip}:#{PORT}" if ip
$stdout.flush
server.start
