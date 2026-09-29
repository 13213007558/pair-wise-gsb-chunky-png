require "spec_helper"

describe ChunkyPNG::Canvas16 do
  describe "#initialize" do
    it "should default to a truecolor alpha canvas with zero samples" do
      canvas = ChunkyPNG::Canvas16.new(2, 2)
      expect(canvas.color_mode).to eql ChunkyPNG::COLOR_TRUECOLOR_ALPHA
      expect(canvas.pixels).to eql [[0, 0, 0, 0]] * 4
    end

    it "should accept a single pixel as background" do
      canvas = ChunkyPNG::Canvas16.new(2, 1, ChunkyPNG::COLOR_GRAYSCALE, [0x1234])
      expect(canvas.pixels).to eql [[0x1234], [0x1234]]
    end

    it "should accept an array of pixels" do
      canvas = ChunkyPNG::Canvas16.new(2, 1, ChunkyPNG::COLOR_TRUECOLOR, [[1, 2, 3], [4, 5, 6]])
      expect(canvas.pixels).to eql [[1, 2, 3], [4, 5, 6]]
    end

    it "should raise an error if the initial array has the wrong length" do
      expect { ChunkyPNG::Canvas16.new(2, 2, ChunkyPNG::COLOR_GRAYSCALE, [[1]]) }
        .to raise_error(ArgumentError)
    end

    it "should raise an error for an unsupported color mode" do
      expect { ChunkyPNG::Canvas16.new(1, 1, ChunkyPNG::COLOR_INDEXED) }
        .to raise_error(ChunkyPNG::NotSupported)
    end
  end

  describe "pixel access" do
    it "should get and set pixels with full 16-bit sample values" do
      canvas = ChunkyPNG::Canvas16.new(2, 2, ChunkyPNG::COLOR_GRAYSCALE_ALPHA)
      canvas[1, 0] = [0xabcd, 0x1234]
      expect(canvas[1, 0]).to eql [0xabcd, 0x1234]
      expect(canvas.get_pixel(1, 0)).to eql [0xabcd, 0x1234]
    end

    it "should raise an error when the sample count does not match the color mode" do
      canvas = ChunkyPNG::Canvas16.new(2, 2, ChunkyPNG::COLOR_TRUECOLOR)
      expect { canvas[0, 0] = [1, 2, 3, 4] }.to raise_error(ArgumentError)
    end

    it "should raise an error for out of bounds coordinates" do
      canvas = ChunkyPNG::Canvas16.new(2, 2)
      expect { canvas[2, 0] }.to raise_error(ChunkyPNG::OutOfBounds)
    end
  end

  describe ".resample_sample_to_8bit" do
    it "should round down by taking the high byte" do
      expect(ChunkyPNG::Canvas16.resample_sample_to_8bit(0x12ff, :down)).to eql 0x12
      expect(ChunkyPNG::Canvas16.resample_sample_to_8bit(0xffff, :down)).to eql 0xff
      expect(ChunkyPNG::Canvas16.resample_sample_to_8bit(0x0000, :down)).to eql 0x00
    end

    it "should round to the nearest 8-bit value" do
      expect(ChunkyPNG::Canvas16.resample_sample_to_8bit(0x12ff, :nearest)).to eql 0x13
      expect(ChunkyPNG::Canvas16.resample_sample_to_8bit(0x1201, :nearest)).to eql 0x12
      expect(ChunkyPNG::Canvas16.resample_sample_to_8bit(0xffff, :nearest)).to eql 0xff
      expect(ChunkyPNG::Canvas16.resample_sample_to_8bit(0x0000, :nearest)).to eql 0x00
    end

    it "should round up to the next 8-bit value" do
      expect(ChunkyPNG::Canvas16.resample_sample_to_8bit(0x1213, :up)).to eql 0x13
      expect(ChunkyPNG::Canvas16.resample_sample_to_8bit(0x1212, :up)).to eql 0x12
      expect(ChunkyPNG::Canvas16.resample_sample_to_8bit(0x1201, :up)).to eql 0x12
      expect(ChunkyPNG::Canvas16.resample_sample_to_8bit(0xffff, :up)).to eql 0xff
      expect(ChunkyPNG::Canvas16.resample_sample_to_8bit(0x0000, :up)).to eql 0x00
    end

    it "should raise an error for an unknown rounding rule" do
      expect { ChunkyPNG::Canvas16.resample_sample_to_8bit(0x1234, :sideways) }
        .to raise_error(ArgumentError)
    end
  end

  describe "#to_canvas" do
    let(:canvas16) do
      ChunkyPNG::Canvas16.new(2, 1, ChunkyPNG::COLOR_TRUECOLOR_ALPHA, [
        [0x1200, 0x3400, 0x5600, 0x7800],
        [0x12ff, 0x34ff, 0x56ff, 0x78ff],
      ])
    end

    it "should convert to an 8-bit canvas using the requested rounding rule" do
      expect(canvas16.to_canvas(:down).pixels).to eql [
        ChunkyPNG::Color.rgba(0x12, 0x34, 0x56, 0x78),
        ChunkyPNG::Color.rgba(0x12, 0x34, 0x56, 0x78),
      ]
      expect(canvas16.to_canvas(:nearest).pixels).to eql [
        ChunkyPNG::Color.rgba(0x12, 0x34, 0x56, 0x78),
        ChunkyPNG::Color.rgba(0x13, 0x35, 0x57, 0x79),
      ]
    end

    it "should collapse pixels that only differ in the low byte when rounding down" do
      pixels = canvas16.to_canvas(:down).pixels
      expect(pixels[0]).to eql pixels[1]
    end

    it "should convert grayscale canvases" do
      canvas = ChunkyPNG::Canvas16.new(1, 1, ChunkyPNG::COLOR_GRAYSCALE, [[0x8080]])
      expect(canvas.to_canvas(:nearest).pixels).to eql [ChunkyPNG::Color.grayscale(0x80)]
    end

    it "should convert grayscale alpha canvases" do
      canvas = ChunkyPNG::Canvas16.new(1, 1, ChunkyPNG::COLOR_GRAYSCALE_ALPHA, [[0x8080, 0x4040]])
      expect(canvas.to_canvas(:nearest).pixels).to eql [ChunkyPNG::Color.grayscale_alpha(0x80, 0x40)]
    end
  end

  describe ".from_canvas" do
    it "should upscale 8-bit samples explicitly" do
      canvas = ChunkyPNG::Canvas.new(1, 1, ChunkyPNG::Color.rgba(0x12, 0x34, 0x56, 0x78))
      canvas16 = ChunkyPNG::Canvas16.from_canvas(canvas)
      expect(canvas16.pixels).to eql [[0x1212, 0x3434, 0x5656, 0x7878]]
    end

    it "should round-trip an 8-bit canvas losslessly" do
      canvas = ChunkyPNG::Canvas.new(2, 1, [ChunkyPNG::Color.rgb(0xff, 0x00, 0x80), ChunkyPNG::Color.rgba(1, 2, 3, 4)])
      canvas16 = ChunkyPNG::Canvas16.from_canvas(canvas)
      expect(canvas16.to_canvas(:down)).to eql canvas
      expect(canvas16.to_canvas(:nearest)).to eql canvas
    end

    it "should support grayscale color modes" do
      canvas = ChunkyPNG::Canvas.new(1, 1, ChunkyPNG::Color.grayscale_alpha(0x80, 0x40))
      canvas16 = ChunkyPNG::Canvas16.from_canvas(canvas, color_mode: ChunkyPNG::COLOR_GRAYSCALE_ALPHA)
      expect(canvas16.pixels).to eql [[0x8080, 0x4040]]
    end

    it "should raise an error for an unsupported color mode" do
      canvas = ChunkyPNG::Canvas.new(1, 1)
      expect { ChunkyPNG::Canvas16.from_canvas(canvas, color_mode: ChunkyPNG::COLOR_INDEXED) }
        .to raise_error(ChunkyPNG::NotSupported)
    end
  end
end
