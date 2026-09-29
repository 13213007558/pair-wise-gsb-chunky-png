require "spec_helper"

describe ChunkyPNG::Canvas::Quantization do
  def red
    ChunkyPNG::Color.rgb(255, 0, 0)
  end

  def green
    ChunkyPNG::Color.rgb(0, 255, 0)
  end

  def blue
    ChunkyPNG::Color.rgb(0, 0, 255)
  end

  def gradient_canvas(width = 16, height = 16)
    canvas = ChunkyPNG::Canvas.new(width, height)
    0.upto(height - 1) do |y|
      0.upto(width - 1) do |x|
        canvas[x, y] = ChunkyPNG::Color.rgba(
          (x * 255) / (width - 1),
          (y * 255) / (height - 1),
          128,
          255
        )
      end
    end
    canvas
  end

  def total_squared_error(original, quantized)
    original.pixels.zip(quantized.pixels).sum do |before, after|
      ChunkyPNG::Color.euclidean_distance_rgba(before, after)**2
    end
  end

  def semi_transparent_canvas
    canvas = ChunkyPNG::Canvas.new(4, 4, ChunkyPNG::Color::TRANSPARENT)
    canvas[1, 1] = ChunkyPNG::Color.rgba(255, 0, 0, 255)
    canvas[2, 1] = ChunkyPNG::Color.rgba(255, 0, 0, 128)
    canvas[1, 2] = ChunkyPNG::Color.rgba(255, 0, 0, 128)
    canvas[2, 2] = ChunkyPNG::Color.rgba(255, 0, 0, 64)
    canvas
  end

  describe "#quantize" do
    it "should not return itself" do
      canvas = gradient_canvas
      expect(canvas.quantize(16)).to_not equal(canvas)
    end

    it "should not adjust the current image" do
      canvas = gradient_canvas
      expect { canvas.quantize(16) }.to_not change { canvas.pixels }
    end

    it "should reduce the number of colors to at most the requested amount" do
      quantized = gradient_canvas.quantize(16)
      expect(quantized.pixels.uniq.length).to be <= 16
    end

    it "should keep the dimensions of the canvas" do
      quantized = gradient_canvas(8, 4).quantize(4)
      expect(quantized.width).to eq 8
      expect(quantized.height).to eq 4
    end

    it "should raise an ArgumentError for an out of range color count" do
      canvas = gradient_canvas
      expect { canvas.quantize(0) }.to raise_error(ArgumentError)
      expect { canvas.quantize(257) }.to raise_error(ArgumentError)
    end

    it "should be lossless if the image already uses few enough colors" do
      canvas = ChunkyPNG::Canvas.new(3, 1, [
        red, green, blue
      ])
      expect(canvas.quantize(8).pixels).to eq canvas.pixels
      expect(canvas.quantize(3).pixels).to eq canvas.pixels
    end

    it "should lower the quantization error when more colors are allowed" do
      canvas = gradient_canvas
      coarse = canvas.quantize(2, dithering: false)
      fine = canvas.quantize(32, dithering: false)
      expect(total_squared_error(canvas, fine)).to be < total_squared_error(canvas, coarse)
    end

    it "should be reproducible" do
      expect(gradient_canvas.quantize(8).pixels).to eq gradient_canvas.quantize(8).pixels
      expect(gradient_canvas.quantize(8, dithering: false).pixels)
        .to eq gradient_canvas.quantize(8, dithering: false).pixels
    end
  end

  describe "#quantize!" do
    it "should return itself" do
      canvas = gradient_canvas
      expect(canvas.quantize!(16)).to equal(canvas)
    end

    it "should adjust the current image" do
      canvas = gradient_canvas
      expect { canvas.quantize!(16) }.to change { canvas.pixels }
      expect(canvas.pixels.uniq.length).to be <= 16
    end
  end

  describe "locked colors" do
    it "should keep locked colors in the resulting palette" do
      canvas = ChunkyPNG::Canvas.new(4, 1, [
        red, blue,
        ChunkyPNG::Color.rgba(200, 200, 200, 255), ChunkyPNG::Color.rgba(100, 100, 100, 255)
      ])
      quantized = canvas.quantize(4, locked: [red, blue])
      expect(quantized[0, 0]).to eq red
      expect(quantized[1, 0]).to eq blue
      expect(quantized.pixels.uniq.length).to be <= 4
    end

    it "should report a conflict when more colors are locked than allowed" do
      canvas = gradient_canvas
      locked = [red, blue]
      expect { canvas.quantize(1, locked: locked) }.to raise_error(ChunkyPNG::ExpectationFailed)
      locked << green
      expect { canvas.quantize(2, locked: locked) }.to raise_error(ChunkyPNG::ExpectationFailed)
    end
  end

  describe "#quantize_to_palette" do
    it "should only use colors from the given palette" do
      palette = [ChunkyPNG::Color::BLACK, ChunkyPNG::Color::WHITE, red]
      quantized = gradient_canvas.quantize_to_palette(palette)
      expect(quantized.pixels.uniq - palette).to be_empty
    end

    it "should accept a ChunkyPNG::Palette instance" do
      palette = ChunkyPNG::Palette.new([ChunkyPNG::Color::BLACK, ChunkyPNG::Color::WHITE])
      quantized = gradient_canvas.quantize_to_palette(palette)
      expect(quantized.pixels.uniq - palette.to_a).to be_empty
    end

    it "should raise an ArgumentError for an empty or too large palette" do
      canvas = gradient_canvas
      expect { canvas.quantize_to_palette([]) }.to raise_error(ArgumentError)
      expect { canvas.quantize_to_palette(Array.new(257) { |i| ChunkyPNG::Color.rgba(i % 256, i / 256, 0, 255) }) }
        .to raise_error(ArgumentError)
    end

    it "should let the alpha channel participate in the color distance" do
      canvas = ChunkyPNG::Canvas.new(1, 1, ChunkyPNG::Color.rgba(240, 0, 0, 10))
      palette = [red, ChunkyPNG::Color::TRANSPARENT]
      quantized = canvas.quantize_to_palette(palette, dithering: false)
      expect(quantized[0, 0]).to eq ChunkyPNG::Color::TRANSPARENT
    end

    it "should break ties between equally distant colors by palette position" do
      canvas = ChunkyPNG::Canvas.new(1, 1, ChunkyPNG::Color.rgba(127, 127, 0, 255))
      expect(canvas.quantize_to_palette([red, green], dithering: false)[0, 0]).to eq red
      expect(canvas.quantize_to_palette([green, red], dithering: false)[0, 0]).to eq green
    end
  end

  describe "dithering" do
    it "should be controlled independently from quantization" do
      canvas = gradient_canvas
      dithered = canvas.quantize(4, dithering: true)
      undithered = canvas.quantize(4, dithering: false)
      expect(dithered.pixels).to_not eq undithered.pixels
      expect(dithered.pixels.uniq.length).to be <= 4
      expect(undithered.pixels.uniq.length).to be <= 4
    end

    it "should spread the quantization error over neighboring pixels" do
      canvas = ChunkyPNG::Canvas.new(2, 1, [
        ChunkyPNG::Color.rgba(150, 150, 150, 255),
        ChunkyPNG::Color.rgba(130, 130, 130, 255)
      ])
      palette = [ChunkyPNG::Color::BLACK, ChunkyPNG::Color::WHITE]
      expect(canvas.quantize_to_palette(palette, dithering: false).pixels)
        .to eq [ChunkyPNG::Color::WHITE, ChunkyPNG::Color::WHITE]
      expect(canvas.quantize_to_palette(palette, dithering: true).pixels)
        .to eq [ChunkyPNG::Color::WHITE, ChunkyPNG::Color::BLACK]
    end

    it "should preserve the average color of a constant colored image" do
      canvas = ChunkyPNG::Canvas.new(16, 16, ChunkyPNG::Color.rgba(128, 128, 128, 255))
      palette = [ChunkyPNG::Color::BLACK, ChunkyPNG::Color::WHITE]
      quantized = canvas.quantize_to_palette(palette, dithering: true)
      expect(quantized.pixels.uniq).to match_array(palette)
      average = quantized.pixels.sum { |p| ChunkyPNG::Color.r(p) } / quantized.pixels.length
      expect(average).to be_within(20).of(128)
    end

    it "should not diffuse error from fully transparent pixels" do
      canvas = ChunkyPNG::Canvas.new(2, 1, [
        ChunkyPNG::Color.rgba(255, 255, 255, 0),
        ChunkyPNG::Color.rgba(100, 100, 100, 255)
      ])
      palette = [ChunkyPNG::Color::TRANSPARENT, ChunkyPNG::Color::BLACK, ChunkyPNG::Color::WHITE]
      quantized = canvas.quantize_to_palette(palette, dithering: true)
      expect(quantized[0, 0]).to eq ChunkyPNG::Color::TRANSPARENT
      expect(quantized[1, 0]).to eq ChunkyPNG::Color::BLACK
    end
  end

  describe "transparency" do
    it "should keep fully transparent pixels fully transparent" do
      canvas = semi_transparent_canvas
      quantized = canvas.quantize(4)
      0.upto(3) do |y|
        0.upto(3) do |x|
          if ChunkyPNG::Color.a(canvas[x, y]) == 0
            expect(ChunkyPNG::Color.a(quantized[x, y])).to eq 0
          end
        end
      end
    end

    it "should include a transparent color in the palette" do
      quantized = semi_transparent_canvas.quantize(4)
      expect(quantized.palette).to be_any { |color| ChunkyPNG::Color.a(color) == 0 }
    end

    it "should normalize fully transparent pixels regardless of their color channels" do
      canvas = ChunkyPNG::Canvas.new(2, 1, [
        ChunkyPNG::Color.rgba(255, 0, 0, 0),
        ChunkyPNG::Color.rgba(0, 0, 255, 0)
      ])
      quantized = canvas.quantize(2)
      expect(quantized.pixels.uniq).to eq [ChunkyPNG::Color::TRANSPARENT]
    end
  end

  describe "indexed PNG encoding" do
    it "should encode as an indexed PNG with at most the requested number of colors" do
      quantized = gradient_canvas.quantize(16)
      datastream = quantized.to_datastream(
        color_mode: ChunkyPNG::COLOR_INDEXED,
        bit_depth: 8,
        filtering: ChunkyPNG::FILTER_NONE
      )
      expect(datastream.header_chunk.color).to eq ChunkyPNG::COLOR_INDEXED

      palette_size = datastream.palette_chunk.content.bytesize / 3
      expect(palette_size).to be <= 16

      raw = datastream.imagedata
      indices = []
      0.upto(quantized.height - 1) do |y|
        scanline = raw.byteslice(y * (quantized.width + 1) + 1, quantized.width)
        indices.concat(scanline.bytes)
      end
      expect(indices.length).to eq quantized.pixels.length
      expect(indices.min).to be >= 0
      expect(indices.max).to be < palette_size
    end

    it "should automatically use the indexed color mode for quantized images" do
      quantized = gradient_canvas.quantize(16)
      datastream = quantized.to_datastream
      expect(datastream.header_chunk.color).to eq ChunkyPNG::COLOR_INDEXED
    end

    it "should read back the same pixels after a PNG round trip" do
      quantized = gradient_canvas.quantize(16)
      decoded = ChunkyPNG::Canvas.from_blob(quantized.to_blob)
      expect(decoded.pixels).to eq quantized.pixels
    end

    it "should survive a PNG round trip with a caller provided palette" do
      palette = [ChunkyPNG::Color::TRANSPARENT, red, blue]
      quantized = semi_transparent_canvas.quantize_to_palette(palette)
      decoded = ChunkyPNG::Canvas.from_blob(quantized.to_blob)
      expect(decoded.pixels).to eq quantized.pixels
    end
  end
end
