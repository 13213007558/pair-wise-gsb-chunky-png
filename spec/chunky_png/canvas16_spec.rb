require "spec_helper"

describe ChunkyPNG::Canvas16 do
  let(:color_modes) do
    {
      ChunkyPNG::COLOR_GRAYSCALE => ->(values) { ChunkyPNG::Color16.grayscale(values.first) },
      ChunkyPNG::COLOR_GRAYSCALE_ALPHA => ->(values) { ChunkyPNG::Color16.grayscale_alpha(*values) },
      ChunkyPNG::COLOR_TRUECOLOR => ->(values) { ChunkyPNG::Color16.rgb(*values) },
      ChunkyPNG::COLOR_TRUECOLOR_ALPHA => ->(values) { ChunkyPNG::Color16.rgba(*values) },
    }
  end

  describe "16-bit color values" do
    it "keeps RGBA components separate from 8-bit integer colors" do
      pixel = ChunkyPNG::Color16.rgba(0x0100, 0x0101, 0x0181, 0xffff)

      expect(ChunkyPNG::Color16.r(pixel)).to eql 0x0100
      expect(ChunkyPNG::Color16.g(pixel)).to eql 0x0101
      expect(ChunkyPNG::Color16.b(pixel)).to eql 0x0181
      expect(ChunkyPNG::Color16.a(pixel)).to eql 0xffff
      expect(pixel).to_not eql ChunkyPNG::Color.rgba(1, 1, 1, 255)
    end

    it "only converts between 8-bit and 16-bit representations explicitly" do
      canvas8 = ChunkyPNG::Canvas.new(1, 1, ChunkyPNG::Color.rgb(255, 254, 253))
      canvas16 = ChunkyPNG::Canvas16.from_canvas(canvas8)

      expect(canvas16[0, 0]).to eql ChunkyPNG::Color16.rgb(65535, 65278, 65021)
      expect(canvas16).to_not eql canvas8
      expect(canvas16.to_canvas).to eql canvas8
    end

    it "uses the caller-selected rounding rule when converting to 8-bit colors" do
      canvas = ChunkyPNG::Canvas16.new(1, 2, [
        ChunkyPNG::Color16.rgb(0x0100, 0x0100, 0x0100),
        ChunkyPNG::Color16.rgb(0x0182, 0x0182, 0x0182),
      ])

      truncated = canvas.to_canvas(rounding: :truncate)
      rounded = canvas.to_canvas(rounding: :round)

      expect(truncated[0, 0]).to eql ChunkyPNG::Color.rgb(1, 1, 1)
      expect(truncated[0, 1]).to eql ChunkyPNG::Color.rgb(1, 1, 1)
      expect(rounded[0, 0]).to eql ChunkyPNG::Color.rgb(1, 1, 1)
      expect(rounded[0, 1]).to eql ChunkyPNG::Color.rgb(2, 2, 2)
      expect { canvas.to_canvas(rounding: :unknown) }.to raise_error(ArgumentError)
    end
  end

  describe "PNG round trips" do
    it "preserves low-byte differences through all supported 16-bit color modes" do
      color_modes.each do |color_mode, color|
        samples = ChunkyPNG::Color.samples_per_pixel(color_mode)
        pixels = [
          color.call(Array.new(samples, 0x0100)),
          color.call(Array.new(samples, 0x0101)),
          color.call(Array.new(samples, 0xffff)),
          color.call(Array.new(samples, 0x0000)),
          color.call(Array.new(samples, 0x8080)),
          color.call(Array.new(samples, 0x00ff)),
          color.call(Array.new(samples, 0x1234)),
          color.call(Array.new(samples, 0x1235)),
          color.call(Array.new(samples, 0xfedc)),
        ]
        original = described_class.new(3, 3, pixels)

        blob = original.to_blob(
          color_mode: color_mode,
          filtering: ChunkyPNG::FILTER_PAETH,
        )
        datastream = ChunkyPNG::Datastream.from_blob(blob)
        scanline_width = 3 * samples * 2
        filter_bytes = datastream.imagedata.bytes.each_slice(scanline_width + 1).map(&:first)

        expect(datastream.header_chunk.depth).to eql 16
        expect(filter_bytes).to eql [ChunkyPNG::FILTER_PAETH] * 3
        expect(described_class.from_datastream(datastream)).to eql original
      end
    end

    it "preserves low-byte differences through Adam7 passes with non-aligned dimensions" do
      color_modes.each do |color_mode, color|
        samples = ChunkyPNG::Color.samples_per_pixel(color_mode)
        pixels = (0...(13 * 11)).map do |index|
          values = Array.new(samples) { |channel| 0x0100 + ((index + channel) & 1) }
          color.call(values)
        end
        original = described_class.new(13, 11, pixels)

        blob = original.to_blob(
          color_mode: color_mode,
          interlace: true,
          filtering: ChunkyPNG::FILTER_SUB,
        )
        datastream = ChunkyPNG::Datastream.from_blob(blob)

        expect(datastream.header_chunk.depth).to eql 16
        expect(datastream.header_chunk.interlace).to eql ChunkyPNG::INTERLACING_ADAM7
        expect(described_class.from_datastream(datastream)).to eql original
      end
    end

    it "does not change the existing 8-bit Canvas decoding meaning" do
      original = ChunkyPNG::Canvas16.new(1, 2, [
        ChunkyPNG::Color16.rgb(0x0000, 0x0000, 0x0000),
        ChunkyPNG::Color16.rgb(0x0182, 0x0182, 0x0182),
      ])
      blob = original.to_blob(color_mode: ChunkyPNG::COLOR_TRUECOLOR)

      canvas = ChunkyPNG::Canvas.from_blob(blob)
      explicit = original.to_canvas(rounding: :truncate)

      expect(canvas).to eql explicit
      expect(canvas[0, 1]).to eql ChunkyPNG::Color.rgb(1, 1, 1)
    end
  end

  describe ChunkyPNG::Image16 do
    it "round trips metadata through the 16-bit image path" do
      image = ChunkyPNG::Image16.new(1, 1, ChunkyPNG::Color16::WHITE)
      image.metadata["Title"] = "Sixteen bit"

      loaded = ChunkyPNG::Image16.from_blob(image.to_blob)

      expect(loaded).to be_a(ChunkyPNG::Image16)
      expect(loaded).to eql image
      expect(loaded.metadata["Title"]).to eql "Sixteen bit"
    end
  end
end
