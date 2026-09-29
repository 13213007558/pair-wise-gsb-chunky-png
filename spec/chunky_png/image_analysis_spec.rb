# frozen_string_literal: true

require "spec_helper"

describe ChunkyPNG::ImageAnalysis::SquaredEuclideanDistanceTransform do
  let(:white) { ChunkyPNG::Color::WHITE }
  let(:black) { ChunkyPNG::Color::BLACK }

  def mask(width, height, active)
    pixels = Array.new(width * height, black)
    active.each { |x, y| pixels[y * width + x] = white }
    ChunkyPNG::Canvas.new(width, height, pixels)
  end

  def brute_force(canvas)
    foreground = []
    canvas.height.times do |y|
      canvas.width.times do |x|
        foreground << [x, y] if canvas[x, y] == white
      end
    end

    distances = Array.new(canvas.area)
    coordinates = Array.new(canvas.area)

    unless foreground.empty?
      canvas.height.times do |y|
        canvas.width.times do |x|
          _distance, seed_x, seed_y = foreground.map do |seed_x, seed_y|
            [
              (x - seed_x) ** 2 + (y - seed_y) ** 2,
              seed_x,
              seed_y
            ]
          end.min_by { |candidate| [candidate[0], candidate[1], candidate[2]] }

          index = y * canvas.width + x
          distances[index] = (x - seed_x) ** 2 + (y - seed_y) ** 2
          coordinates[index] = [seed_x, seed_y]
        end
      end
    end

    [distances, coordinates]
  end

  def expect_matches_brute_force(canvas)
    transform = described_class.from_canvas(canvas)
    distances, coordinates = brute_force(canvas)

    expect(transform.squared_distances).to eql(distances)
    expect(transform.nearest_foreground_coordinates).to eql(coordinates)
  end

  [[1, 1], [1, 2], [2, 1], [2, 2], [1, 3], [3, 1], [2, 3], [3, 2], [3, 3]]
    .each do |width, height|
    it "matches brute force for every #{width}x#{height} binary mask" do
      pixel_count = width * height
      (0...(2 ** pixel_count)).each do |pattern|
        active = pixel_count.times
          .select { |index| pattern[index] == 1 }
          .map { |index| [index % width, index / width] }

        expect_matches_brute_force(mask(width, height, active))
      end
    end
  end

  it "matches brute force for random non-square masks" do
    srand(489)
    30.times do
      width = rand(1..8)
      height = rand(1..8)
      active = Array.new(rand(0...(width * height))) do
        [rand(0...width), rand(0...height)]
      end.uniq

      expect_matches_brute_force(mask(width, height, active))
    end
  end

  it "uses nil as the explicit empty-foreground convention" do
    transform = mask(2, 2, []).squared_euclidean_distance_transform

    expect(transform).to be_empty_foreground
    expect(transform.squared_distances).to eql([nil, nil, nil, nil])
    expect(transform.coordinates).to eql([nil, nil, nil, nil])
    expect(transform.distance_at(0, 0)).to be_nil
    expect(transform.coordinates_at(1, 1)).to be_nil
    expect(transform[0, 1]).to eql([nil, nil])
  end

  it "supports single-row, single-column, and full-foreground masks" do
    row = mask(4, 1, [[1, 0]])
    row_transform = described_class.from_canvas(row)
    expect(row_transform.squared_distances).to eql([1, 0, 1, 4])
    expect(row_transform.coordinates).to eql([[1, 0], [1, 0], [1, 0], [1, 0]])

    column = mask(1, 4, [[0, 1]])
    column_transform = described_class.from_canvas(column)
    expect(column_transform.squared_distances).to eql([1, 0, 1, 4])
    expect(column_transform.coordinates).to eql(
      [[0, 1], [0, 1], [0, 1], [0, 1]]
    )

    full = mask(2, 3, [
      [0, 0], [1, 0],
      [0, 1], [1, 1],
      [0, 2], [1, 2]
    ])
    full_transform = described_class.from_canvas(full)
    expect(full_transform.squared_distances.uniq).to eql([0])
    full_transform.height.times do |y|
      full_transform.width.times do |x|
        expect(full_transform.coordinates_at(x, y)).to eql([x, y])
      end
    end
  end

  it "breaks distance ties by ascending x then ascending y" do
    transform = described_class.from_canvas(mask(3, 3, [[0, 0], [2, 2]]))

    expect(transform.distance_at(1, 1)).to eql(2)
    expect(transform.coordinates_at(1, 1)).to eql([0, 0])

    second_transform = described_class.from_canvas(
      mask(3, 3, [[0, 2], [2, 0]])
    )

    expect(second_transform.distance_at(1, 1)).to eql(2)
    expect(second_transform.coordinates_at(1, 1)).to eql([0, 2])
  end

  it "accepts a custom foreground color" do
    red = ChunkyPNG::Color.rgb(255, 0, 0)
    canvas = ChunkyPNG::Canvas.new(1, 2, [red, black])
    transform = described_class.from_canvas(canvas, red)

    expect(transform.squared_distances).to eql([0, 1])
    expect(transform.coordinates).to eql([[0, 0], [0, 0]])
  end

  it "keeps distances unchanged when the mask is translated" do
    active = [[0, 0], [2, 1], [1, 3]]
    original = mask(6, 5, active)
    translated = mask(6, 5, active.map { |x, y| [x + 2, y + 1] })

    original_transform = described_class.from_canvas(original)
    translated_transform = described_class.from_canvas(translated)

    original.height.times do |y|
      original.width.times do |x|
        translated_x = x + 2
        translated_y = y + 1
        next unless translated.include_xy?(translated_x, translated_y)

        expect(translated_transform.distance_at(translated_x, translated_y))
          .to eql(original_transform.distance_at(x, y))
      end
    end
  end

  it "keeps distances invariant under transposition" do
    active = [[0, 0], [2, 1], [1, 3], [3, 0]]
    canvas = mask(5, 4, active)
    transposed_pixels = canvas.pixels.each_slice(canvas.width).to_a
      .transpose.flatten
    transposed = ChunkyPNG::Canvas.new(canvas.height, canvas.width,
      transposed_pixels)

    transform = described_class.from_canvas(canvas)
    transposed_transform = described_class.from_canvas(transposed)

    canvas.height.times do |y|
      canvas.width.times do |x|
        expect(transposed_transform.distance_at(y, x))
          .to eql(transform.distance_at(x, y))
      end
    end
  end

  it "is available from ChunkyPNG::Image and the module facade" do
    canvas = ChunkyPNG::Image.new(1, 1, white)

    transform = canvas.squared_euclidean_distance_transform
    expect(transform.squared_distances).to eql([0])
    expect(transform.coordinates).to eql([[0, 0]])
    expect(
      ChunkyPNG::ImageAnalysis.squared_euclidean_distance_transform(canvas)
        .squared_distances
    ).to eql([0])
  end

  it "raises for an invalid mask" do
    expect { described_class.from_canvas(Object.new) }
      .to raise_error(ArgumentError)
  end

  it "raises for coordinates outside the result bounds" do
    transform = described_class.from_canvas(mask(1, 1, [[0, 0]]))

    expect { transform.distance_at(1, 0) }
      .to raise_error(ChunkyPNG::OutOfBounds)
    expect { transform.coordinates_at(0, 1) }
      .to raise_error(ChunkyPNG::OutOfBounds)
  end
end
