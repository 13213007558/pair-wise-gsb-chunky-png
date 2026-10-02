require "spec_helper"

describe ChunkyPNG::Canvas::PoissonBlending do
  let(:mask_values) do
    [
      1, 1, 0, 1,
      1, 0, 0, 1,
      0, 0, 0, 0,
      0, 1, 1, 0
    ]
  end

  let(:target) do
    pixels = (0...16).map do |index|
      x = index % 4
      y = index / 4
      value = 10 + 7 * x + 3 * y
      ChunkyPNG::Color.rgba(value, value + 2, value + 4, 64 + index)
    end
    ChunkyPNG::Canvas.new(4, 4, pixels)
  end

  let(:source) do
    pixels = (0...16).map do |index|
      x = index % 4
      y = index / 4
      value = 180 - 9 * x - 5 * y
      ChunkyPNG::Color.rgba(value, value - 3, value - 7, 13)
    end
    ChunkyPNG::Canvas.new(4, 4, pixels)
  end

  let(:mask) do
    pixels = mask_values.map do |active|
      active == 1 ? ChunkyPNG::Color.rgb(0, 0, 0) : ChunkyPNG::Color::TRANSPARENT
    end
    ChunkyPNG::Canvas.new(4, 4, pixels)
  end

  def color_value(pixel, channel)
    case channel
    when :r then ChunkyPNG::Color.r(pixel)
    when :g then ChunkyPNG::Color.g(pixel)
    else ChunkyPNG::Color.b(pixel)
    end
  end

  def reference_solution(canvas, source, mask, mode, channel)
    directions = [[0, -1], [0, 1], [-1, 0], [1, 0]]
    positions = []
    mask.pixels.each_with_index do |pixel, index|
      positions << [index % 4, index / 4] if ChunkyPNG::Color.a(pixel) == 255
    end
    active = {}
    positions.each_with_index { |position, index| active[position] = index }

    equations = Array.new(positions.length) { Array.new(positions.length + 1, 0.0) }

    positions.each_with_index do |(x, y), row|
      directions.each do |delta_x, delta_y|
        nx = x + delta_x
        ny = y + delta_y
        next unless canvas.include_xy?(nx, ny)

        equations[row][row] += 1
        source_gradient = 0.0
        if source.include_xy?(nx, ny)
          source_gradient =
            color_value(source[nx, ny], channel) -
            color_value(source[x, y], channel)
        end

        gradient = source_gradient
        if mode == :mixed_gradients
          target_gradient =
            color_value(canvas[nx, ny], channel) -
            color_value(canvas[x, y], channel)
          if target_gradient.abs > source_gradient.abs
            gradient = target_gradient
          end
        end

        equations[row][positions.length] += gradient
        if active[[nx, ny]]
          equations[row][active[[nx, ny]]] -= 1
        else
          equations[row][positions.length] += color_value(canvas[nx, ny], channel)
        end
      end
    end

    gaussian_solve(equations)
  end

  def gaussian_solve(equations)
    size = equations.length
    size.times do |pivot|
      pivot_row = (pivot...size).max_by { |row| equations[row][pivot].abs }
      equations[pivot], equations[pivot_row] = equations[pivot_row], equations[pivot]
      divisor = equations[pivot][pivot]
      (pivot..size).each { |column| equations[pivot][column] /= divisor }

      size.times do |row|
        next if row == pivot
        factor = equations[row][pivot]
        (pivot..size).each do |column|
          equations[row][column] -= factor * equations[pivot][column]
        end
      end
    end
    equations.map { |row| row[size] }
  end

  def expect_reference_values(result, mode, channel)
    values = reference_solution(target, source, mask, mode, channel)
    positions = []
    mask_values.each_with_index do |active, index|
      positions << [index % 4, index / 4] if active == 1
    end

    positions.each_with_index do |(x, y), index|
      expected = values[index].round
      expected = 0 if expected < 0
      expected = 255 if expected > 255
      expect(color_value(result.image[x, y], channel)).to be_within(1e-8).of(expected)
    end
  end

  [
    :source_gradients,
    :mixed_gradients
  ].each do |mode|
    describe "#{mode} mode" do
      it "matches an explicitly constructed small linear system" do
        result = target.poisson_blend(
          source, mask, 0, 0,
          mode: mode,
          solver: :exact,
          tolerance: 1e-10
        )

        expect(result).to be_converged
        expect(result.iterations).to eql 0
        expect(result.residual).to be < 1e-10
        expect(result.mask_size).to eql 7
        [:r, :g, :b].each { |channel| expect_reference_values(result, mode, channel) }
      end

      it "solves the same system with Gauss-Seidel iterations" do
        result = target.poisson_blend(
          source, mask, 0, 0,
          mode: mode,
          iterations_budget: 500,
          tolerance: 1e-6
        )
        exact = target.poisson_blend(
          source, mask, 0, 0,
          mode: mode,
          solver: :exact,
          tolerance: 1e-10
        )

        expect(result).to be_converged
        expect(result.iterations).to be > 0
        expect(result.iterations_budget).to eql 500
        expect(result.residual).to be <= 1e-6
        expect(result.image.pixels).to eql exact.image.pixels
      end
    end
  end

  it "uses target pixels as boundary conditions and leaves mask holes unchanged" do
    result = target.poisson_blend(
      source, mask, 0, 0,
      mode: :source_gradients,
      solver: :exact
    )

    expect(result).to be_converged
    mask_values.each_with_index do |active, index|
      x = index % 4
      y = index / 4
      expect(result.image[x, y]).to eql target[x, y] if active == 0
    end
  end

  it "preserves destination alpha and ignores source and mask RGB/alpha values" do
    colored_mask = ChunkyPNG::Canvas.new(
      4,
      4,
      mask_values.map do |active|
        active == 1 ? ChunkyPNG::Color.rgb(255, 128, 64) : ChunkyPNG::Color.rgba(255, 255, 255, 0)
      end
    )
    result = target.poisson_blend(
      source, colored_mask, 0, 0,
      solver: :exact
    )

    target.pixels.each_with_index do |pixel, index|
      expect(ChunkyPNG::Color.a(result.image.pixels[index])).to eql ChunkyPNG::Color.a(pixel)
    end
  end

  it "chooses stronger target or source gradients independently in mixed mode" do
    target_pixels = [
      ChunkyPNG::Color.rgb(0, 120, 10), ChunkyPNG::Color.rgb(120, 120, 10), ChunkyPNG::Color.rgb(0, 120, 10),
      ChunkyPNG::Color.rgb(0, 120, 10), ChunkyPNG::Color.rgb(100, 100, 10), ChunkyPNG::Color.rgb(0, 120, 10),
      ChunkyPNG::Color.rgb(0, 120, 10), ChunkyPNG::Color.rgb(0, 120, 10), ChunkyPNG::Color.rgb(0, 120, 10)
    ]
    local_target = ChunkyPNG::Canvas.new(3, 3, target_pixels)
    source_pixels = [
      ChunkyPNG::Color.rgb(50, 50, 10), ChunkyPNG::Color.rgb(80, 60, 20), ChunkyPNG::Color.rgb(50, 50, 10),
      ChunkyPNG::Color.rgb(50, 50, 10), ChunkyPNG::Color.rgb(50, 50, 10), ChunkyPNG::Color.rgb(50, 50, 10),
      ChunkyPNG::Color.rgb(50, 50, 10), ChunkyPNG::Color.rgb(50, 50, 10), ChunkyPNG::Color.rgb(50, 50, 10)
    ]
    local_source = ChunkyPNG::Canvas.new(3, 3, source_pixels)
    local_mask = ChunkyPNG::Canvas.new(
      3,
      3,
      [0, 0, 0, 0, ChunkyPNG::Color.rgb(255, 255, 255), 0, 0, 0, 0]
    )

    result = local_target.poisson_blend(
      local_source, local_mask,
      solver: :exact,
      mode: :mixed_gradients
    )

    expect(result).to be_converged
    expect(ChunkyPNG::Color.r(result.image[1, 1])).to eql 0
    expect(ChunkyPNG::Color.g(result.image[1, 1])).to eql 140
    expect(ChunkyPNG::Color.b(result.image[1, 1])).to eql 13
  end

  it "does not return an image when the iteration budget is exhausted" do
    result = target.poisson_blend(
      source, mask, 0, 0,
      iterations_budget: 0,
      tolerance: 0
    )

    expect(result).to_not be_converged
    expect(result.image).to be_nil
    expect(result.iterations).to eql 0
    expect(result.iterations_budget).to eql 0
    expect(result.residual).to be > 0
  end

  it "does not mutate the destination" do
    original_pixels = target.pixels.dup
    target.poisson_blend(source, mask, 0, 0, solver: :exact)
    expect(target.pixels).to eql original_pixels
  end

  it "rejects a non-binary mask" do
    mask.pixels[0] = ChunkyPNG::Color.rgba(0, 0, 0, 128)
    expect { target.poisson_blend(source, mask) }.to raise_error(ArgumentError, /binary/)
  end

  it "rejects a mask component without a target boundary" do
    full_mask = ChunkyPNG::Canvas.new(4, 4, ChunkyPNG::Color.rgb(0, 0, 0))
    expect { target.poisson_blend(source, full_mask, solver: :exact) }
      .to raise_error(ArgumentError, /boundary/)
  end

  it "rejects active mask pixels outside the destination" do
    expect { target.poisson_blend(source, mask, 1, 1) }
      .to raise_error(ChunkyPNG::OutOfBounds)
  end
end
