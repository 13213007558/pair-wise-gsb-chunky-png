# frozen_string_literal: true

require "spec_helper"

describe ChunkyPNG::Canvas16 do
  let(:color) { ChunkyPNG::Color16 }

  describe ChunkyPNG::Color16 do
    it "packs and unpacks four 16-bit samples" do
      value = color.rgba(0x0001, 0x0102, 0x7fff, 0xffff)
      expect([color.r(value), color.g(value), color.b(value), color.a(value)]).to eql [0x0001, 0x0102, 0x7fff, 0xffff]
    end

    it "expands 8-bit samples by duplicating the byte" do
      expect(color.from_8bit(0x00)).to eql 0x0000
      expect(color.from_8bit(0x01)).to eql 0x0101
      expect(color.from_8bit(0x7f)).to eql 0x7f7f
      expect(color.from_8bit(0xff)).to eql 0xffff
    end

    it "reduces 16-bit samples using nearest-integer scaling with halves rounded up" do
      expect(color.to_8bit(0x0000)).to eql 0x00
      expect(color.to_8bit(0x0080)).to eql 0x00
      expect(color.to_8bit(0x0081)).to eql 0x01
      expect(color.to_8bit(0x7fff)).to eql 0x7f
      expect(color.to_8bit(0x8001)).to eql 0x80
      expect(color.to_8bit(0x8080)).to eql 0x80
      expect(color.to_8bit(0xffff)).to eql 0xff
    end

    it "converts complete RGBA colors in both directions using the documented rules" do
      value8 = ChunkyPNG::Color.rgba(1, 2, 3, 255)
      value16 = color.from_color(value8)
      samples = [color.r(value16), color.g(value16), color.b(value16), color.a(value16)]
      expect(samples).to eql [0x0101, 0x0202, 0x0303, 0xffff]
      expect(color.to_color(color.rgba(0x0080, 0x0081, 0x8001, 0xffff))).to eql ChunkyPNG::Color.rgba(0, 1, 128, 255)
    end
  end

  describe "PNG round trips" do
    let(:modes) do
      {
        ChunkyPNG::COLOR_GRAYSCALE => proc { |index| color.grayscale(0x0100 + index) },
        ChunkyPNG::COLOR_GRAYSCALE_ALPHA => proc { |index| color.grayscale_alpha(0x0100 + index, 0xfffc - index) },
        ChunkyPNG::COLOR_TRUECOLOR => proc { |index| color.rgb(0x0100 + index, 0x0101 + index, 0x0102 + index) },
        ChunkyPNG::COLOR_TRUECOLOR_ALPHA => proc do |index|
          color.rgba(0x0100 + index, 0x0101 + index, 0x0102 + index, 0x0103 + index)
        end
      }
    end

    let(:filters) do
      [
        ChunkyPNG::FILTER_NONE,
        ChunkyPNG::FILTER_SUB,
        ChunkyPNG::FILTER_UP,
        ChunkyPNG::FILTER_AVERAGE,
        ChunkyPNG::FILTER_PAETH
      ]
    end

    it "preserves every sample for all direct color modes, filters and Adam7" do
      modes.each do |color_mode, factory|
        pixels = 8.times.map { |index| factory.call(index) }
        canvas = described_class.new(4, 2, pixels)

        filters.each do |filtering|
          blob = canvas.to_blob(
            color_mode: color_mode,
            bit_depth: 16,
            filtering: filtering,
            interlace: false,
            compression: Zlib::NO_COMPRESSION
          )
          datastream = ChunkyPNG::Datastream.from_blob(blob)
          expect(datastream.header_chunk.depth).to eql 16
          expect(described_class.from_datastream(datastream).pixels).to eql pixels
        end

        blob = canvas.to_blob(
          color_mode: color_mode,
          bit_depth: 16,
          filtering: ChunkyPNG::FILTER_PAETH,
          interlace: true,
          compression: Zlib::NO_COMPRESSION
        )
        datastream = ChunkyPNG::Datastream.from_blob(blob)
        expect(datastream.header_chunk.interlace).to eql ChunkyPNG::INTERLACING_ADAM7
        expect(described_class.from_datastream(datastream).pixels).to eql pixels
      end
    end

    it "keeps samples whose high bytes are equal but low bytes differ by one" do
      pixels = [
        color.rgba(0x0100, 0x0200, 0x0300, 0x0400),
        color.rgba(0x0101, 0x0201, 0x0301, 0x0401)
      ]
      canvas = described_class.new(2, 1, pixels)
      blob = canvas.to_blob(
        bit_depth: 16,
        color_mode: ChunkyPNG::COLOR_TRUECOLOR_ALPHA,
        filtering: ChunkyPNG::FILTER_PAETH,
        interlace: true
      )
      decoded = described_class.from_blob(blob)
      expect(decoded.pixels).to eql pixels
    end

    it "round trips an 8-bit direct PNG through the expanded 16-bit canvas" do
      pixels = [color.rgba(0x0000, 0x0101, 0x7f7f, 0xffff), color.rgba(0x8080, 0xfefe, 0xffff, 0x0101)]
      canvas = described_class.new(2, 1, pixels)
      blob = canvas.to_blob(bit_depth: 8, color_mode: ChunkyPNG::COLOR_TRUECOLOR_ALPHA)
      decoded = described_class.from_blob(blob)
      expect(decoded.pixels).to eql pixels
    end

    it "applies RGB transparency using the original 16-bit samples" do
      transparent = color.rgb(0x0100, 0x0201, 0x0302)
      opaque = color.rgb(0x0101, 0x0201, 0x0302)
      canvas = described_class.new(2, 1, [transparent, opaque])
      blob = canvas.to_blob(bit_depth: 16, color_mode: ChunkyPNG::COLOR_TRUECOLOR)

      datastream = ChunkyPNG::Datastream.from_blob(blob)
      datastream.transparency_chunk = ChunkyPNG::Chunk::Transparency.new("tRNS", [0x0100, 0x0201, 0x0302].pack("nnn"))
      datastream.transparency_chunk.instance_variable_set(:@type, "tRNS")

      decoded = described_class.from_datastream(datastream)
      expect(decoded.pixels).to eql [color::TRANSPARENT, opaque]
    end

    it "applies grayscale transparency using the original 16-bit sample" do
      transparent = color.grayscale(0x1234)
      opaque = color.grayscale(0x1235)
      canvas = described_class.new(2, 1, [transparent, opaque])
      blob = canvas.to_blob(bit_depth: 16, color_mode: ChunkyPNG::COLOR_GRAYSCALE)

      datastream = ChunkyPNG::Datastream.from_blob(blob)
      datastream.transparency_chunk = ChunkyPNG::Chunk::Generic.new("tRNS", [0x1234].pack("n"))

      decoded = described_class.from_datastream(datastream)
      expect(decoded.pixels).to eql [color::TRANSPARENT, opaque]
    end

    it "applies 8-bit RGB transparency against the unexpanded source key" do
      transparent = color.rgb(0x0101, 0x0202, 0x0303)
      opaque = color.rgb(0x0101, 0x0303, 0x0202)
      canvas = described_class.new(2, 1, [transparent, opaque])
      blob = canvas.to_blob(bit_depth: 8, color_mode: ChunkyPNG::COLOR_TRUECOLOR)

      datastream = ChunkyPNG::Datastream.from_blob(blob)
      datastream.transparency_chunk = ChunkyPNG::Chunk::Generic.new("tRNS", [1, 2, 3].pack("nnn"))

      decoded = described_class.from_datastream(datastream)
      expect(decoded.pixels).to eql [color::TRANSPARENT, opaque]
    end
  end

  describe "canvas precision conversion" do
    it "creates a 16-bit canvas from an 8-bit canvas and back with explicit rounding" do
      canvas8 = ChunkyPNG::Canvas.new(1, 2, [
        ChunkyPNG::Color.rgba(0, 1, 127, 255),
        ChunkyPNG::Color.rgba(128, 254, 255, 1)
      ])
      canvas16 = canvas8.to_canvas16
      expect(canvas16).to be_a(described_class)
      expect(canvas16.pixels).to eql [
        color.rgba(0x0000, 0x0101, 0x7f7f, 0xffff),
        color.rgba(0x8080, 0xfefe, 0xffff, 0x0101)
      ]
      expect(canvas16.to_canvas8.pixels).to eql canvas8.pixels
    end

    it "returns an equivalent 16-bit canvas without reducing an already 16-bit canvas" do
      canvas16 = described_class.new(1, 1, color.rgba(0x0100, 0x0201, 0x0302, 0x0403))
      expect(canvas16.to_canvas16.pixels).to eql canvas16.pixels
    end

    it "keeps the original 8-bit API's truncating 16-bit representation" do
      pixels = [color.rgb(0x0100, 0x0201, 0x0302), color.rgb(0x0101, 0x0202, 0x0303)]
      canvas16 = described_class.new(2, 1, pixels)
      blob = canvas16.to_blob(color_mode: ChunkyPNG::COLOR_TRUECOLOR, bit_depth: 16)
      canvas8 = ChunkyPNG::Canvas.from_blob(blob)
      expect(canvas8.pixels).to eql [
        ChunkyPNG::Color.rgb(1, 2, 3),
        ChunkyPNG::Color.rgb(1, 2, 3)
      ]
    end
  end

  it "rejects indexed images because they do not provide 16-bit direct samples" do
    source = ChunkyPNG::Canvas.from_file(png_suite_file("basic", "basn3p08.png"))
    expect { described_class.from_blob(source.to_blob) }.to raise_error(ChunkyPNG::NotSupported)
  end
end

describe ChunkyPNG::Image16 do
  it "reads and writes metadata with a 16-bit image" do
    image = described_class.new(1, 1, ChunkyPNG::Color16.rgb(0x0100, 0x0201, 0x0302), "Title" => "16-bit")
    decoded = described_class.from_blob(image.to_blob)
    expect(decoded).to be_a(described_class)
    expect(decoded.metadata).to eql("Title" => "16-bit")
    expect(decoded.pixels).to eql image.pixels
  end
end
