#!/usr/bin/ruby
# encoding: utf-8
# Builds map layers. Run this when hunt maps or boundaries change: ruby tools/overlays.rb
# - public/overlays/*.png and src/overlays.json: hunt map PDFs that carry GPS data (macOS sips renders them)
# - public/boundaries.json: official USFWS hunt units and CDFW wildlife area outlines
Encoding.default_external = 'UTF-8'
require 'fileutils'
require 'tmpdir'
require 'json'
require 'net/http'
require 'uri'
require_relative '../lib/pdf_text'

ROOT = File.expand_path('..', __dir__)
OUT = File.join(ROOT, 'public/overlays')
FileUtils.mkdir_p(OUT)
WIDTH = 2000

def fetch(url, limit = 5)
  uri = URI(url)
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 90) do |h|
    h.get(uri.request_uri, 'User-Agent' => 'Mozilla/5.0')
  end
  return fetch(URI.join(url, res['location']).to_s, limit - 1) if res.is_a?(Net::HTTPRedirection) && limit > 0
  raise "#{res.code} #{url}" unless res.is_a?(Net::HTTPSuccess)
  res.body
end

# Inverse UTM on GRS80, for the few PDFs that store projected coordinates.
def utm_to_latlng(north, east, zone)
  a = 6378137.0
  f = 1 / 298.257222101
  e2 = f * (2 - f)
  k0 = 0.9996
  x = east - 500000.0
  m = north / k0
  mu = m / (a * (1 - e2 / 4 - 3 * e2**2 / 64 - 5 * e2**3 / 256))
  e1 = (1 - Math.sqrt(1 - e2)) / (1 + Math.sqrt(1 - e2))
  p1 = mu + (3 * e1 / 2 - 27 * e1**3 / 32) * Math.sin(2 * mu) + (21 * e1**2 / 16 - 55 * e1**4 / 32) * Math.sin(4 * mu) +
       (151 * e1**3 / 96) * Math.sin(6 * mu)
  ep2 = e2 / (1 - e2)
  c1 = ep2 * Math.cos(p1)**2
  t1 = Math.tan(p1)**2
  n1 = a / Math.sqrt(1 - e2 * Math.sin(p1)**2)
  r1 = a * (1 - e2) / (1 - e2 * Math.sin(p1)**2)**1.5
  d = x / (n1 * k0)
  lat = p1 - (n1 * Math.tan(p1) / r1) * (d**2 / 2 - (5 + 3 * t1 + 10 * c1 - 4 * c1**2 - 9 * ep2) * d**4 / 24)
  lng = (d - (1 + 2 * t1 + c1) * d**3 / 6 + (5 - 2 * c1 + 28 * t1) * d**5 / 120) / Math.cos(p1)
  [lat * 180 / Math::PI, lng * 180 / Math::PI + (zone * 6 - 183)]
end

def nums(s)
  s.to_s.scan(/-?\d*\.?\d+/).map(&:to_f)
end

def resolve(objs, s)
  m = s.to_s.match(/\A\s*(\d+) 0 R/)
  m ? objs[m[1].to_i].to_s : s.to_s
end

# Least-squares affine from page points to lat/lng.
def fit(pts)
  solve = lambda do |idx|
    sxx = sxy = sx = syy = sy = sxv = syv = sv = 0.0
    pts.each do |p|
      x, y, v = p[0], p[1], p[2][idx]
      sxx += x * x; sxy += x * y; sx += x; syy += y * y; sy += y; sxv += x * v; syv += y * v; sv += v
    end
    n = pts.size.to_f
    det = sxx * (syy * n - sy * sy) - sxy * (sxy * n - sy * sx) + sx * (sxy * sy - syy * sx)
    a = (sxv * (syy * n - sy * sy) - sxy * (syv * n - sy * sv) + sx * (syv * sy - syy * sv)) / det
    b = (sxx * (syv * n - sy * sv) - sxv * (sxy * n - sy * sx) + sx * (sxy * sv - syv * sx)) / det
    c = (sxx * (syy * sv - sy * syv) - sxy * (sxy * sv - sx * syv) + sxv * (sxy * sy - syy * sx)) / det
    [a, b, c]
  end
  [solve.call(0), solve.call(1)]
end

