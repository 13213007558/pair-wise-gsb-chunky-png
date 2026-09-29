# frozen-string-literal: true

require "spec_helper"

describe ChunkyPNG::Canvas::Quantization do
  def gradient_canvas(width = 32, height = 32)
    ChunkyPNG::Canvas.new(width, height).tap do |canvas|
      height.times do |y|
        width.times do |x|
          canvas[x, y] = ChunkyPNG::Color.rgba((x * 255.0 / (width - 1)).round, (y * 255.0 / (height - 1)).round, ((x + y) * 255.0 / (width + height - 2)).round, 255)
        end
      end
    end
  end

  def alpha_edge_canvas(width = 32, height = 8)
    ChunkyPNG::Canvas.new(width, height).tap do |canvas|
      height.times do |y|
        width.times do |x|
          canvas[x, y] = ChunkyPNG::Color.rgba(200, 40, 40, (x * 255.0 / (width - 1)).round)
        end
      end
    end
  end

  def total_error(original, quantized)
    original.pixels.zip(quantized.pixels).inject(0.0) do |sum, (before, after)|
      sum + ChunkyPNG::Color.euclidean_distance_rgba(after, before)
    end
  end

  describe "#quantize" do
    context "with a generated palette" do
      let(:canvas) { gradient_canvas }
      subject(:quantized) { canvas.quantize(16) }

      it "uses at most the requested number of colors" do
        expect(quantized.pixels.uniq.length).to be <= 16
        expect(quantized.encoding_palette.size).to be <= 16
      end

      it "only uses colors from the encoding palette" do
        expect(quantized.pixels.uniq - quantized.encoding_palette.to_a).to be_empty
      end

      it "is reproducible" do
        expect(canvas.quantize(16).pixels).to eql quantized.pixels
        expect(canvas.quantize(16, dither: true).pixels).to eql canvas.quantize(16, dither: true).pixels
      end

      it "does not depend on pixel insertion order" do
        reordered = ChunkyPNG::Canvas.new(canvas.width, canvas.height, canvas.pixels.reverse)
        expect(reordered.quantize(16).encoding_palette.to_a.sort).to eql quantized.encoding_palette.to_a.sort
      end

      it "limits the quantization error" do
        expect(total_error(canvas, quantized) / canvas.area).to be < 64.0
      end

      it "keeps the average color of the image close to the original" do
        [ChunkyPNG::Color.method(:r), ChunkyPNG::Color.method(:g), ChunkyPNG::Color.method(:b)].each do |channel|
          before = canvas.pixels.inject(0) { |sum, p| sum + channel.call(p) } / canvas.area.to_f
          after = quantized.pixels.inject(0) { |sum, p| sum + channel.call(p) } / canvas.area.to_f
          expect((after - before).abs).to be < 32.0
        end
      end

      it "returns a canvas of the same class and dimensions" do
        expect(quantized).to be_a ChunkyPNG::Canvas
        expect(quantized.width).to eql canvas.width
        expect(quantized.height).to eql canvas.height
      end

      it "raises an ArgumentError for an out of range color count" do
        expect { canvas.quantize(0) }.to raise_error(ArgumentError)
        expect { canvas.quantize(257) }.to raise_error(ArgumentError)
      end
    end

    context "with an image that has few colors" do
      let(:colors) { [ChunkyPNG::Color.rgba(255, 0, 0, 255), ChunkyPNG::Color.rgba(0, 255, 0, 255), ChunkyPNG::Color.rgba(0, 0, 255, 255), ChunkyPNG::Color.rgba(255, 255, 0, 128)] }
      let(:canvas) do
        ChunkyPNG::Canvas.new(8, 8).tap do |c|
          8.times { |y| 8.times { |x| c[x, y] = colors[(x + y) % 4] } }
        end
      end

      it "keeps the image identical when the palette is large enough" do
        quantized = canvas.quantize(256)
        expect(quantized.pixels).to eql canvas.pixels
        expect(quantized.encoding_palette.to_a.sort).to eql colors.sort
      end

      it "reduces the image to the requested number of colors" do
        quantized = canvas.quantize(2)
        expect(quantized.pixels.uniq.length).to be <= 2
      end
    end

    context "with semi-transparent edges" do
      let(:canvas) { alpha_edge_canvas }

      it "keeps fully transparent pixels transparent" do
        quantized = canvas.quantize(4)
        canvas.width.times do |x|
          next unless ChunkyPNG::Color.fully_transparent?(canvas[x, 0])

          expect(ChunkyPNG::Color.a(quantized[x, 0])).to be <= 32
        end
      end

      it "keeps the alpha gradient monotonic" do
        quantized = canvas.quantize(8)
        alphas = (0...canvas.width).map { |x| ChunkyPNG::Color.a(quantized[x, 0]) }
        expect(alphas.each_cons(2).all? { |a, b| b >= a }).to be true
      end

      it "does not let fully transparent pixels spread color error into opaque regions" do
        junk = ChunkyPNG::Canvas.new(16, 4)
        clean = ChunkyPNG::Canvas.new(16, 4)
        4.times do |y|
          16.times do |x|
            if x < 8
              junk[x, y] = clean[x, y] = ChunkyPNG::Color.rgba(200, 40, 40, 255)
            else
              junk[x, y] = ChunkyPNG::Color.rgba(0, 255, 0, 0)
              clean[x, y] = ChunkyPNG::Color::TRANSPARENT
            end
          end
        end

        opaque = ->(img) { img.quantize(2, dither: true).crop(0, 0, 8, 4).pixels }
        expect(opaque.call(junk)).to eql opaque.call(clean)
      end
    end

    context "with a caller-provided palette" do
      let(:canvas) { gradient_canvas }
      let(:palette) { [ChunkyPNG::Color.rgba(255, 0, 0, 255), ChunkyPNG::Color.rgba(0, 0, 255, 255), ChunkyPNG::Color::TRANSPARENT] }

      it "only uses colors from the provided palette" do
        quantized = canvas.quantize(8, palette: palette)
        expect(quantized.pixels.uniq - palette).to be_empty
        expect(quantized.encoding_palette.to_a.sort).to eql palette.sort
      end

      it "accepts a ChunkyPNG::Palette instance" do
        quantized = canvas.quantize(8, palette: ChunkyPNG::Palette.new(palette))
        expect(quantized.pixels.uniq - palette).to be_empty
      end

      it "accepts dithering with a provided palette" do
        quantized = canvas.quantize(8, palette: palette, dither: true)
        expect(quantized.pixels.uniq - palette).to be_empty
      end

      it "raises a conflict when the palette exceeds the color limit" do
        expect { canvas.quantize(2, palette: palette) }
          .to raise_error(ChunkyPNG::ExpectationFailed, /conflict/i)
      end

      it "raises an error for an empty palette" do
        expect { canvas.quantize(8, palette: []) }
          .to raise_error(ChunkyPNG::ExpectationFailed)
      end
    end

    context "indexed PNG output" do
      let(:canvas) { gradient_canvas }
      subject(:quantized) { canvas.quantize(16) }

      it "encodes as an indexed image with a bounded palette" do
        datastream = quantized.to_datastream(color_mode: ChunkyPNG::COLOR_INDEXED)
        expect(datastream.header_chunk.color).to eql ChunkyPNG::COLOR_INDEXED
        expect(datastream.palette_chunk.content.bytesize).to be <= 16 * 3
      end

      it "uses a bit depth that fits the palette" do
        datastream = quantized.to_datastream(color_mode: ChunkyPNG::COLOR_INDEXED)
        expect(datastream.header_chunk.depth).to eql 4
      end

      it "reads back the exact same pixels" do
        blob = quantized.to_blob(color_mode: ChunkyPNG::COLOR_INDEXED)
        expect(ChunkyPNG::Canvas.from_blob(blob).pixels).to eql quantized.pixels
      end

      it "reads back the exact same pixels with dithering enabled" do
        dithered = canvas.quantize(16, dither: true)
        blob = dithered.to_blob(color_mode: ChunkyPNG::COLOR_INDEXED)
        expect(ChunkyPNG::Canvas.from_blob(blob).pixels).to eql dithered.pixels
      end

      it "keeps semi-transparent colors through a roundtrip" do
        quantized_edge = alpha_edge_canvas.quantize(8)
        blob = quantized_edge.to_blob(color_mode: ChunkyPNG::COLOR_INDEXED)
        decoded = ChunkyPNG::Canvas.from_blob(blob)
        expect(decoded.pixels).to eql quantized_edge.pixels
        expect(decoded.pixels.map { |p| ChunkyPNG::Color.a(p) }.uniq.length).to be > 2
      end
    end
  end
end
