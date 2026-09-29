require "spec_helper"

describe ChunkyPNG::Canvas::ProjectiveTransform do
  def color(r, g, b, a = 255)
    ChunkyPNG::Color.rgba(r, g, b, a)
  end

  def canvas_from_rows(rows)
    height = rows.length
    width = rows.first.length
    ChunkyPNG::Canvas.new(width, height, rows.flatten)
  end

  let(:identity_matrix) { [1, 0, 0, 0, 1, 0, 0, 0, 1] }

  let(:colorful_canvas) do
    canvas_from_rows([
      [color(10, 20, 30), color(40, 50, 60), color(70, 80, 90)],
      [color(15, 25, 35), color(45, 55, 65), color(75, 85, 95)]
    ])
  end

  describe "#warp_homography" do
    it "maps the canvas onto itself exactly with the identity matrix" do
      result = colorful_canvas.warp_homography(identity_matrix, 3, 2)
      expect(result).to eql colorful_canvas
    end

    it "accepts the matrix as 3 rows of 3 elements" do
      nested = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
      expect(colorful_canvas.warp_homography(nested, 3, 2)).to eql colorful_canvas
    end

    it "does not modify the original canvas" do
      original = colorful_canvas.dup
      colorful_canvas.warp_homography(identity_matrix, 3, 2)
      expect(colorful_canvas).to eql original
    end

    it "does not return itself" do
      expect(colorful_canvas.warp_homography(identity_matrix, 3, 2)).to_not equal colorful_canvas
    end

    it "maps integer translations exactly and fills the exposed area with the background" do
      background = color(200, 0, 0)
      result = colorful_canvas.warp_homography([1, 0, 2, 0, 1, 1, 0, 0, 1], 3, 2, background: background)
      expected = canvas_from_rows([
        [background, background, background],
        [background, background, colorful_canvas[0, 0]]
      ])
      expect(result).to eql expected
    end

    it "maps a horizontal flip exactly" do
      result = colorful_canvas.warp_homography([-1, 0, 3, 0, 1, 0, 0, 0, 1], 3, 2)
      expected = canvas_from_rows([
        [colorful_canvas[2, 0], colorful_canvas[1, 0], colorful_canvas[0, 0]],
        [colorful_canvas[2, 1], colorful_canvas[1, 1], colorful_canvas[0, 1]]
      ])
      expect(result).to eql expected
    end

    it "maps a 90 degree rotation exactly" do
      result = colorful_canvas.warp_homography([0, -1, 2, 1, 0, 0, 0, 0, 1], 2, 3)
      expected = canvas_from_rows([
        [colorful_canvas[0, 1], colorful_canvas[0, 0]],
        [colorful_canvas[1, 1], colorful_canvas[1, 0]],
        [colorful_canvas[2, 1], colorful_canvas[2, 0]]
      ])
      expect(result).to eql expected
    end

    it "moves a single dot to the geometrically correct position" do
      source = ChunkyPNG::Canvas.new(5, 5, ChunkyPNG::Color::TRANSPARENT)
      source[1, 1] = ChunkyPNG::Color::WHITE
      result = source.warp_homography([0, -1, 5, 1, 0, 0, 0, 0, 1], 5, 5)
      expect(result[3, 1]).to eql ChunkyPNG::Color::WHITE
      expect(result.pixels.count(ChunkyPNG::Color::WHITE)).to eql 1
    end

    it "interpolates smoothly when upscaling" do
      source = canvas_from_rows([
        [color(0, 0, 0), color(255, 255, 255)],
        [color(0, 0, 0), color(255, 255, 255)]
      ])
      result = source.warp_homography([2, 0, 0, 0, 2, 0, 0, 0, 1], 4, 4, background: color(0, 0, 0))
      expect(result.row(0)).to eql [color(0, 0, 0), color(48, 48, 48), color(143, 143, 143), color(143, 143, 143)]
      expect(result.row(1)).to eql [color(0, 0, 0), color(64, 64, 64), color(191, 191, 191), color(191, 191, 191)]
      expect(result.row(2)).to eql [color(0, 0, 0), color(64, 64, 64), color(191, 191, 191), color(191, 191, 191)]
      expect(result.row(3)).to eql [color(0, 0, 0), color(48, 48, 48), color(143, 143, 143), color(143, 143, 143)]
    end

    it "averages high frequency content when downscaling a checkerboard" do
      source = ChunkyPNG::Canvas.new(16, 16)
      for y in 0...16
        for x in 0...16
          source[x, y] = ((x + y).even?) ? color(255, 255, 255) : color(0, 0, 0)
        end
      end
      result = source.warp_homography([0.25, 0, 0, 0, 0.25, 0, 0, 0, 1], 4, 4)
      for y in 1..2
        for x in 1..2
          pixel = result[x, y]
          expect(ChunkyPNG::Color.a(pixel)).to eql 255
          expect([127, 128]).to include ChunkyPNG::Color.r(pixel)
          expect([127, 128]).to include ChunkyPNG::Color.g(pixel)
          expect([127, 128]).to include ChunkyPNG::Color.b(pixel)
        end
      end
    end

    it "blends fractional positions with premultiplied alpha" do
      source = canvas_from_rows([[color(255, 0, 0), ChunkyPNG::Color::TRANSPARENT]])
      result = source.warp_homography([1, 0, -0.5, 0, 1, 0, 0, 0, 1], 1, 1)
      expect(result[0, 0]).to eql color(255, 0, 0, 128)
    end

    it "samples semi-transparent pixels with premultiplied alpha" do
      source = canvas_from_rows([[color(255, 0, 0), ChunkyPNG::Color::TRANSPARENT]])
      result = source.warp_homography([0.5, 0, 0, 0, 1, 0, 0, 0, 1], 1, 1)
      pixel = result[0, 0]
      expect(ChunkyPNG::Color.a(pixel)).to eql 112
      expect(ChunkyPNG::Color.r(pixel)).to eql 255
      expect(ChunkyPNG::Color.g(pixel)).to eql 0
      expect(ChunkyPNG::Color.b(pixel)).to eql 0
    end

    it "keeps the hue of a rotated semi-transparent thin line" do
      source = ChunkyPNG::Canvas.new(21, 21, ChunkyPNG::Color::TRANSPARENT)
      for x in 0...21
        source[x, 10] = color(255, 0, 0, 128)
      end

      theta = Math::PI / 6
      cos = Math.cos(theta)
      sin = Math.sin(theta)
      center = 10.5
      matrix = [
        cos, -sin, center - (cos * center) + (sin * center),
        sin, cos, center - (sin * center) - (cos * center),
        0, 0, 1
      ]
      result = source.warp_homography(matrix, 21, 21)

      alpha_sum = 0
      result.pixels.each do |pixel|
        alpha = ChunkyPNG::Color.a(pixel)
        next if alpha == 0
        expect(alpha).to be <= 128
        expect(ChunkyPNG::Color.r(pixel)).to eql 255
        expect(ChunkyPNG::Color.g(pixel)).to eql 0
        expect(ChunkyPNG::Color.b(pixel)).to eql 0
        alpha_sum += alpha
      end
      expect(alpha_sum).to be_within((21 * 128) * 0.25).of(21 * 128)
    end

    it "uses the background color for pixels outside of the source canvas" do
      background = color(0, 0, 200)
      result = colorful_canvas.warp_homography([1, 0, 10, 0, 1, 0, 0, 0, 1], 3, 2, background: background)
      expect(result.pixels.uniq).to eql [background]
    end

    it "handles a projective denominator that crosses zero" do
      source = ChunkyPNG::Canvas.new(4, 3, color(255, 255, 255))
      background = color(0, 200, 0)
      matrix = [1, 0, 0, 0, 1, 0, 0.4, 0, 1]
      result = nil
      expect { result = source.warp_homography(matrix, 5, 3, background: background) }.to_not raise_error
      expect(result[2, 1]).to eql background
    end

    it "handles extreme minification without runaway sampling" do
      source = ChunkyPNG::Canvas.new(64, 64, color(255, 0, 0))
      result = source.warp_homography([1.0 / 64, 0, 0, 0, 1.0 / 64, 0, 0, 0, 1], 1, 1)
      expect(result[0, 0]).to eql color(255, 0, 0)
    end

    it "handles extreme magnification" do
      source = ChunkyPNG::Canvas.new(2, 2, color(255, 0, 0))
      background = color(255, 0, 0)
      result = source.warp_homography([1_000_000, 0, 0, 0, 1_000_000, 0, 0, 0, 1], 3, 3, background: background)
      expect(result.pixels.uniq).to eql [color(255, 0, 0)]
    end

    it "maps absurdly large inverse coordinates to the background" do
      source = ChunkyPNG::Canvas.new(4, 4, color(255, 255, 255))
      background = color(0, 0, 255)
      result = source.warp_homography([1e-12, 0, 0, 0, 1e-12, 0, 0, 0, 1], 2, 2, background: background)
      expect(result.pixels.uniq).to eql [background]
    end

    it "raises an ArgumentError for a singular matrix" do
      expect { colorful_canvas.warp_homography([0, 0, 0, 0, 0, 0, 0, 0, 0], 3, 2) }.to raise_error(ArgumentError)
      expect { colorful_canvas.warp_homography([[1, 2, 3], [2, 4, 6], [7, 8, 9]], 3, 2) }.to raise_error(ArgumentError)
    end

    it "raises an ArgumentError for a malformed matrix" do
      expect { colorful_canvas.warp_homography([1, 0, 0, 0, 1, 0], 3, 2) }.to raise_error(ArgumentError)
      expect { colorful_canvas.warp_homography("not a matrix", 3, 2) }.to raise_error(ArgumentError)
    end

    it "raises an ArgumentError for non-finite matrix values" do
      expect { colorful_canvas.warp_homography([1, 0, 0, 0, 1, 0, 0, 0, Float::INFINITY], 3, 2) }.to raise_error(ArgumentError)
      expect { colorful_canvas.warp_homography([1, 0, 0, 0, 1, 0, 0, 0, Float::NAN], 3, 2) }.to raise_error(ArgumentError)
    end

    it "raises an ArgumentError for invalid target dimensions" do
      expect { colorful_canvas.warp_homography(identity_matrix, 0, 2) }.to raise_error(ArgumentError)
      expect { colorful_canvas.warp_homography(identity_matrix, 3, -1) }.to raise_error(ArgumentError)
    end
  end

  describe "#warp_homography!" do
    it "replaces the canvas content and dimensions" do
      canvas = colorful_canvas.dup
      canvas.warp_homography!([-1, 0, 3, 0, 1, 0, 0, 0, 1], 3, 2)
      expect(canvas[0, 0]).to eql colorful_canvas[2, 0]
    end

    it "returns itself" do
      canvas = colorful_canvas.dup
      expect(canvas.warp_homography!(identity_matrix, 3, 2)).to equal canvas
    end
  end
end
