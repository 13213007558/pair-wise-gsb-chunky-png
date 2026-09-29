require "spec_helper"

describe "ChunkyPNG::Canvas16 PNG encoding and decoding" do
  COLOR_MODES = {
    "grayscale"        => ChunkyPNG::COLOR_GRAYSCALE,
    "grayscale_alpha"  => ChunkyPNG::COLOR_GRAYSCALE_ALPHA,
    "truecolor"        => ChunkyPNG::COLOR_TRUECOLOR,
    "truecolor_alpha"  => ChunkyPNG::COLOR_TRUECOLOR_ALPHA,
  }.freeze

  FILTERS = {
    "none"    => ChunkyPNG::FILTER_NONE,
    "sub"     => ChunkyPNG::FILTER_SUB,
    "up"      => ChunkyPNG::FILTER_UP,
    "average" => ChunkyPNG::FILTER_AVERAGE,
    "paeth"   => ChunkyPNG::FILTER_PAETH,
  }.freeze

  # Builds a deterministic sample value for a pixel. The low byte varies
  # independently from the high byte, so neighboring pixels often only
  # differ in their low 8 bits.
  def sample_for(pixel_index, channel)
    ((pixel_index * 0x9e35 + channel * 0x1001 + 0x1234) & 0xffff)
  end

  def canvas16_for(color_mode, width, height)
    channels = ChunkyPNG::Canvas16::CHANNELS[color_mode]
    pixels = (0...(width * height)).map do |i|
      (0...channels).map { |c| sample_for(i, c) }
    end
    ChunkyPNG::Canvas16.new(width, height, color_mode, pixels)
  end

  COLOR_MODES.each do |mode_name, color_mode|
    context "with #{mode_name} color mode" do
      it "should write a 16-bit PNG header" do
        ds = ChunkyPNG::Datastream.from_blob(canvas16_for(color_mode, 2, 2).to_blob)
        expect(ds.header_chunk.depth).to eql 16
        expect(ds.header_chunk.color).to eql color_mode
      end

      it "should round-trip samples that only differ in the low 8 bits" do
        channels = ChunkyPNG::Canvas16::CHANNELS[color_mode]
        base = [0xab00] * channels
        low_byte_only = [0xabff] * channels
        canvas = ChunkyPNG::Canvas16.new(2, 1, color_mode, [base, low_byte_only])

        decoded = ChunkyPNG::Canvas16.from_blob(canvas.to_blob)
        expect(decoded).to eql canvas
        expect(decoded[0, 0]).to eql base
        expect(decoded[1, 0]).to eql low_byte_only

        # The low byte difference must be invisible after 8-bit conversion
        # when rounding down, proving the difference lived in the low bytes.
        expect(decoded.to_canvas(:down)[0, 0]).to eql decoded.to_canvas(:down)[1, 0]
      end

      FILTERS.each do |filter_name, filter|
        it "should round-trip exactly with #{filter_name} filtering across rows" do
          canvas = canvas16_for(color_mode, 7, 5)
          blob = canvas.to_blob(filtering: filter)
          expect(ChunkyPNG::Canvas16.from_blob(blob)).to eql canvas
        end
      end

      it "should round-trip exactly with Adam7 interlacing on a non-even size" do
        canvas = canvas16_for(color_mode, 13, 11)
        blob = canvas.to_blob(interlace: true, filtering: ChunkyPNG::FILTER_PAETH)

        ds = ChunkyPNG::Datastream.from_blob(blob)
        expect(ds.header_chunk.interlace).to eql ChunkyPNG::INTERLACING_ADAM7
        expect(ChunkyPNG::Canvas16.from_datastream(ds)).to eql canvas
      end

      it "should round-trip exactly with Adam7 interlacing on single-pixel sizes" do
        [[1, 1], [1, 7], [7, 1]].each do |width, height|
          canvas = canvas16_for(color_mode, width, height)
          blob = canvas.to_blob(interlace: true)
          expect(ChunkyPNG::Canvas16.from_blob(blob)).to eql canvas
        end
      end
    end
  end

  describe "decoding the PNG suite 16-bit images" do
    %w[basi0g16 basi2c16 basi4a16 basi6a16 basn0g16 basn2c16 basn4a16 basn6a16].each do |file|
      it "should decode #{file}.png without losing the low bytes" do
        canvas16 = ChunkyPNG::Canvas16.from_file(png_suite_file("basic", "#{file}.png"))

        # The low bytes must survive an encode/decode cycle at full depth.
        expect(ChunkyPNG::Canvas16.from_blob(canvas16.to_blob)).to eql canvas16

        # Downsampling with the :down rule matches the historic 8-bit decode.
        canvas8 = ChunkyPNG::Canvas.from_file(png_suite_file("basic", "#{file}.png"))
        expect(canvas16.to_canvas(:down)).to eql canvas8
      end
    end
  end

  describe "decoding unsupported images" do
    it "should raise an error for an 8-bit image" do
      expect { ChunkyPNG::Canvas16.from_file(png_suite_file("basic", "basn2c08.png")) }
        .to raise_error(ChunkyPNG::NotSupported, /bit depth of 8/)
    end

    it "should raise an error for an indexed image" do
      expect { ChunkyPNG::Canvas16.from_file(png_suite_file("basic", "basn3p08.png")) }
        .to raise_error(ChunkyPNG::NotSupported, /[Ii]ndexed/)
    end
  end

  describe "transparency chunks" do
    it "should decode a 16-bit truecolor image with a tRNS chunk to truecolor alpha" do
      canvas = ChunkyPNG::Canvas16.from_file(png_suite_file("transparency", "tbbn2c16.png"))
      expect(canvas.color_mode).to eql ChunkyPNG::COLOR_TRUECOLOR_ALPHA
      expect(canvas.pixels.map(&:last)).to include(0, 0xffff)
    end

    it "should decode a 16-bit grayscale image with a tRNS chunk to grayscale alpha" do
      canvas = ChunkyPNG::Canvas16.from_file(png_suite_file("transparency", "tbwn1g16.png"))
      expect(canvas.color_mode).to eql ChunkyPNG::COLOR_GRAYSCALE_ALPHA
    end
  end

  describe "interaction with the 8-bit Canvas API" do
    it "should not change how ChunkyPNG::Canvas decodes 16-bit images" do
      canvas16 = canvas16_for(ChunkyPNG::COLOR_TRUECOLOR_ALPHA, 4, 3)
      blob = canvas16.to_blob

      # The existing 8-bit decoding path keeps its historic meaning:
      # samples are truncated to their high byte.
      expect(ChunkyPNG::Canvas.from_blob(blob)).to eql canvas16.to_canvas(:down)
    end
  end
end