# Finds the largest GPS-tagged viewport on the first page, in page coordinates.
def georef(pdf)
  objs = PdfText.objects(pdf)
  page = objs.values.map(&:to_s).find { |b| b.b =~ %r{/Type\s*/Page(?![s\w])} && b.b =~ %r{/VP\b} }
  return nil unless page
  page = page.b
  vp = page[%r{/VP\s*(\[.*\]|\d+ 0 R)}m, 1].to_s
  vp = objs[vp.to_i].to_s.b if vp =~ /\A\d+ 0 R/
  best = nil
  vp.split(/(?=<<\s*\/(?:BBox|Type\s*\/Viewport))/).each do |chunk|
    bbox = nums(chunk[%r{/BBox\s*\[(.*?)\]}m, 1])
    next unless bbox.size == 4
    ms = chunk[%r{/Measure\s+(\d+ 0 R)}, 1]
    meas = ms ? resolve(objs, ms).b : chunk
    gp = nums(meas[%r{/GPTS\s*\[(.*?)\]}m, 1])
    next if gp.size < 6
    lp = nums(meas[%r{/LPTS\s*\[(.*?)\]}m, 1])
    lp = nums(meas[%r{/Bounds\s*\[(.*?)\]}m, 1]) if lp.size != gp.size
    next unless lp.size == gp.size
    x0, x1 = [bbox[0], bbox[2]].minmax
    y0, y1 = [bbox[1], bbox[3]].minmax
    area = (x1 - x0) * (y1 - y0)
    next if best && best[:area] >= area
    gcs = meas[%r{/GCS\s+(\d+) 0 R}, 1]
    wkt = gcs ? objs[gcs.to_i].to_s.b : meas
    zone = wkt[/UTM[_ ]Zone[_ ](\d+)/i, 1].to_i
    latlng = gp.each_slice(2).map { |a, b| a.abs > 90 ? (zone > 0 ? utm_to_latlng(a, b, zone) : nil) : [a, b] }
    next if latlng.include?(nil)
    # PDFs write BBox corners in either order, and LPTS follow that order, so use it as written.
    pts = lp.each_slice(2).zip(latlng).map { |(u, v), g| [bbox[0] + u * (bbox[2] - bbox[0]), bbox[1] + v * (bbox[3] - bbox[1]), g] }
    best = { area: area, box: [x0, y0, x1, y1], pts: pts }
  end
  return nil unless best
  mb = nums(page[%r{/CropBox\s*\[(.*?)\]}m, 1])
  mb = nums(page[%r{/MediaBox\s*\[(.*?)\]}m, 1]) if mb.size != 4
  best.merge(media: mb, rotate: page[%r{/Rotate\s+(-?\d+)}, 1].to_i % 360)
end

refuges = JSON.parse(File.read(File.join(ROOT, 'src/refuges.json')))
done = {}
manifest = []
Dir.mktmpdir do |tmp|
  refuges.each do |r|
    r['maps'].reject { |m| m['label'] =~ /flood/i }.each do |m|
      url = m['url']
      unless done.key?(url)
        name = "map#{url[/DocumentID=(\d+)/, 1] || url.split('/').last.gsub(/\W+/, '')[0, 40]}"
        begin
          pdf = fetch(url)
          g = georef(pdf)
          if g && g[:media].size == 4
            src = File.join(tmp, "#{name}.pdf")
            File.binwrite(src, pdf)
            png = File.join(OUT, "#{name}.png")
            system('sips', '-s', 'format', 'png', '-Z', WIDTH.to_s, src, '--out', png, out: File::NULL, err: File::NULL)
            x0, y0, x1, y1 = g[:media]
            a = fit(g[:pts])
            ll = ->(x, y) { [(a[0][0] * x + a[0][1] * y + a[0][2]).round(6), (a[1][0] * x + a[1][1] * y + a[1][2]).round(6)] }
            # Image corners in page space, allowing for page rotation: top-left, top-right, bottom-left.
            corners = case g[:rotate]
                      when 90 then [[x0, y0], [x0, y1], [x1, y0]]
                      when 180 then [[x1, y0], [x0, y0], [x1, y1]]
                      when 270 then [[x1, y1], [x1, y0], [x0, y1]]
                      else [[x0, y1], [x1, y1], [x0, y0]]
                      end.map { |c| ll.call(*c) }
            raise 'map would be upside down' unless corners[0][0] > corners[2][0] && corners[1][1] > corners[0][1]
            bx0, by0, bx1, by1 = g[:box]
            w = x1 - x0
            h = y1 - y0
            sides = [(y1 - by1) / h, (x1 - bx1) / w, (by0 - y0) / h, (bx0 - x0) / w] # top right bottom left
            sides = sides.rotate(-(g[:rotate] / 90)) if g[:rotate] != 0
            done[url] = { img: "overlays/#{name}.png", corners: corners, clip: sides.map { |s| (s * 100).round(2) } }
            warn "ok   #{r['id']}: #{m['label']} rot=#{g[:rotate]} #{File.size(png) / 1024}KB"
          else
            done[url] = nil
            warn "none #{r['id']}: #{m['label']}"
          end
        rescue StandardError => e
          done[url] = nil
          warn "FAIL #{r['id']}: #{m['label']}: #{e.message}"
        end
      end
      manifest << { refuge: r['id'], label: m['label'] }.merge(done[url]) if done[url]
    end
  end
