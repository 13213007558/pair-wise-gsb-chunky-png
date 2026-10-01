# frozen-string-literal: true

require "spec_helper"

describe ChunkyPNG::Canvas::PoissonBlending do
  let :color do
    ChunkyPNG::Color
  end

  def grayscale_canvas(width, height, values)
    pixels = values.map { |value| color.grayscale(value) }
    ChunkyPNG::Canvas.new(width, height, pixels)
  end

  def grayscale_values(canvas)
    canvas.pixels.map { |pixel| ChunkyPNG::Color.r(pixel) }
  end

  def alpha_values(canvas)
    canvas.pixels.map { |pixel| ChunkyPNG::Color.a(pixel) }
  end

  def binary_mask(width, height, values)
    pixels = values.map {
      |active| color.grayscale_alpha(255, active.to_i > 0 ? 255 : 0)
    }
    ChunkyPNG::Canvas.new(width, height, pixels)
  end

  it "solves a small problem directly and leaves mask pixels outside unchanged" do
    target = grayscale_canvas(3, 3, [
      10, 10, 10,
      10, 10, 10,
      10, 10, 10
    ])
    source = grayscale_canvas(3, 3, [
      0, 0, 0,
      0, 100, 0,
      0, 0, 0
    ])
    mask = ChunkyPNG::Canvas.new(3, 3, Array.new(9) {
      |index| color.grayscale_alpha(255, index == 4 ? 255 : 0)
    })

    result = target.poisson_compose(source, mask, 0, 0)

    expect(result).to be_converged
    expect(result.solver).to eq(:direct)
    expect(result.iterations).to eq(0)
    expect(result.residual).to be < 1.0e-10
    expect(grayscale_values(result.canvas)).to eq([
      10, 10, 10,
      10, 110, 10,
      10, 10, 10
    ])
    expect(grayscale_values(target)).to eq(Array.new(9, 10))
  end

  it "uses source-sized mask coordinates with the supplied offset" do
    target = grayscale_canvas(5, 5, Array.new(25, 10))
    source = grayscale_canvas(3, 3, [
      0, 0, 0,
      0, 100, 0,
      0, 0, 0
    ])
    mask = binary_mask(3, 3, [
      0, 0, 0,
      0, 1, 0,
      0, 0, 0
    ])

    result = target.poisson_compose(source, mask, 1, 1, solver: :direct)
    values = grayscale_values(result.canvas)

    expect(result).to be_converged
    expect(values).to eq([
      10, 10, 10, 10, 10,
      10, 10, 10, 10, 10,
      10, 10, 110, 10, 10,
      10, 10, 10, 10, 10,
      10, 10, 10, 10, 10
    ])
    expect(grayscale_values(target)).to eq(Array.new(25, 10))
  end

  it "matches the direct solution for a mask with a hole and multiple components" do
    target = grayscale_canvas(5, 5, [
      20, 20, 20, 20, 20,
      20, 20, 20, 20, 20,
      20, 20, 20, 20, 20,
      20, 20, 20, 20, 20,
      20, 20, 20, 20, 20
    ])
    source = grayscale_canvas(5, 5, [
      0,  10, 20, 30, 40,
      50, 60, 70, 80, 90,
      0,  10, 20, 30, 40,
      50, 60, 70, 80, 90,
      0,  10, 20, 30, 40
    ])
    mask_values = [
      1, 1, 0, 0, 1,
      1, 1, 0, 0, 1,
      0, 0, 0, 0, 1,
      1, 0, 1, 1, 0,
      1, 0, 0, 0, 0
    ]
    mask = ChunkyPNG::Canvas.new(5, 5, mask_values.map {
      |active| color.grayscale_alpha(255, active == 1 ? 255 : 0)
    })

    direct = target.poisson_compose(source, mask, 0, 0,
      solver: :direct, tolerance: 1.0e-10)
    iterative = target.poisson_compose(source, mask, 0, 0,
      solver: :gauss_seidel, max_iterations: 10_000, tolerance: 1.0e-8)

    expect(direct).to be_converged
    expect(iterative).to be_converged
    expect(iterative.status).to eq(:converged)
    expect(iterative.residual).to be <= 1.0e-8
    direct.canvas.pixels.each_with_index do |pixel, index|
      expect(ChunkyPNG::Color.r(iterative.canvas[index_to_x(index, 5), index_to_y(index, 5)])).to be_within(1).of(
        ChunkyPNG::Color.r(pixel)
      )
    end
    target.pixels.each_with_index do |pixel, index|
      next if mask_values[index] == 1
      x = index_to_x(index, 5)
      y = index_to_y(index, 5)
      expect(direct.canvas[x, y]).to eq(pixel)
    end
  end

  it "handles a full-canvas component with a target-value anchor" do
    target = grayscale_canvas(3, 2, [
      5, 5, 5,
      5, 5, 5
    ])
    source = grayscale_canvas(3, 2, [
      0, 10, 20,
      30, 40, 50
    ])
    mask = ChunkyPNG::Canvas.new(3, 2, Array.new(6, color::WHITE))

    direct = target.poisson_compose(source, mask, 0, 0,
      solver: :direct, tolerance: 1.0e-10)
    iterative = target.poisson_compose(source, mask, 0, 0,
      solver: :gauss_seidel, max_iterations: 10_000, tolerance: 1.0e-8)

    expect(direct).to be_converged
    expect(iterative).to be_converged
    expect(ChunkyPNG::Color.r(direct.canvas[0, 0])).to eq(5)
    direct.canvas.pixels.each_with_index do |pixel, index|
      x = index_to_x(index, 3)
      y = index_to_y(index, 3)
      expect(ChunkyPNG::Color.r(iterative.canvas[x, y])).to be_within(1).of(
        ChunkyPNG::Color.r(pixel)
      )
    end
  end

  it "uses Neumann conditions when a retained active pixel touches the target edge" do
    target = grayscale_canvas(3, 3, Array.new(9, 30))
    source = grayscale_canvas(3, 3, [
      0, 0, 0,
      0, 100, 0,
      0, 0, 0
    ])
    mask = ChunkyPNG::Canvas.new(3, 3, Array.new(9) {
      |index| color.grayscale_alpha(255, index.zero? ? 255 : 0)
    })

    result = target.poisson_compose(source, mask, -1, -1, solver: :direct)

    expect(result).to be_converged
    expect(grayscale_values(result.canvas)).to eq([
      130, 30, 30,
      30, 30, 30,
      30, 30, 30
    ])
  end

  it "uses the stronger local gradient in mixed mode" do
    target = grayscale_canvas(3, 1, [0, 0, 100])
    source = grayscale_canvas(3, 1, [0, 0, 10])
    mask = binary_mask(3, 1, [0, 1, 0])

    normal = target.poisson_compose(source, mask, 0, 0,
      solver: :direct, gradient: :normal)
    mixed = target.poisson_compose(source, mask, 0, 0,
      solver: :direct, gradient: :mixed)

    expect(grayscale_values(normal.canvas)).to eq([0, 45, 100])
    expect(grayscale_values(mixed.canvas)).to eq([0, 0, 100])
  end

  it "reports max iterations as unconverged with the final residual" do
    target = grayscale_canvas(3, 3, Array.new(9, 10))
    source = grayscale_canvas(3, 3, [
      0, 20, 40,
      60, 80, 100,
      0, 20, 40
    ])
    mask = ChunkyPNG::Canvas.new(3, 3, Array.new(9, color::WHITE))

    result = target.poisson_compose(source, mask, 0, 0,
      solver: :gauss_seidel, max_iterations: 0, tolerance: 1.0e-6)

    expect(result.converged?).to eq(false)
    expect(result.status).to eq(:max_iterations)
    expect(result.iterations).to eq(0)
    expect(result.residual).to be > 1.0e-6
  end

  it "preserves target alpha for every changed pixel" do
    pixels = Array.new(9) { |index| color.grayscale_alpha(index * 5, 30 + index * 20) }
    target = ChunkyPNG::Canvas.new(3, 3, pixels)
    source_pixels = Array.new(9, color.rgba(0, 0, 0, 5))
    source_pixels[4] = color.rgba(200, 100, 50, 5)
    source = ChunkyPNG::Canvas.new(3, 3, source_pixels)
    mask = ChunkyPNG::Canvas.new(3, 3, Array.new(9) {
      |index| color.grayscale_alpha(255, index == 4 ? 255 : 0)
    })

    result = target.poisson_compose(source, mask, 0, 0, solver: :direct)

    expect(alpha_values(result.canvas)).to eq(alpha_values(target))
    expect(ChunkyPNG::Color.a(result.canvas[1, 1])).to eq(110)
  end

  it "modifies the receiver through the bang method while keeping outside pixels unchanged" do
    target = grayscale_canvas(2, 2, [1, 2, 3, 4])
    source = grayscale_canvas(1, 2, [0, 100])
    mask = binary_mask(1, 2, [1, 1])

    result = target.poisson_compose!(source, mask, 0, 0, solver: :direct)

    expect(result).to be_converged
    expect(grayscale_values(target)).to eq([0, 2, 37, 4])
    result.canvas[0, 0] = color.grayscale(99)
    expect(grayscale_values(target)).to eq([0, 2, 37, 4])
  end

  it "raises when an active mask pixel has no source sample" do
    target = grayscale_canvas(2, 2, Array.new(4, 10))
    source = grayscale_canvas(1, 1, [50])
    mask = ChunkyPNG::Canvas.new(2, 2, Array.new(4, color::WHITE))

    expect {
      target.poisson_compose(source, mask, 0, 0, solver: :direct)
    }.to raise_error(ArgumentError, /source pixel/)
  end

  def index_to_x(index, width)
    index % width
  end

  def index_to_y(index, width)
    index / width
  end
end
