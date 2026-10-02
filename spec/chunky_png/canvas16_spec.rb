require "spec_helper"

describe ChunkyPNG::Canvas16 do
  MODES = {
    ChunkyPNG::COLOR_GRAYSCALE => ->(value) { ChunkyPNG::Color16.grayscale(value) },
    ChunkyPNG::COLOR_GRAYSCALE_ALPHA => ->(value) { ChunkyPNG::Color16.grayscale_alpha(value, 65_535 - value) },
    ChunkyPNG::COLOR_TRUECOLOR => ->(value) { ChunkyPNG::Color16.rgb(value, value + 1, value + 2) },
    ChunkyPNG::COLOR_TRUECOLOR_ALPHA => ->(value) do
      ChunkyPNG::Color16.rgba(value, value + 1, value + 2, 65_535 - value)
    end,
  }.freeze

  [
    ChunkyPNG::FILTER_NONE,
    ChunkyPNG::FILTER_SUB,
    ChunkyPNG::FILTER_UP,
    ChunkyPNG::FILTER_AVERAGE,
    ChunkyPNG::FILTER_PAETH,
  ].each do |filter|
    MODES.each do |color_mode, pixel_for|
      it "preserves adjacent 16-bit samples for color mode #{color_mode} with filter #{filter}" do
        pixels = [100, 101, 102, 103].map(&pixel_for)
        canvas = described_class.new(2, 2, pixels)

        blob = canvas.to_blob(color_mode: color_mode, filtering: filter)
        datastream = ChunkyPNG::Datastream.from_blob(blob)

        expect(datastream.header_chunk.depth).to eql(16)
        expect(described_class.from_datastream(datastream).pixels).to eql(pixels)
      end
    end
  end

  MODES.each do |color_mode, pixel_for|
    it "preserves every sample for color mode #{color_mode} through Adam7 interlacing" do
      pixels = (0...63).map { |index| pixel_for.call(1000 + index) }
      canvas = described_class.new(7, 9, pixels)

      decoded = described_class.from_blob(
        canvas.to_blob(color_mode: color_mode, interlace: true, filtering: ChunkyPNG::FILTER_PAETH)
      )

      expect(decoded.pixels).to eql(pixels)
    end

    [[1, 1], [1, 2], [2, 1], [2, 2]].each do |width, height|
      it "preserves color mode #{color_mode} through empty Adam7 passes at #{width}x#{height}" do
        pixels = (0...(width * height)).map { |index| pixel_for.call(1000 + index) }
        canvas = described_class.new(width, height, pixels)

        decoded = described_class.from_blob(canvas.to_blob(
          color_mode: color_mode,
          interlace: true,
          filtering: ChunkyPNG::FILTER_PAETH
        ))

        expect(decoded.pixels).to eql(pixels)
      end
    end
  end

  it "compares grayscale transparency keys using the original 16-bit sample" do
    canvas = described_class.from_file(png_suite_file(:transparency, "tbwn1g16.png"))
    transparent = canvas.pixels.find { |pixel| ChunkyPNG::Color16.a(pixel).zero? }
    opaque = canvas.pixels.find { |pixel| ChunkyPNG::Color16.a(pixel) == 65_535 }

    expect(ChunkyPNG::Color16.r(transparent)).to eql(32_639)
    expect(ChunkyPNG::Color16.r(opaque)).to_not eql(32_639)
  end

  it "does not confuse a grayscale key with an adjacent 16-bit sample" do
    key = 0x7f7f
    canvas = described_class.new(1, 2, [
      ChunkyPNG::Color16.grayscale(key),
      ChunkyPNG::Color16.grayscale(key + 1),
    ])
    datastream = ChunkyPNG::Datastream.from_blob(
      canvas.to_blob(
        color_mode: ChunkyPNG::COLOR_GRAYSCALE,
        filtering: ChunkyPNG::FILTER_PAETH,
        interlace: true
      )
    )
    datastream.transparency_chunk = ChunkyPNG::Chunk::Transparency.new("tRNS", [key].pack("n"))
    decoded = described_class.from_datastream(datastream)

    expect(ChunkyPNG::Color16.a(decoded[0, 0])).to eql(0)
    expect(ChunkyPNG::Color16.r(decoded[0, 0])).to eql(key)
    expect(ChunkyPNG::Color16.a(decoded[0, 1])).to eql(65_535)
    expect(ChunkyPNG::Color16.r(decoded[0, 1])).to eql(key + 1)
  end

  it "compares RGB transparency keys using the original 16-bit samples" do
    canvas = described_class.from_file(png_suite_file(:transparency, "tbbn2c16.png"))
    transparent = canvas.pixels.find { |pixel| ChunkyPNG::Color16.a(pixel).zero? }
    opaque = canvas.pixels.find { |pixel| ChunkyPNG::Color16.a(pixel) == 65_535 }

    expect(ChunkyPNG::Color16.to_truecolor_bytes(transparent)).to eql([32_639, 32_639, 32_639])
    expect(ChunkyPNG::Color16.to_truecolor_bytes(opaque)).to_not eql([32_639, 32_639, 32_639])
  end

  it "does not confuse an RGB key with adjacent 16-bit samples" do
    key = ChunkyPNG::Color16.rgb(0x7f7f, 0x7f80, 0x7f81)
    nearby = ChunkyPNG::Color16.rgb(0x7f80, 0x7f81, 0x7f82)
    canvas = described_class.new(1, 2, [key, nearby])
    datastream = ChunkyPNG::Datastream.from_blob(
      canvas.to_blob(
        color_mode: ChunkyPNG::COLOR_TRUECOLOR,
        filtering: ChunkyPNG::FILTER_PAETH,
        interlace: true
      )
    )
    datastream.transparency_chunk = ChunkyPNG::Chunk::Transparency.new("tRNS", [0x7f7f, 0x7f80, 0x7f81].pack("n3"))
    decoded = described_class.from_datastream(datastream)

    expect(ChunkyPNG::Color16.a(decoded[0, 0])).to eql(0)
    expect(ChunkyPNG::Color16.to_truecolor_bytes(decoded[0, 0])).to eql([0x7f7f, 0x7f80, 0x7f81])
    expect(decoded[0, 1]).to eql(nearby)
  end

  it "converts to and from the original 8-bit canvas API" do
    canvas8 = ChunkyPNG::Canvas.new(1, 2, [
      ChunkyPNG::Color.rgba(0, 1, 254, 255),
      ChunkyPNG::Color.grayscale_alpha(128, 64),
    ])

    canvas16 = described_class.from_canvas(canvas8)

    expect(canvas16.pixels).to eql([
      ChunkyPNG::Color16.rgba(0x0000, 0x0101, 0xfefe, 0xffff),
      ChunkyPNG::Color16.grayscale_alpha(0x8080, 0x4040),
    ])
    expect(canvas16.to_canvas.pixels).to eql(canvas8.pixels)
    expect(canvas16.to_canvas(:truncate).pixels).to eql(canvas8.pixels)
  end

  it "preserves metadata through Image16" do
    image = ChunkyPNG::Image16.new(
      1,
      1,
      ChunkyPNG::Color16::WHITE,
      "Title" => "Deep PNG"
    )

    decoded = ChunkyPNG::Image16.from_blob(image.to_blob(color_mode: ChunkyPNG::COLOR_GRAYSCALE))

    expect(decoded).to be_a(ChunkyPNG::Image16)
    expect(decoded.metadata).to eql("Title" => "Deep PNG")
    expect(decoded.pixels).to eql(image.pixels)
  end

  describe ChunkyPNG::Color16 do
    it "packs and extracts four 16-bit samples" do
      color = described_class.rgba(0x0001, 0x0100, 0xff00, 0x00ff)

      expect(described_class.r(color)).to eql(0x0001)
      expect(described_class.g(color)).to eql(0x0100)
      expect(described_class.b(color)).to eql(0xff00)
      expect(described_class.a(color)).to eql(0x00ff)
    end

    it "uses PNG bit replication to convert 8-bit samples to 16-bit samples" do
      expect(described_class.from_8bit(0x00)).to eql(0x0000)
      expect(described_class.from_8bit(0x01)).to eql(0x0101)
      expect(described_class.from_8bit(0xff)).to eql(0xffff)
    end

    it "uses round-to-nearest to convert 16-bit samples to 8-bit samples" do
      expect(described_class.to_8bit(0x0000)).to eql(0x00)
      expect(described_class.to_8bit(0x00ff)).to eql(0x01)
      expect(described_class.to_8bit(0x0100)).to eql(0x01)
      expect(described_class.to_8bit(0xfefe)).to eql(0xfe)
      expect(described_class.to_8bit(0xfeff)).to eql(0xfe)
      expect(described_class.to_8bit(0xff7f)).to eql(0xff)
      expect(described_class.to_8bit(0xffff)).to eql(0xff)
    end

    it "exposes the legacy high-byte 16-to-8-bit rule separately" do
      expect(described_class.to_8bit_truncated(0x00ff)).to eql(0x00)
      expect(described_class.to_8bit_truncated(0xfeff)).to eql(0xfe)
    end

    it "converts complete 8-bit and 16-bit colors with explicit rules" do
      color8 = ChunkyPNG::Color.rgba(0, 1, 254, 255)
      color16 = described_class.rgba(0x0000, 0x0101, 0xfefe, 0xffff)

      expect(described_class.from_color(color8)).to eql(color16)
      expect(described_class.to_color(color16)).to eql(color8)
    end
  end
end