end
File.write(File.join(ROOT, 'src/overlays.json'), JSON.generate(manifest))

# Official boundaries
FWS = 'https://services.arcgis.com/QVENGdaPbd4LUkLV/arcgis/rest/services/FWS_National_Hunt_Units_2025-2026/FeatureServer/0/query'.freeze
CDFW = 'https://services2.arcgis.com/Uq9r85Potqm3MfRV/ArcGIS/rest/services/biosds3092_fpu/FeatureServer/0/query'.freeze
def geojson(base, where, fields)
  q = URI.encode_www_form(where: where, outFields: fields, returnGeometry: true, outSR: 4326, maxAllowableOffset: 0.00015, f: 'geojson', resultRecordCount: 500)
  JSON.parse(fetch("#{base}?#{q}"))['features']
end
def trim(g)
  g.is_a?(Array) ? (g.first.is_a?(Numeric) ? g.map { |n| n.round(5) } : g.map { |x| trim(x) }) : g
end
features = []
orgs = %w[Sacramento Delevan Colusa Sutter Kern].map { |n| "#{n} National Wildlife Refuge" } + ['San Luis National Wildlife Refuge', 'Merced National Wildlife Refuge']
where = "Organization_Name IN (#{orgs.map { |o| "'#{o}'" }.join(',')})"
geojson(FWS, where, 'Organization_Name,Hunt_Unit_Name,Huntable').each do |f|
  p = f['properties']
  closed = p['Huntable'] == 'No' || p['Hunt_Unit_Name'].to_s =~ /closed/i
  features << { type: 'Feature', geometry: { type: f['geometry']['type'], coordinates: trim(f['geometry']['coordinates']) },
                properties: { src: 'USFWS', area: p['Organization_Name'], unit: p['Hunt_Unit_Name'], status: closed ? 'closed' : 'open' } }
end
names = ['Ash Creek', 'Butte Valley', 'Gray Lodge', 'Grizzly Island', 'Honey Lake', 'Imperial', 'Los Banos', 'Mendota', 'North Grasslands',
         'San Jacinto', 'Shasta Valley', 'Upper Butte Basin', 'Volta', 'Willow Creek', 'Yolo Bypass'].map { |n| "#{n} Wildlife Area" }
geojson(CDFW, "Name IN (#{names.map { |n| "'#{n}'" }.join(',')})", 'Name').each do |f|
  next unless f['geometry']
  features << { type: 'Feature', geometry: { type: f['geometry']['type'], coordinates: trim(f['geometry']['coordinates']) },
                properties: { src: 'CDFW', area: f['properties']['Name'], unit: 'State wildlife area boundary', status: 'state' } }
end
File.write(File.join(ROOT, 'public/boundaries.json'), JSON.generate(type: 'FeatureCollection', features: features))
warn "overlays: #{done.values.compact.size} maps, boundaries: #{features.size} features, #{File.size(File.join(ROOT, 'public/boundaries.json')) / 1024} KB"
warn "no GPS overlay: #{refuges.reject { |r| manifest.any? { |m| m[:refuge] == r['id'] } }.map { |r| r['id'] }.join(', ')}"
