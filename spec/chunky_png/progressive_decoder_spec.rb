require "spec_helper"

describe ChunkyPNG::ProgressiveDecoder do
  include ChunkyPNG::Canvas::Adam7Interlacing

  let(:datastream) { ChunkyPNG::Datastream.from_file(resource_file("adam7.png")) }
  let(:idat_data) { datastream.data_chunks.map(&:content).join }
  let(:reference) { ChunkyPNG::Canvas.from_file(resource_file("adam7.png")) }

  def decode_in_chunks(ds, chunks)
    decoder = ChunkyPNG::ProgressiveDecoder.from_datastream(ds)
    events = []
    chunks.each { |chunk| events.concat(decoder << chunk) }
    events.concat(decoder.finish)
    events
  end

  def split_bytes(data, chunk_size)
    data.bytes.each_slice(chunk_size).map { |bytes| bytes.pack("C*") }
  end

  def expected_canvas(pass_numbers)
    canvas = ChunkyPNG::Canvas.new(reference.width, reference.height)
    pass_numbers.each { |pass| adam7_merge_pass(pass, canvas, adam7_extract_pass(pass, reference)) }
    canvas
  end

  def expected_mask(width, height, pass_numbers)
    mask = Array.new(height) { Array.new(width, false) }
    pass_numbers.each do |pass|
      x_shift, x_offset, y_shift, y_offset = adam7_multiplier_offset(pass)
      y_offset.step(height - 1, 1 << y_shift) do |y|
        x_offset.step(width - 1, 1 << x_shift) do |x|
          mask[y][x] = true
        end
      end
    end
    mask
  end

  describe "decoding the reference Adam7 image" do
    it "emits one event per pass, in pass order" do
      events = decode_in_chunks(datastream, [idat_data])
      expect(events.map(&:pass)).to eql (0..6).to_a
    end

    it "produces snapshots that match the progressively merged passes" do
      events = decode_in_chunks(datastream, [idat_data])
      events.each do |event|
        expect(event.snapshot.pixels).to eql expected_canvas(0..event.pass).pixels
      end
    end

    it "produces masks that mark exactly the pixels of the completed passes" do
      events = decode_in_chunks(datastream, [idat_data])
      events.each do |event|
        expect(event.mask).to eql expected_mask(reference.width, reference.height, 0..event.pass)
      end
    end

    it "decodes the same image as regular decoding after the final pass" do
      events = decode_in_chunks(datastream, [idat_data])
      expect(events.last.snapshot.pixels).to eql reference.pixels
      expect(events.last.mask).to all(satisfy { |row| row.all? })
    end

    it "keeps the first pass snapshot unchanged after decoding to the end" do
      events = decode_in_chunks(datastream, [idat_data])
      expect(events.first.snapshot.pixels).to eql expected_canvas(0..0).pixels
      expect(events.first.snapshot.pixels).not_to eql events.last.snapshot.pixels
      expect(events.first.mask.flatten.count(true)).to eql 1
    end

    it "supports feeding the data byte by byte" do
      events = decode_in_chunks(datastream, split_bytes(idat_data, 1))
      expect(events.map(&:pass)).to eql (0..6).to_a
      expect(events.last.snapshot.pixels).to eql reference.pixels
    end

    it "produces the same result when the input is split at any byte position" do
      0.upto(idat_data.bytesize) do |split|
        chunks = [idat_data[0...split], idat_data[split..-1]]
        events = decode_in_chunks(datastream, chunks)
        expect(events.map(&:pass)).to eql (0..6).to_a
        expect(events.last.snapshot.pixels).to eql reference.pixels
      end
    end
  end

  describe "partial scanlines" do
    let(:pixelstream) { Zlib::Inflate.inflate(idat_data) }

    def pass_bytesize(pass)
      width, height = adam7_pass_size(pass, 8, 8)
      ChunkyPNG::Color.pass_bytesize(ChunkyPNG::COLOR_INDEXED, 8, width, height)
    end

    def recompress(cut)
      zstream = Zlib::Deflate.new
      chunks = [
        zstream.deflate(pixelstream[0...cut], Zlib::FULL_FLUSH),
        zstream.deflate(pixelstream[cut..-1], Zlib::FINISH),
      ]
      zstream.close
      chunks
    end

    it "does not complete a pass before its final scanline is fully received" do
      # Pass 0 of the 8x8 image consists of a single 2-byte scanline.
      expect(pass_bytesize(0)).to eql 2
      partial, rest = recompress(pass_bytesize(0) - 1)

      decoder = ChunkyPNG::ProgressiveDecoder.from_datastream(datastream)
      expect(decoder << partial).to be_empty

      events = decoder << rest
      events.concat(decoder.finish)
      expect(events.map(&:pass)).to eql (0..6).to_a
    end

    it "does not complete a pass when only some of its scanlines are decoded" do
      # Pass 3 consists of 2 scanlines; feed all data up to and including
      # its first scanline.
      cut = pass_bytesize(0) + pass_bytesize(1) + pass_bytesize(2)
      cut += ChunkyPNG::Color.scanline_bytesize(ChunkyPNG::COLOR_INDEXED, 8, 2) + 1
      first, rest = recompress(cut)

      decoder = ChunkyPNG::ProgressiveDecoder.from_datastream(datastream)
      events = decoder << first
      expect(events.map(&:pass)).to eql [0, 1, 2]

      events = decoder << rest
      events.concat(decoder.finish)
      expect(events.map(&:pass)).to eql [3, 4, 5, 6]
    end
  end

  describe "images with empty passes" do
    let(:tiny_datastream) { ChunkyPNG::Datastream.from_file(png_suite_file("sizes", "s01i3p01.png")) }
    let(:tiny_reference) { ChunkyPNG::Canvas.from_file(png_suite_file("sizes", "s01i3p01.png")) }

    it "advances through the empty passes and emits events for all 7 passes" do
      data = tiny_datastream.data_chunks.map(&:content).join
      events = decode_in_chunks(tiny_datastream, split_bytes(data, 2))
      expect(events.map(&:pass)).to eql (0..6).to_a
    end

    it "produces the complete image after the first pass already" do
      data = tiny_datastream.data_chunks.map(&:content).join
      events = decode_in_chunks(tiny_datastream, [data])
      events.each do |event|
        expect(event.snapshot.pixels).to eql tiny_reference.pixels
        expect(event.mask).to eql [[true]]
      end
    end
  end

  describe "decoding different image types" do
    files = %w[
      basi0g01 basi0g02 basi0g04 basi0g08 basi0g16
      basi2c08 basi2c16
      basi3p01 basi3p02 basi3p04 basi3p08
      basi4a08 basi4a16 basi6a08 basi6a16
    ]

    files.each do |file|
      it "decodes #{file}.png to the same image as regular decoding" do
        ds = ChunkyPNG::Datastream.from_file(png_suite_file("basic", "#{file}.png"))
        data = ds.data_chunks.map(&:content).join
        events = decode_in_chunks(ds, split_bytes(data, 5))

        expect(events.map(&:pass)).to eql (0..6).to_a
        expect(events.last.snapshot.pixels).to eql ChunkyPNG::Canvas.from_file(png_suite_file("basic", "#{file}.png")).pixels
        expect(events.last.mask).to all(satisfy { |row| row.all? })
      end
    end
  end

  describe "#on_pass_complete" do
    it "calls the callback for every completed pass" do
      decoder = ChunkyPNG::ProgressiveDecoder.from_datastream(datastream)
      passes = []
      decoder.on_pass_complete { |event| passes << event.pass }

      returned = decoder << idat_data
      returned.concat(decoder.finish)

      expect(passes).to eql (0..6).to_a
      expect(returned.map(&:pass)).to eql passes
    end
  end

  describe "error handling" do
    it "raises for images that are not Adam7 interlaced" do
      ds = ChunkyPNG::Datastream.from_file(png_suite_file("basic", "basn2c08.png"))
      expect { ChunkyPNG::ProgressiveDecoder.from_datastream(ds) }.to raise_error(ChunkyPNG::NotSupported)
    end

    it "raises when the stream ends before all passes are decoded" do
      decoder = ChunkyPNG::ProgressiveDecoder.from_datastream(datastream)
      decoder << idat_data[0, 10]
      expect { decoder.finish }.to raise_error(StandardError)
    end

    it "raises when data is added after the stream has finished" do
      decoder = ChunkyPNG::ProgressiveDecoder.from_datastream(datastream)
      decoder << idat_data
      decoder.finish

      expect(decoder).to be_finished
      expect { decoder << "more data" }.to raise_error(ChunkyPNG::ExpectationFailed)
      expect { decoder.finish }.to raise_error(ChunkyPNG::ExpectationFailed)
    end
  end
end
