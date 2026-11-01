#!/usr/bin/ruby
# encoding: utf-8
# Reads USFWS blind-by-blind hunt results into public/blinds.json: ruby tools/blinds.rb
# Each day's blinds are checked against the Total row printed in the PDF.
Encoding.default_external = 'UTF-8'
require 'json'
require 'date'
require 'net/http'
require 'uri'
require_relative '../lib/pdf_text'

ROOT = File.expand_path('..', __dir__)
DOCS = 'https://www.fws.gov/sites/default/files/documents/'.freeze
FILES = {
  'sacramento' => { '2020-21' => 'Sacramento%20NWR%20Blind%20Averages%202020-21_508.pdf', '2019-20' => 'Sacramento%20NWR%20Blind%20Averages%202019-20_508.pdf' },
  'delevan' => { '2020-21' => 'Delevan%20NWR%20Pond%20Blind%20Averages_2020-21_508.pdf', '2019-20' => 'Delevan%20NWR%20Blinds%20AP%20season%20averages%202019-20_508.pdf' },
  'colusa' => { '2020-21' => 'Colusa%20NWR%20Pond%20Blind%20Averages%202020-21_508.pdf', '2019-20' => 'Colusa%20NWR%20POND%20averages%202019-20_508.pdf' },
  'sutter' => { '2020-21' => 'Sutter%20NWR%20Pond%20Blind%20Averages%202020-21_508.pdf', '2019-20' => 'Sutter%20NWR%20Pond%20Averages%202019-20_508.pdf' }
}.freeze
MONTHS = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec].freeze

def fetch(url, limit = 5)
  uri = URI(url)
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 90) { |h| h.get(uri.request_uri, 'User-Agent' => 'Mozilla/5.0') }
  return fetch(URI.join(url, res['location']).to_s, limit - 1) if res.is_a?(Net::HTTPRedirection) && limit > 0
  raise "#{res.code} #{url}" unless res.is_a?(Net::HTTPSuccess)
  res.body
end

def iso(label, season)
  d, m = label.split('-')
  n = MONTHS.index(m) + 1
  format('%04d-%02d-%02d', season[0, 4].to_i + (n >= 8 ? 0 : 1), n, d.to_i)
end

DATE = /(\d{1,2}-[A-Z][a-z]{2})/

# Cells on nearly the same baseline belong to one row, even if their y differs slightly.
def rows_of(cells)
  rows = []
  cells.sort_by { |_, y, _| -y }.each do |c|
    if rows.last && (rows.last.last[1] - c[1]).abs < 3
      rows.last << c
    else
      rows << [c]
    end
  end
  rows.map { |r| r.sort_by(&:first) }
end

# Returns { date => { entries: { blind => [hunters, birds] }, total: [hunters, birds], raw: hunters } }
def parse(pdf, season, name, log)
  days = {}
  pages = PdfText.page_list(pdf)
  title = pages.first.map { |c| c[2] }.join(' ')
  unless title =~ /#{name}\s+National Wildlife Refuge/i
    log << "file is titled for another refuge"
    return days
  end
  pages.each do |cells|
    rows = rows_of(cells)
    at = rows.index { |r| r.any? { |c| c[2] =~ /Hunters|Hntrs/ } } or next
    head = rows[at]
    dates = rows[0..at].flatten(1).select { |c| c[2] =~ DATE }
    prev_end = 0
    blocks = head.select { |c| c[2] =~ /Hunters|Hntrs/ }.map do |h|
      after = head.select { |c| c[0] > h[0] }
      birds = after.find { |c| c[2] =~ /Birds|Brds/ }
      avg = after.find { |c| c[2] =~ /Average|Avg/ }
      next unless birds && avg
      b = { from: prev_end, h: h[0], b: birds[0], a: avg[0] }
      prev_end = avg[0] + 30
      b
    end.compact
    blocks.each_with_index do |b, i|
      b[:to] = blocks[i + 1] ? blocks[i + 1][:from] : 10_000
      d = dates.find { |x, _, _| x >= b[:from] && x < b[:to] }
      b[:date] = d && iso(d[2][DATE, 1], season)
      days[b[:date]] ||= { entries: {}, total: nil, raw: 0 } if b[:date]
    end
    rows[(at + 1)..-1].to_a.each do |row|
      blocks.each do |b|
        next unless b[:date]
        inside = row.select { |x, _, _| x >= b[:from] && x < b[:to] }
        label = inside.find { |x, _, _| x < b[:h] - 4 } or next
        cell = ->(from, to) { (c = inside.find { |x, _, _| x >= from && x < to }) && c[2].strip }
        hs = cell.call(b[:h] - 4, b[:b] - 4)
        bs = cell.call(b[:b] - 4, b[:a] - 4)
        blind = label[2].strip.sub(/\A(P\d) ([A-Z])\z/, '\1\2')
        next unless blind =~ /\A[A-Za-z0-9 .-]{1,8}\z/
        day = days[b[:date]]
        if blind =~ /\ATotal/i
          day[:total] = [hs.to_i, bs.to_i]
        elsif hs =~ /\A\d+\z/ && hs.to_i > 0
          day[:raw] += hs.to_i
          # A blank bird count isn't zero, so that visit is left out.
          if bs =~ /\A\d+\z/
            day[:entries][blind] = [hs.to_i, bs.to_i]
          else
            log << "#{b[:date]} #{blind}: hunters but no bird count"
          end
        end
      end
    end
  end
  days
end

out = {}
FILES.each do |id, seasons|
  out[id] = []
  seasons.each do |season, file|
    log = []
    days = parse(fetch(DOCS + file), season, id.capitalize, log).reject { |_, d| d[:entries].empty? }
    days = days.sort.to_h
    bad = []
    off = []
    dropped = []
    prev = nil
    clean = {}
    days.each do |date, d|
      if prev && prev == d[:entries]
        dropped << "#{date} repeats the previous day"
        next
      end
      prev = d[:entries]
      if date[5, 2].to_i.between?(2, 7)
        dropped << "#{date} special hunt"
        next
      end
      sum = [d[:entries].values.sum(&:first), d[:entries].values.sum(&:last)]
      bad << "#{date} sum #{[d[:raw], sum[1]]} vs total #{d[:total]}" if d[:total] && [d[:raw], sum[1]] != d[:total]
      off << date unless [0, 3, 6].include?(Date.parse(date).wday)
      clean[date] = d[:entries]
    end
    if clean.empty?
      warn "#{id} #{season}: nothing usable (#{log.first})"
      next
    end
    names = clean.values.flat_map(&:keys).uniq
    dates = clean.keys
    out[id] << { season: season, url: DOCS + file, dates: dates,
                 blinds: names.map { |n| [n, dates.each_with_index.map { |dt, i| (e = clean[dt][n]) && [i, e[0], e[1]] }.compact] }.to_h,
                 dropped: dropped }
    warn "#{id} #{season}: #{dates.size} days, #{names.size} blinds, #{bad.size} total mismatches, dropped #{dropped.size}, blanks #{log.size}, off-day #{off.first(5)}"
    warn "   #{names.first(60).join(' ')}"
    bad.first(6).each { |b| warn "   #{b}" }
    dropped.first(4).each { |b| warn "   #{b}" }
  end
end
File.write(File.join(ROOT, 'public/blinds.json'), JSON.generate(out))
warn "wrote public/blinds.json (#{File.size(File.join(ROOT, 'public/blinds.json')) / 1024} KB)"
