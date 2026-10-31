#!/usr/bin/ruby
# Pulls fresh CDFW data and writes the single-file site to public/index.html.
# Usage: ruby build.rb            (fetch, then build)
#        ruby build.rb --offline  (rebuild from data/snapshot.json)
Encoding.default_external = 'UTF-8'
require 'fileutils'
require_relative 'lib/cdfw'

ROOT = __dir__
SNAP = File.join(ROOT, 'data/snapshot.json')

FileUtils.mkdir_p(File.join(ROOT, 'data'))
FileUtils.mkdir_p(File.join(ROOT, 'public'))
unless ARGV.include?('--offline')
  snap = Cdfw.snapshot
  # Keep the last good copy if CDFW can't be reached.
  File.write(SNAP, JSON.generate(snap)) if snap[:draws].any?
  warn "draw lists: #{snap[:draws].size}, hunt rows: #{snap[:harvest][:rows].size}, errors: #{snap[:errors].size}"
  snap[:errors].each { |e| warn "  #{e}" }
end

last = File.join(ROOT, 'src/season_2025.json')
File.write(last, JSON.generate(Cdfw.last_season)) unless File.exist?(last)

safe = ->(s) { s.gsub('</', '<\/') }
html = File.read(File.join(ROOT, 'src/app.html'))
html = html.sub('/*LEAFLET_CSS*/') { File.read(File.join(ROOT, 'src/leaflet.css')) }
html = html.sub('/*REFUGES*/null') { safe.call(JSON.generate(JSON.parse(File.read(File.join(ROOT, 'src/refuges.json'))))) }
html = html.sub('/*LAST*/null') { safe.call(File.read(last)) }
html = html.sub('/*OVERLAYS*/null') { safe.call(File.read(File.join(ROOT, 'src/overlays.json'))) }
html = html.sub('/*SNAPSHOT*/null') { safe.call(File.read(SNAP)) }
File.write(File.join(ROOT, 'public/index.html'), html)
warn "wrote public/index.html (#{html.bytesize / 1024} KB)"

# A complete site folder for static hosting.
site = File.join(ROOT, 'site')
FileUtils.rm_rf(site)
FileUtils.mkdir_p(site)
head = '<!doctype html><html lang="en"><head><meta charset="utf-8">' \
       '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"></head><body>'
File.write(File.join(site, 'index.html'), head + html)
FileUtils.cp(File.join(ROOT, 'public/boundaries.json'), site)
FileUtils.cp_r(File.join(ROOT, 'public/overlays'), site)
