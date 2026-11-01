# Minimal, dependency-free PDF text extractor, for the simple tables CDFW publishes.
# Returns rows of text cells, top to bottom, left to right, one array per visual line.
require 'zlib'

module PdfText
  module_function

  def inflate(raw)
    Zlib::Inflate.inflate(raw)
  rescue Zlib::Error
    begin
      z = Zlib::Inflate.new
      out = z.inflate(raw)
      z.close
      out
    rescue Zlib::Error
      nil
    end
  end

  def objects(pdf)
    objs = {}
    # Direct objects
    pdf.scan(/(\d+) 0 obj(.*?)endobj/m) { |n, body| objs[n.to_i] = body }
    # Objects packed inside object streams
    objs.values.dup.each do |body|
      next unless body =~ %r{/Type\s*/ObjStm}
      data = stream_of(body) or next
      count = body[%r{/N\s+(\d+)}, 1].to_i
      first = body[%r{/First\s+(\d+)}, 1].to_i
      nums = data[0, first].split.map(&:to_i)
      count.times do |i|
        num, off = nums[i * 2], nums[i * 2 + 1]
        nxt = i + 1 < count ? nums[i * 2 + 3] : data.length - first
        objs[num] ||= data[first + off, nxt - off]
      end
    end
    objs
  end

  def stream_of(body)
    return nil unless (m = body.match(/stream\r?\n/))
    raw = body[m.end(0)..-1].sub(/\r?\n?endstream.*\z/m, '')
    body[0, m.begin(0)] =~ /FlateDecode/ ? inflate(raw) : raw
  end

  def cmap(text)
    map = {}
    text.scan(/beginbfchar(.*?)endbfchar/m) do |(sec)|
      sec.scan(/<(\h+)>\s*<(\h+)>/) { |a, b| map[a.hex] = utf16(b) }
    end
    text.scan(/beginbfrange(.*?)endbfrange/m) do |(sec)|
      sec.scan(/<(\h+)>\s*<(\h+)>\s*<(\h+)>/) do |a, b, c|
        (a.hex..b.hex).each_with_index { |code, i| map[code] = [c.hex + i].pack('U') }
      end
      sec.scan(/<(\h+)>\s*<\h+>\s*\[(.*?)\]/m) do |a, list|
        list.scan(/<(\h+)>/).each_with_index { |(u), i| map[a.hex + i] = utf16(u) }
      end
    end
    map
  end

  def utf16(hex)
    [hex].pack('H*').force_encoding('UTF-16BE').encode('UTF-8')
  rescue StandardError
    ''
  end

  def fonts_for(page, objs)
    res = page[%r{/Resources\s+(\d+) 0 R}, 1]
    scope = res ? objs[res.to_i].to_s : page
    fd = scope[%r{/Font\s*<<(.*?)>>}m, 1]
    unless fd
      ref = scope[%r{/Font\s+(\d+) 0 R}, 1]
      fd = objs[ref.to_i].to_s if ref
    end
    fonts = {}
    fd.to_s.scan(%r{/([\w.+-]+)\s+(\d+) 0 R}) do |name, n|
      tu = objs[n.to_i].to_s[%r{/ToUnicode\s+(\d+) 0 R}, 1]
      data = tu && stream_of(objs[tu.to_i].to_s)
      # Only composite fonts use two-byte codes. A simple font's cmap can still declare a <0000> <FFFF> range.
      fonts[name] = { map: data ? cmap(data) : nil, two: objs[n.to_i].to_s.b.match?(%r{/Subtype\s*/Type0}) }
    end
    fonts
  end

  def decode_literal(s)
    s.gsub(/\\([nrtbf()\\]|\d{1,3})/) do
      c = Regexp.last_match(1)
      case c
      when 'n' then "\n" when 'r' then "\r" when 't' then "\t"
      when 'b' then "\b" when 'f' then "\f"
      when /\d/ then c.oct.chr
      else c
      end
    end
  end

  def show(bytes, font)
    return bytes.encode('UTF-8', 'ISO-8859-1') unless font && font[:map]
    codes = font[:two] ? bytes.unpack('n*') : bytes.unpack('C*')
    codes.map { |c| font[:map][c] || '' }.join
  end

  def string_token(tok, font)
    bytes = tok.start_with?('<') ? [tok[1..-2].delete("^0-9A-Fa-f")].pack('H*') : decode_literal(tok[1..-2].b)
    show(bytes.b, font)
  end

  STR = /\((?:\\.|[^\\)])*\)|<\h*>/m

  # Walks one content stream, returning cells positioned on the page.
  def page_cells(content, fonts)
    cells = []
    font = nil
    lead = 0.0
    x = y = lx = ly = 0.0
    a = d = 1.0
    ctm = [[1.0, 1.0, 0.0, 0.0]]
    content = content.b
    tok = /\((?:\\.|[^\\)])*\)|<\h*>|\[(?:\((?:\\.|[^\\)])*\)|<\h*>|[^\]])*\]|\/[^\s\/\[\]()<>]+|[-+.\d]+|[A-Za-z'"*]+/m
    stack = []
    content.scan(tok) do
      t = Regexp.last_match(0)
      if t =~ /\A[A-Za-z'"*]+\z/
        case t
        when 'q' then ctm.push(ctm.last.dup)
        when 'Q' then ctm.pop if ctm.size > 1
        when 'cm'
          n = stack.last(6).map(&:to_f)
          if n.size == 6
            c = ctm.last
            ctm[-1] = [c[0] * n[0], c[1] * n[3], c[2] + c[0] * n[4], c[3] + c[1] * n[5]]
          end
        when 'BT' then x = y = lx = ly = 0.0; a = d = 1.0
        when 'Tf' then font = fonts[stack[-2].to_s.delete('/')]
        when 'TL' then lead = stack.last.to_f
        when 'Td', 'TD'
          n = stack.last(2).map(&:to_f)
          lead = -n[1] if t == 'TD'
          lx += n[0] * a; ly += n[1] * d; x = lx; y = ly
        when 'Tm'
          n = stack.last(6).map(&:to_f)
          a, d = n[0], n[3]; x = lx = n[4]; y = ly = n[5]
        when 'T*' then ly -= lead * d; x = lx; y = ly
        when 'Tj', "'", 'TJ'
          arg = stack.last.to_s
          if t == "'" then ly -= lead * d; x = lx; y = ly end
          text = arg.scan(STR).map { |s| string_token(s, font) }.join
          c = ctm.last
          cells << [c[2] + c[0] * x, c[3] + c[1] * y, text] unless text.strip.empty?
        end
        stack.clear
      else
        stack << t
      end
    end
    cells
  end

  # Positioned cells for each page, in file order.
  def page_list(pdf)
    pdf = pdf.b
    objs = objects(pdf)
    pages = objs.select { |_, b| b.to_s =~ %r{/Type\s*/Page(?![s\w])} }.sort_by { |n, _| [pdf.index("#{n} 0 obj") || 0, n] }
    pages.map do |_, page|
      fonts = fonts_for(page, objs)
      refs = page[%r{/Contents\s*\[(.*?)\]}m, 1]&.scan(/(\d+) 0 R/)&.flatten || [page[%r{/Contents\s+(\d+) 0 R}, 1]].compact
      page_cells(refs.map { |r| stream_of(objs[r.to_i].to_s) }.compact.join("\n"), fonts)
    end
  end

  # Merges cells sharing a baseline; adjoining cells only split when separated by a real gap.
  def rows(pdf)
    pdf = pdf.b
    objs = objects(pdf)
    pages = objs.select { |_, b| b.to_s =~ %r{/Type\s*/Page(?![s\w])} }.sort_by { |n, _| n }
    pages = pages.sort_by { |n, b| [pdf.index("#{n} 0 obj") || 0, n] }
    pages.flat_map do |_, page|
      fonts = fonts_for(page, objs)
      refs = page[%r{/Contents\s*\[(.*?)\]}m, 1]&.scan(/(\d+) 0 R/)&.flatten || [page[%r{/Contents\s+(\d+) 0 R}, 1]].compact
      data = refs.map { |r| stream_of(objs[r.to_i].to_s) }.compact.join("\n")
      page_cells(data, fonts)
        .group_by { |_, y, _| y.round }
        .sort_by { |y, _| -y }
        .map { |_, cs| cs.sort_by(&:first).map { |c| c[2].strip } }
    end
  end
end
