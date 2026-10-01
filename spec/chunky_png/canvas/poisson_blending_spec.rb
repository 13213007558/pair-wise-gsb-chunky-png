require "spec_helper"

describe ChunkyPNG::Canvas::PoissonBlending do
  def build_canvas(width, height, &color_fn)
    canvas = ChunkyPNG::Canvas.new(width, height)
    height.times do |y|
      width.times do |x|
        canvas[x, y] = color_fn.call(x, y)
      end
    end
    canvas
  end

  # A 12x12 target with a distinct color (and alpha) per pixel.
  let(:target) do
    build_canvas(12, 12) { |x, y| ChunkyPNG::Color.rgba((30 + x * 7) % 256, (60 + y * 11) % 256, 200, 150 + x) }
  end

  # An 8x8 source with non-linear gradients.
  let(:source) do
    build_canvas(8, 8) { |x, y| ChunkyPNG::Color.rgb((x * x * 4 + y * 3) % 256, (255 - x * 20) % 256, (y * 30) % 256) }
  end

  # An 8x8 mask with an irregular region: a diamond shape with a hole, plus
  # a separate two-pixel component.
  let(:mask) do
    build_canvas(8, 8) do |x, y|
      diamond = (x - 3.5).abs + (y - 3.5).abs <= 3 && !(x == 3 && y == 3)
      component = (x == 7 && y <= 1)
      (diamond || component) ? ChunkyPNG::Color::WHITE : ChunkyPNG::Color::TRANSPARENT
    end
  end

  def masked?(mask, x, y, offset_x, offset_y)
    mx = x - offset_x
    my = y - offset_y
    return false if mx < 0 || my < 0 || mx >= mask.width || my >= mask.height
    pixel = mask[mx, my]
    ChunkyPNG::Color.a(pixel) > 0 &&
      (ChunkyPNG::Color.r(pixel) | ChunkyPNG::Color.g(pixel) | ChunkyPNG::Color.b(pixel)) > 0
  end

  def expect_outside_pixels_unchanged(result_image, target, mask, offset_x, offset_y)
    target.height.times do |y|
      target.width.times do |x|
        next if masked?(mask, x, y, offset_x, offset_y)
        expect(result_image[x, y]).to(
          eql(target[x, y]),
          "expected pixel (#{x}, #{y}) outside the mask to be unchanged"
        )
      end
    end
  end

  describe "#poisson_blend" do
    it "returns a result with solver diagnostics" do
      result = target.poisson_blend(source, mask, 2, 2)
      expect(result).to be_a(ChunkyPNG::Canvas::PoissonBlending::Result)
      expect(result.image).to be_a(ChunkyPNG::Canvas)
      expect(result.iterations).to be > 0
      expect(result.residual).to be <= 0.5
      expect(result.mask_size).to be > 0
      expect(result).to be_converged
    end

    it "does not modify the target canvas" do
      expect { target.poisson_blend(source, mask, 2, 2) }.to_not change { target.pixels }
    end

    it "leaves every pixel outside the mask exactly unchanged" do
      result = target.poisson_blend(source, mask, 2, 2)
      expect_outside_pixels_unchanged(result.image, target, mask, 2, 2)
    end

    it "preserves the alpha channel of the target everywhere" do
      result = target.poisson_blend(source, mask, 2, 2)
      target.area.times do |i|
        expect(ChunkyPNG::Color.a(result.image.pixels[i])).to eql ChunkyPNG::Color.a(target.pixels[i])
      end
    end

    it "leaves holes inside the mask unchanged" do
      result = target.poisson_blend(source, mask, 2, 2)
      expect(result.image[5, 5]).to eql target[5, 5]
    end

    it "solves disconnected mask components" do
      result = target.poisson_blend(source, mask, 2, 2)
      expect(result).to be_converged
      expect(result.image[9, 2]).to_not eql target[9, 2]
    end

    it "reproduces the source Laplacian in the interior of the masked region" do
      interior_mask = build_canvas(8, 8) do |x, y|
        (x >= 1 && x <= 6 && y >= 1 && y <= 6) ? ChunkyPNG::Color::WHITE : ChunkyPNG::Color::TRANSPARENT
      end
      result = target.poisson_blend(source, interior_mask, 2, 2, tolerance: 0.01, max_iterations: 5000)
      expect(result).to be_converged

      # For masked pixels whose neighbors are all masked, the discrete
      # Laplacian of the result must match the discrete Laplacian of the
      # source (shifted by the offset).
      (3..6).each do |y|
        (3..6).each do |x|
          [ChunkyPNG::Color.method(:r), ChunkyPNG::Color.method(:g), ChunkyPNG::Color.method(:b)].each do |channel|
            image_laplacian = 4 * channel.call(result.image[x, y]) -
              channel.call(result.image[x + 1, y]) - channel.call(result.image[x - 1, y]) -
              channel.call(result.image[x, y + 1]) - channel.call(result.image[x, y - 1])
            source_laplacian = 4 * channel.call(source[x - 2, y - 2]) -
              channel.call(source[x - 1, y - 2]) - channel.call(source[x - 3, y - 2]) -
              channel.call(source[x - 2, y - 1]) - channel.call(source[x - 2, y - 3])
            expect(image_laplacian).to be_within(2).of(source_laplacian)
          end
        end
      end
    end

    it "supports masks that touch the canvas edges" do
      edge_mask = build_canvas(8, 8) do |x, y|
        (x < 4 && y < 4) ? ChunkyPNG::Color::WHITE : ChunkyPNG::Color::TRANSPARENT
      end
      result = target.poisson_blend(source, edge_mask, 0, 0)
      expect(result).to be_converged
      expect_outside_pixels_unchanged(result.image, target, edge_mask, 0, 0)
    end

    it "handles a mask that covers the entire canvas" do
      full_source = build_canvas(12, 12) { |x, y| ChunkyPNG::Color.rgb(x * 20, y * 20, 100) }
      full_mask = ChunkyPNG::Canvas.new(12, 12, ChunkyPNG::Color::WHITE)
      result = target.poisson_blend(full_source, full_mask, 0, 0)
      expect(result).to be_converged
      expect(result.mask_size).to eql 144
    end

    it "clips the mask to the canvas when the offset pushes it out of bounds" do
      result = target.poisson_blend(source, mask, 8, 8)
      expect(result).to be_converged
      expect_outside_pixels_unchanged(result.image, target, mask, 8, 8)
    end

    it "returns a converged empty result for an empty mask" do
      empty_mask = ChunkyPNG::Canvas.new(8, 8, ChunkyPNG::Color::TRANSPARENT)
      result = target.poisson_blend(source, empty_mask, 2, 2)
      expect(result).to be_converged
      expect(result.iterations).to eql 0
      expect(result.residual).to eql 0.0
      expect(result.mask_size).to eql 0
      expect(result.image).to eql target
    end

    it "reports non-convergence when the iteration limit is reached" do
      result = target.poisson_blend(source, mask, 2, 2, max_iterations: 1, tolerance: 1e-9)
      expect(result).to_not be_converged
      expect(result.iterations).to eql 1
      expect(result.residual).to be > 1e-9
    end

    it "agrees with the direct solver within rounding error" do
      iterative = target.poisson_blend(source, mask, 2, 2, tolerance: 0.01, max_iterations: 5000)
      direct = target.poisson_blend(source, mask, 2, 2, solver: :direct)
      expect(direct).to be_converged
      expect(direct.residual).to be < 1e-6
      target.area.times do |i|
        expect(ChunkyPNG::Color.r(iterative.image.pixels[i])).to be_within(1).of(ChunkyPNG::Color.r(direct.image.pixels[i]))
        expect(ChunkyPNG::Color.g(iterative.image.pixels[i])).to be_within(1).of(ChunkyPNG::Color.g(direct.image.pixels[i]))
        expect(ChunkyPNG::Color.b(iterative.image.pixels[i])).to be_within(1).of(ChunkyPNG::Color.b(direct.image.pixels[i]))
      end
    end

    it "supports mixed gradients" do
      result = target.poisson_blend(source, mask, 2, 2, mode: :mixed)
      expect(result).to be_converged
      expect_outside_pixels_unchanged(result.image, target, mask, 2, 2)
    end

    it "raises an error when the mask dimensions do not match the source" do
      bad_mask = ChunkyPNG::Canvas.new(4, 4, ChunkyPNG::Color::WHITE)
      expect { target.poisson_blend(source, bad_mask, 0, 0) }.to raise_error(ChunkyPNG::ExpectationFailed)
    end

    it "raises an error for an unknown mode" do
      expect { target.poisson_blend(source, mask, 0, 0, mode: :bogus) }.to raise_error(ChunkyPNG::ExpectationFailed)
    end

    it "raises an error for an unknown solver" do
      expect { target.poisson_blend(source, mask, 0, 0, solver: :bogus) }.to raise_error(ChunkyPNG::ExpectationFailed)
    end
  end

  describe "#poisson_blend!" do
    it "replaces the pixels of the target canvas" do
      result = target.poisson_blend!(source, mask, 2, 2)
      expect(result).to be_converged
      expect(result.image.pixels).to eql target.pixels
    end

    it "leaves pixels outside the mask unchanged" do
      original = target.pixels.dup
      target.poisson_blend!(source, mask, 2, 2)
      target.height.times do |y|
        target.width.times do |x|
          next if masked?(mask, x, y, 2, 2)
          expect(target[x, y]).to eql original[y * target.width + x]
        end
      end
    end
  end
end
