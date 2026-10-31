# Pulls vacancy draw lists and hunt results from wildlife.ca.gov into plain data.
require 'net/http'
require 'uri'
require 'json'
require 'time'
require_relative 'pdf_text'

module Cdfw
  UA = 'CA-Refuge-Draw-Prototype/0.1'.freeze
  DRAW_PAGES = %w[Kesterson Los-Banos Salt-Slough Wister San-Jacinto Yolo Sacramento Colusa Delevan Sutter].freeze
  RESULTS_PAGE = 'https://wildlife.ca.gov/Hunting/Waterfowl'.freeze
  HARVEST_FILES = 40
  SEED_BUTTE = [247917, 247918].freeze

  module_function

  def get(url, limit = 5)
    raise 'too many redirects' if limit.zero?
    uri = URI(url)
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 15, read_timeout: 30) do |h|
      h.get(uri.request_uri, 'User-Agent' => UA)
    end
    return get(URI.join(url, res['location']).to_s, limit - 1) if res.is_a?(Net::HTTPRedirection)
    raise "#{res.code} from #{url}" unless res.is_a?(Net::HTTPSuccess)
    res.body
  end

  def doc_url(id)
    "https://nrm.dfg.ca.gov/FileHandler.ashx?DocumentID=#{id}&inline"
  end

  def doc_links(html)
    html.force_encoding('UTF-8').scrub.scan(/<a[^>]*href="[^"]*DocumentID=(\d+)[^"]*"[^>]*>(.*?)<\/a>/mi).map do |id, text|
      [id, text.gsub(/<[^>]+>/, ' ').gsub('&nbsp;', ' ').gsub(/\(external link\)/i, '').gsub(/\s+/, ' ').strip]
    end
  end

  # A label reads like "October 31, 2026 - Kesterson ADA (PDF)". Returns "Kesterson ADA".
  def draw_key(label)
    label.sub(/\(PDF\)/i, '').sub(/\A.*?\s-\s+/, '').strip
  end

  # Wister labels vary from year to year, so that page always maps to one key.
  def key_for(slug, label)
    slug == 'Wister' ? 'Wister' : draw_key(label)
  end

  def parse_draw(pdf)
    rows = PdfText.rows(pdf)
    head = rows.flatten.join(' ')
    hunt = head[%r{Hunt Date\s+(\d+/\d+/\d+)}, 1]
    done = head[%r{Draw Completed Date\s+(\d+/\d+/\d+)}, 1]
    entries = rows.select { |r| r[0].to_s.start_with?('VDR-') && r.size >= 3 }
                  .map { |r| [r[0], r[1].to_i, r[2].to_i] }
                  .sort_by { |e| e[1] }
    { area: rows.first&.join(' '), huntDate: hunt, drawDate: done, entries: entries }
  end

  def draws(errors)
    DRAW_PAGES.flat_map do |slug|
      page = "https://wildlife.ca.gov/Fill-in-Draw/#{slug}"
      begin
        # Pages list newest first, so the first link for each key is the latest list.
        doc_links(get(page)).uniq { |_, l| key_for(slug, l) }.map do |id, label|
          begin
            parse_draw(get(doc_url(id))).merge(key: key_for(slug, label), label: label, page: page, url: doc_url(id))
          rescue StandardError => e
            errors << "#{label}: #{e.message}"
            nil
          end
        end.compact
      rescue StandardError => e
        errors << "#{slug}: #{e.message}"
        []
      end
    end
  end

  # Upper Butte Basin's lists aren't linked from a page we can find. CDFW uploads them
  # beside the Wister and San Jacinto lists, so check IDs near the newest known one.
  def butte_basin(known, errors)
    prior = begin
      JSON.parse(File.read(File.join(__dir__, '../data/snapshot.json')))['draws'].to_a
          .select { |d| d['key'] =~ /Howard|Little Dry/ }.map { |d| d['url'][/DocumentID=(\d+)/, 1].to_i }
    rescue StandardError
      []
    end
    newest = known.map { |d| d[:url][/DocumentID=(\d+)/, 1].to_i }.max.to_i
    ids = (SEED_BUTTE + prior + ((newest - 8)..(newest + 12)).to_a).uniq
    found = ids.map do |id|
      begin
        d = parse_draw(get(doc_url(id)))
        next unless d[:huntDate] && d[:area].to_s =~ /Upper Butte/
        key = d[:area] =~ /Howard/ ? 'Howard Slough' : 'Little Dry Creek'
        d.merge(key: key, label: d[:area], page: nil, url: doc_url(id))
      rescue StandardError
        nil
      end
    end.compact
    date = ->(d) { m, day, y = d[:huntDate].split('/').map(&:to_i); [y, m, day] }
    found.group_by { |d| d[:key] }.flat_map do |_, list|
      latest = list.map(&date).max
      list.select { |d| date.call(d) == latest }.sort_by { |d| -d[:entries].size }
    end
  rescue StandardError => e
    errors << "Upper Butte Basin: #{e.message}"
    []
  end

  def parse_harvest(pdf)
    PdfText.rows(pdf).select { |r| r.size >= 6 && r[1] =~ %r{\A\d+/\d+\z} }.map do |r|
      { area: r[0], date: r[1], hunters: r[2].to_i, ducks: r[3].to_i, geese: r[4].to_i, birds: r[5].to_i,
        avg: r[8] && r[8] =~ /\A[\d.]+\z/ ? r[8].to_f : nil, top: r[9..10].to_a.compact }
    end
  end

  LAST_SEASON_DOC = 247256

  def area_key(name)
    name.to_s.upcase.sub('(NO.GL)', '(N GRASSLANDS)').sub('DRY CK.', 'DRY CREEK').strip
  end

  # Totals for each area from CDFW's full-season results file.
  def last_season
    rows = parse_harvest(get(doc_url(LAST_SEASON_DOC))).uniq { |r| [area_key(r[:area]), r[:date]] }
    rows.select { |r| r[:hunters] > 0 }.group_by { |r| area_key(r[:area]) }.map do |key, list|
      species = Hash.new(0)
      list.each { |r| r[:top].uniq.each { |s| species[s] += 1 if s =~ /\A[A-Z]{4}\z/ } }
      [key, { days: list.size, hunters: list.sum { |r| r[:hunters] }, ducks: list.sum { |r| r[:ducks] }, geese: list.sum { |r| r[:geese] },
              birds: list.sum { |r| r[:birds] }, species: species }]
    end.to_h
  end

  def harvest(errors)
    links = doc_links(get(RESULTS_PAGE)).select { |_, l| l =~ /\b(Sep|Oct|Nov|Dec|Jan|Feb)\w*\.?\s+\d+.*20(26|27)/i }.first(HARVEST_FILES)
    rows = links.flat_map do |id, label|
      begin
        parse_harvest(get(doc_url(id)))
      rescue StandardError => e
        errors << "#{label}: #{e.message}"
        []
      end
    end
    { files: links.map { |id, l| { label: l, url: doc_url(id) } }, rows: rows.uniq { |r| [r[:area], r[:date]] } }
  rescue StandardError => e
    errors << "hunt results: #{e.message}"
    { files: [], rows: [] }
  end

  def snapshot
    errors = []
    found = draws(errors)
    { fetchedAt: Time.now.utc.iso8601, draws: found + butte_basin(found, errors), harvest: harvest(errors), errors: errors }
  end
end
