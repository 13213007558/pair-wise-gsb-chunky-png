require "spec_helper"

describe ChunkyPNG::Canvas::Homography do
  include ChunkyPNG::Color

  let(:white) { ChunkyPNG::Color::WHITE }
  let(:black) { ChunkyPNG::Color::BLACK }
  let(:transparent) { ChunkyPNG::Color::TRANSPARENT }

  def grid_canvas(width, height)
    canvas = ChunkyPNG::Canvas.new(width, height)
    height.times do |y|
      width.times do |x|
        canvas[x, y] = ChunkyPNG::Color.rgba(10 + (x * 40), 20 + (y * 40), 30 + ((x + y) * 20), 255)
      end
    end
    canvas
  end

  describe "#homography_transform" do
    it "returns a new canvas with the requested dimensions" do
      result = grid_canvas(2, 2).homography_transform([1, 0, 0, 0, 1, 0, 0, 0, 1], 5, 7)
      expect(result).to be_a(ChunkyPNG::Canvas)
      expect(result.width).to eql 5
      expect(result.height).to eql 7
    end

    it "does not modify the original canvas" do
      canvas = grid_canvas(3, 3)
      expect { canvas.homography_transform([1, 0, 1, 0, 1, 1, 0, 0, 1], 4, 4) }
        .to_not change { canvas.pixels }
    end

    it "accepts a nested 3x3 matrix" do
      canvas = grid_canvas(2, 2)
      flat = canvas.homography_transform([1, 0, 0, 0, 1, 0, 0, 0, 1], 2, 2)
      nested = canvas.homography_transform([[1, 0, 0], [0, 1, 0], [0, 0, 1]], 2, 2)
      expect(nested).to eql flat
    end

    it "treats matrices that differ by a scalar factor as equal" do
      canvas = grid_canvas(3, 3)
      identity = canvas.homography_transform([1, 0, 0, 0, 1, 0, 0, 0, 1], 3, 3)
      scaled = canvas.homography_transform([2, 0, 0, 0, 2, 0, 0, 0, 2], 3, 3)
      expect(scaled).to eql identity
    end

    context "with exact integer transformations" do
      it "maps the identity transformation exactly" do
        canvas = grid_canvas(4, 3)
        expect(canvas.homography_transform([1, 0, 0, 0, 1, 0, 0, 0, 1], 4, 3)).to eql canvas
      end

      it "maps an integer translation exactly" do
        canvas = grid_canvas(2, 2)
        result = canvas.homography_transform([1, 0, 2, 0, 1, 1, 0, 0, 1], 4, 3)
        expect(result[2, 1]).to eql canvas[0, 0]
        expect(result[3, 1]).to eql canvas[1, 0]
        expect(result[2, 2]).to eql canvas[0, 1]
        expect(result[3, 2]).to eql canvas[1, 1]
        expect(result[0, 0]).to eql transparent
        expect(result[1, 2]).to eql transparent
        expect(result[3, 0]).to eql transparent
      end

      it "maps a 90 degree rotation exactly" do
        canvas = grid_canvas(3, 2)
        result = canvas.homography_transform([0, -1, 2, 1, 0, 0, 0, 0, 1], 2, 3)
        2.times do |y|
          3.times do |x|
            expect(result[1 - y, x]).to eql canvas[x, y]
          end
        end
      end

      it "smears a sheared pixel over its footprint, preserving its color" do
        canvas = ChunkyPNG::Canvas.new(3, 3, transparent)
        marker = ChunkyPNG::Color.rgb(200, 100, 50)
        canvas[0, 1] = marker
        result = canvas.homography_transform([1, 2, 0, 0, 1, 0, 0, 0, 1], 5, 3)
        [2, 3, 4].each do |x|
          pixel = result[x, 1]
          expect(ChunkyPNG::Color.r(pixel)).to eql 200
          expect(ChunkyPNG::Color.g(pixel)).to eql 100
          expect(ChunkyPNG::Color.b(pixel)).to eql 50
          expect(ChunkyPNG::Color.a(pixel)).to be > 0
        end
        expect(result[0, 1]).to eql transparent
      end
    end

    context "when minifying" do
      it "averages a 2x2 block exactly" do
        canvas = ChunkyPNG::Canvas.new(2, 2, [
          ChunkyPNG::Color.rgba(0, 0, 0, 255), ChunkyPNG::Color.rgba(4, 8, 12, 255),
          ChunkyPNG::Color.rgba(8, 16, 24, 255), ChunkyPNG::Color.rgba(12, 24, 36, 255)
        ])
        result = canvas.homography_transform([1, 0, 0, 0, 1, 0, 0, 0, 2], 1, 1)
        expect(result[0, 0]).to eql ChunkyPNG::Color.rgba(6, 12, 18, 255)
      end

      it "averages a high frequency checkerboard to gray" do
        canvas = ChunkyPNG::Canvas.new(8, 8)
        8.times do |y|
          8.times do |x|
            canvas[x, y] = ((x + y).even? ? white : black)
          end
        end

        result = canvas.homography_transform([1, 0, 0, 0, 1, 0, 0, 0, 8], 1, 1)
        expect(result[0, 0]).to eql ChunkyPNG::Color.rgba(128, 128, 128, 255)

        result = canvas.homography_transform([1, 0, 0, 0, 1, 0, 0, 0, 2], 4, 4)
        expect(result.pixels.uniq).to eql [ChunkyPNG::Color.rgba(128, 128, 128, 255)]
      end

      it "averages a tilted checkerboard without moire" do
        canvas = ChunkyPNG::Canvas.new(16, 16)
        16.times do |y|
          16.times do |x|
            canvas[x, y] = ((x + y).even? ? white : black)
          end
        end
        result = canvas.homography_transform([4, 1, 0, 0, 4, 0, 0, 0, 16], 4, 4)
        [[1, 1], [2, 1], [1, 2], [2, 2]].each do |x, y|
          pixel = result[x, y]
          expect(ChunkyPNG::Color.r(pixel)).to be_within(26).of(128)
          expect(ChunkyPNG::Color.g(pixel)).to be_within(26).of(128)
          expect(ChunkyPNG::Color.b(pixel)).to be_within(26).of(128)
          expect(ChunkyPNG::Color.a(pixel)).to eql 255
        end
      end
    end

    context "with semi-transparent content" do
      it "samples with premultiplied alpha" do
        canvas = ChunkyPNG::Canvas.new(2, 1, [
          ChunkyPNG::Color.rgba(0, 0, 0, 255),
          ChunkyPNG::Color.rgba(255, 255, 255, 0)
        ])
        result = canvas.homography_transform([1, 0, -0.5, 0, 1, 0, 0, 0, 1], 1, 1)
        pixel = result[0, 0]
        expect(ChunkyPNG::Color.a(pixel)).to eql 128
        expect(ChunkyPNG::Color.r(pixel)).to eql 0
        expect(ChunkyPNG::Color.g(pixel)).to eql 0
        expect(ChunkyPNG::Color.b(pixel)).to eql 0
      end

      it "averages a thin semi-transparent line without changing its color" do
        canvas = ChunkyPNG::Canvas.new(3, 3, transparent)
        line = ChunkyPNG::Color.rgba(10, 20, 30, 128)
        3.times { |y| canvas[1, y] = line }

        result = canvas.homography_transform([1, 0, 0, 0, 3, 0, 0, 0, 3], 1, 3)
        3.times do |y|
          pixel = result[0, y]
          expect(ChunkyPNG::Color.r(pixel)).to eql 10
          expect(ChunkyPNG::Color.g(pixel)).to eql 20
          expect(ChunkyPNG::Color.b(pixel)).to eql 30
          expect(ChunkyPNG::Color.a(pixel)).to eql 43
        end
      end
    end

    context "with a background color" do
      it "fills pixels outside of the source canvas with the background" do
        canvas = grid_canvas(2, 2)
        background = ChunkyPNG::Color.rgb(255, 0, 0)
        result = canvas.homography_transform([1, 0, 1, 0, 1, 0, 0, 0, 1], 4, 2, background)
        expect(result[0, 0]).to eql background
        expect(result[1, 0]).to eql canvas[0, 0]
        expect(result[2, 1]).to eql canvas[1, 1]
        expect(result[3, 1]).to eql background
      end

      it "fills the whole canvas when the source maps completely outside" do
        canvas = grid_canvas(2, 2)
        background = ChunkyPNG::Color.rgb(0, 0, 255)
        result = canvas.homography_transform([1, 0, 100, 0, 1, 0, 0, 0, 1], 3, 3, background)
        expect(result.pixels.uniq).to eql [background]
      end
    end

    context "with degenerate matrices" do
      it "raises an ArgumentError for a singular matrix" do
        canvas = grid_canvas(2, 2)
        expect { canvas.homography_transform([1, 2, 3, 2, 4, 6, 1, 1, 1], 2, 2) }
          .to raise_error(ArgumentError)
      end

      it "raises an ArgumentError for an all-zero matrix" do
        canvas = grid_canvas(2, 2)
        expect { canvas.homography_transform(Array.new(9, 0), 2, 2) }
          .to raise_error(ArgumentError)
      end

      it "raises an ArgumentError for a matrix of the wrong size" do
        canvas = grid_canvas(2, 2)
        expect { canvas.homography_transform([1, 0, 0, 0, 1, 0, 0, 0], 2, 2) }
          .to raise_error(ArgumentError)
      end

      it "raises an ArgumentError for non-finite values" do
        canvas = grid_canvas(2, 2)
        expect { canvas.homography_transform([1, 0, 0, 0, 1, 0, 0, 0, Float::NAN], 2, 2) }
          .to raise_error(ArgumentError)
        expect { canvas.homography_transform([1, 0, 0, 0, 1, 0, 0, 0, Float::INFINITY], 2, 2) }
          .to raise_error(ArgumentError)
      end

      it "raises an ArgumentError for non-numeric values" do
        canvas = grid_canvas(2, 2)
        expect { canvas.homography_transform([1, 0, 0, 0, 1, 0, 0, 0, "1"], 2, 2) }
          .to raise_error(ArgumentError)
      end
    end

    context "with a projective transformation" do
      it "handles a denominator that crosses zero inside the canvas" do
        canvas = ChunkyPNG::Canvas.new(4, 4, white)
        background = ChunkyPNG::Color.rgb(0, 0, 255)
        result = canvas.homography_transform([1, 0, 0, 0, 1, 0, 1, 0, 1], 6, 6, background)
        expect(result.width).to eql 6
        expect(result[5, 5]).to eql background
        expect(result[3, 0]).to eql background
        expect(result[1, 2]).to eql background
        expect(result[0, 0]).to_not eql background
      end

      it "rectifies a skewed rectangle onto the target canvas" do
        canvas = grid_canvas(4, 4)
        matrix = [1, 0.25, 0, 0.5, 1, 0, 0.1, 0.05, 1]
        result = canvas.homography_transform(matrix, 8, 8)
        expect(result.width).to eql 8
        expect(result.height).to eql 8
        expect(result.pixels.uniq.length).to be > 1
      end
    end

    context "with extreme scaling" do
      let(:canvas) { grid_canvas(4, 4) }
      let(:background) { ChunkyPNG::Color.rgb(0, 255, 0) }

      it "handles extreme minification without runaway sampling" do
        result = canvas.homography_transform([1, 0, 0, 0, 1, 0, 0, 0, 100_000], 2, 2, background)
        expect(result.pixels.uniq).to eql [background]
      end

      it "handles extreme upscaling without huge coordinates" do
        result = canvas.homography_transform([100_000, 0, 0, 0, 1, 0, 0, 0, 1], 2, 2, background)
        expect(result.width).to eql 2
        expect(result.height).to eql 2
      end

      it "handles extreme translations without huge coordinates" do
        result = canvas.homography_transform([1, 0, 1.0e9, 0, 1, 0, 0, 0, 1], 2, 2, background)
        expect(result.pixels.uniq).to eql [background]
      end

      it "handles a nearly singular projective denominator" do
        matrix = [1, 0, 0, 0, 1, 0, 1, 0, 1.0e-9]
        result = canvas.homography_transform(matrix, 2, 2, background)
        expect(result.width).to eql 2
        expect(result.height).to eql 2
      end
    end
  end
end
