# frozen_string_literal: true

require "spec_helper"

describe ChunkyPNG::Canvas do
  let(:target) do
    pixels = [
      10, 10, 10, 40, 40, 40,
      10, 10, 10, 40, 40, 40,
      10, 10, 10, 40, 40, 40,
      20, 20, 20, 60, 60, 60,
      20, 20, 20, 60, 60, 60,
      20, 20, 20, 60, 60, 60
    ].map { |value| ChunkyPNG::Color.rgb(value, value, value) }
    ChunkyPNG::Canvas.new(6, 6, pixels)
  end

  let(:source) do
    pixels = [
      0, 0, 0, 0, 0, 0,
      0, 70, 80, 0, 0, 0,
      0, 60, 50, 0, 0, 0,
      0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0
    ].map { |value| ChunkyPNG::Color.rgb(value, value, value) }
    ChunkyPNG::Canvas.new(6, 6, pixels)
  end

  let(:mask) do
    [
      0, 0, 0, 0, 0, 0,
      0, 1, 1, 0, 0, 0,
      0, 1, 1, 0, 0, 0,
      0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0
    ]
  end

  describe "#poisson_blend" do
    let(:single_target) do
      pixels = [10, 10, 10, 20, 0, 30, 40, 40, 40]
      ChunkyPNG::Canvas.new(3, 3, pixels.map { |value| ChunkyPNG::Color.rgb(value, value, value) })
    end

    let(:single_source) do
      pixels = [0, 0, 0, 0, 70, 0, 0, 0, 0]
      ChunkyPNG::Canvas.new(3, 3, pixels.map { |value| ChunkyPNG::Color.rgb(value, value, value) })
    end

    let(:single_mask) { [0, 0, 0, 0, 1, 0, 0, 0, 0] }

    it "solves a one-pixel system explicitly for source gradients" do
      result = single_target.poisson_blend(single_source, single_mask, 0, 0, solver: :direct)
      value = ChunkyPNG::Color.r(result.canvas.get_pixel(1, 1))

      expect(result).to be_converged
      expect(result.solver).to eql(:direct)
      expect(result.iterations).to eql(0)
      expect(result.iteration_budget).to eql(1000)
      expect(result.mask_pixels).to eql(1)
      expect(result.residual).to be < 0.000001
      expect(value).to eql(95)
      expect(single_target).not_to eql(result.canvas)
    end

    it "matches the explicit solution with Gauss-Seidel iterations" do
      direct = single_target.poisson_blend(single_source, single_mask, 0, 0, solver: :direct, tolerance: 0.0)
      iterative = single_target.poisson_blend(
        single_source, single_mask, 0, 0,
        solver: :gauss_seidel, tolerance: 0.000001
      )

      expect(iterative).to be_converged
      expect(iterative.solver).to eql(:gauss_seidel)
      expect(iterative.iterations).to be <= iterative.iteration_budget
      expect(iterative.residual).to be <= 0.000001
      expect(iterative.mask_pixels).to eql(1)
      expect(iterative.canvas).to eql(direct.canvas)
    end

    it "supports mixed gradients and keeps a strong target feature" do
      stripe_pixels = (0...36).map { |index| ChunkyPNG::Color.rgb(index % 6 == 2 ? 100 : 0, 0, 0) }
      stripe_target = ChunkyPNG::Canvas.new(6, 6, stripe_pixels)
      flat_source = ChunkyPNG::Canvas.new(6, 6, ChunkyPNG::Color.rgb(0, 0, 0))
      result = stripe_target.poisson_blend(flat_source, mask, 0, 0, mode: :mixed, solver: :direct)
      values = result.canvas.pixels.values_at(7, 8, 13, 14).map { |pixel| ChunkyPNG::Color.r(pixel) }

      expect(result).to be_converged
      expect(values).to eql([0, 100, 0, 100])
    end

    it "handles holes and disconnected components" do
      disconnected_mask = [
        0, 0, 0, 0, 0, 0,
        0, 1, 0, 1, 0, 0,
        0, 0, 0, 0, 0, 0,
        0, 1, 1, 0, 0, 0,
        0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0
      ]
      result = target.poisson_blend(source, disconnected_mask, 0, 0, solver: :direct)

      expect(result.mask_pixels).to eql(4)
      expect(result).to be_converged
      expect(ChunkyPNG::Color.r(result.canvas.get_pixel(2, 1))).to eql(10)
      expect(ChunkyPNG::Color.r(result.canvas.get_pixel(3, 1))).to eql(13)
      expect(ChunkyPNG::Color.r(result.canvas.get_pixel(1, 3))).to eql(0)
      expect(ChunkyPNG::Color.r(result.canvas.get_pixel(2, 3))).to eql(10)
    end

    it "preserves target alpha and ignores source alpha when solving RGB" do
      target.pixels.map! { |pixel| ChunkyPNG::Color.rgba(ChunkyPNG::Color.r(pixel), 0, 0, 32) }
      source.pixels.map! { |pixel| ChunkyPNG::Color.rgba(ChunkyPNG::Color.r(pixel), 255, 255, 128) }
      result = target.poisson_blend(source, mask, 0, 0, solver: :direct)

      expect(result.canvas.pixels.map { |pixel| ChunkyPNG::Color.a(pixel) }.uniq).to eql([32])
      expect(ChunkyPNG::Color.r(result.canvas.get_pixel(1, 1))).to eql(85)
    end

    it "does not report success when the iteration budget is exhausted" do
      result = target.poisson_blend(source, mask, 0, 0, solver: :gauss_seidel, iterations: 0)

      expect(result).not_to be_converged
      expect(result.iterations).to eql(0)
      expect(result.iteration_budget).to eql(0)
      expect(result.residual).to be > 0
    end

    it "accepts a canvas mask with white selected pixels and black background" do
      mask_pixels = Array.new(36, ChunkyPNG::Color::BLACK)
      [7, 8, 13, 14].each { |index| mask_pixels[index] = ChunkyPNG::Color::WHITE }
      mask_canvas = ChunkyPNG::Canvas.new(6, 6, mask_pixels)
      result = target.poisson_blend(source, mask_canvas, 0, 0, solver: :direct)

      expect(result.mask_pixels).to eql(4)
      expect(result).to be_converged
    end

    it "accepts an alpha mask with opaque selected pixels and transparent background" do
      mask_pixels = Array.new(36, ChunkyPNG::Color::TRANSPARENT)
      [7, 8, 13, 14].each do |index|
        mask_pixels[index] = ChunkyPNG::Color.rgba(0, 0, 0, 255)
      end
      mask_canvas = ChunkyPNG::Canvas.new(6, 6, mask_pixels)
      result = target.poisson_blend(source, mask_canvas, 0, 0, solver: :direct)

      expect(result.mask_pixels).to eql(4)
      expect(result).to be_converged
    end

    it "returns an unchanged result for an empty mask" do
      result = target.poisson_blend(source, Array.new(36, 0), 0, 0)

      expect(result).to be_converged
      expect(result.mask_pixels).to eql(0)
      expect(result.residual).to eql(0.0)
      expect(result.canvas).to eql(target)
    end

    it "requires a one-pixel border around selected mask pixels" do
      mask[6] = 1
      expect { target.poisson_blend(source, mask, 0, 0) }.to raise_error(ArgumentError)
    end

    it "raises when the source does not fit at the requested offset" do
      expect { target.poisson_blend(source, mask, 1, 1) }.to raise_error(ChunkyPNG::OutOfBounds)
    end

    it "mutates the receiver with the bang method" do
      result = target.poisson_blend!(source, mask, 0, 0, solver: :direct)

      expect(result.canvas).to equal(target)
      expect(ChunkyPNG::Color.r(target.get_pixel(1, 1))).to eql(85)
    end
  end
end
