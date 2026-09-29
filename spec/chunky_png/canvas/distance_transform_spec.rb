require "spec_helper"

describe ChunkyPNG::Canvas::DistanceTransform do
  def mask_canvas(width, height, seeds)
    pixels = Array.new(width * height, ChunkyPNG::Color::BLACK)
    seeds.each { |(x, y)| pixels[y * width + x] = ChunkyPNG::Color::WHITE }
    ChunkyPNG::Canvas.new(width, height, pixels)
  end

  def random_seeds(width, height, count, rng)
    (0...(width * height)).to_a.sample(count, random: rng).map { |i| [i % width, i / width] }
  end

  # Reference implementation: compares every pixel with every seed, breaking
  # ties by coordinate order (topmost first, then leftmost).
  def brute_force_transform(width, height, seeds)
    distances = Array.new(width * height)
    nearest = Array.new(width * height)
    height.times do |y|
      width.times do |x|
        best = seeds.min_by { |(sx, sy)| [(x - sx)**2 + (y - sy)**2, sy, sx] }
        next unless best
        distances[y * width + x] = (x - best[0])**2 + (y - best[1])**2
        nearest[y * width + x] = ChunkyPNG::Point.new(best[0], best[1])
      end
    end
    [distances, nearest]
  end

  describe "#distance_transform" do
    it "matches a brute force transform on small masks" do
      rng = Random.new(42)
      [[5, 4, 3], [8, 6, 5], [7, 7, 12], [3, 3, 1], [16, 1, 3], [1, 16, 3]].each do |w, h, count|
        seeds = random_seeds(w, h, count, rng)
        result = mask_canvas(w, h, seeds).distance_transform
        expected_distances, expected_nearest = brute_force_transform(w, h, seeds)
        expect(result.distances).to eql expected_distances
        expect(result.nearest).to eql expected_nearest
      end
    end

    it "matches a brute force transform on a larger mask" do
      rng = Random.new(123)
      seeds = random_seeds(60, 45, 40, rng)
      result = mask_canvas(60, 45, seeds).distance_transform
      expected_distances, expected_nearest = brute_force_transform(60, 45, seeds)
      expect(result.distances).to eql expected_distances
      expect(result.nearest).to eql expected_nearest
    end

    it "reports the dimensions of the mask" do
      result = mask_canvas(5, 3, [[0, 0]]).distance_transform
      expect(result.width).to eql 5
      expect(result.height).to eql 3
    end

    it "returns exact integer distances that exceed the 8-bit channel range" do
      result = mask_canvas(30, 20, [[0, 0]]).distance_transform
      expect(result.distance_at(29, 19)).to eql (29**2) + (19**2)
      expect(result.distance_at(29, 19)).to be > 255
      expect(result.nearest_at(29, 19)).to eql ChunkyPNG::Point.new(0, 0)
    end

    it "breaks ties by coordinate order, topmost first, then leftmost" do
      # (2, 2) is at squared distance 5 from both (3, 0) and (0, 1);
      # (3, 0) wins because it has the smaller y-coordinate.
      result = mask_canvas(4, 3, [[3, 0], [0, 1]]).distance_transform
      expect(result.distance_at(2, 2)).to eql 5
      expect(result.nearest_at(2, 2)).to eql ChunkyPNG::Point.new(3, 0)
    end

    it "prefers the leftmost seed for ties within a single row" do
      result = mask_canvas(5, 1, [[0, 0], [4, 0]]).distance_transform
      expect(result.distance_at(2, 0)).to eql 4
      expect(result.nearest_at(2, 0)).to eql ChunkyPNG::Point.new(0, 0)
    end

    it "prefers the topmost seed for ties within a single column" do
      result = mask_canvas(1, 5, [[0, 0], [0, 4]]).distance_transform
      expect(result.distance_at(0, 2)).to eql 4
      expect(result.nearest_at(0, 2)).to eql ChunkyPNG::Point.new(0, 0)
    end

    it "uses nil for every pixel when the mask has no foreground pixels" do
      result = mask_canvas(4, 3, []).distance_transform
      expect(result.distances).to eql Array.new(12, nil)
      expect(result.nearest).to eql Array.new(12, nil)
    end

    it "returns zero distances and each pixel itself for an all-foreground mask" do
      seeds = (0...12).map { |i| [i % 4, i / 4] }
      result = mask_canvas(4, 3, seeds).distance_transform
      expect(result.distances).to eql Array.new(12, 0)
      3.times do |y|
        4.times do |x|
          expect(result.nearest_at(x, y)).to eql ChunkyPNG::Point.new(x, y)
        end
      end
    end

    it "supports a custom foreground color" do
      red = ChunkyPNG::Color.rgb(255, 0, 0)
      canvas = ChunkyPNG::Canvas.new(3, 1, ChunkyPNG::Color::BLACK)
      canvas[2, 0] = red
      result = canvas.distance_transform(red)
      expect(result.distances).to eql [4, 1, 0]
      expect(result.nearest).to eql [ChunkyPNG::Point.new(2, 0)] * 3
    end

    it "preserves distances under translation of the mask" do
      rng = Random.new(7)
      seeds = random_seeds(6, 5, 6, rng)
      dx, dy = 3, 2
      base = mask_canvas(6, 5, seeds).distance_transform
      shifted_seeds = seeds.map { |(x, y)| [x + dx, y + dy] }
      shifted = mask_canvas(6 + dx, 5 + dy, shifted_seeds).distance_transform
      5.times do |y|
        6.times do |x|
          expect(shifted.distance_at(x + dx, y + dy)).to eql base.distance_at(x, y)
          nearest = base.nearest_at(x, y)
          expect(shifted.nearest_at(x + dx, y + dy)).to eql ChunkyPNG::Point.new(nearest.x + dx, nearest.y + dy)
        end
      end
    end

    it "transposes distances and coordinates when the mask is transposed" do
      rng = Random.new(11)
      seeds = random_seeds(7, 4, 6, rng)
      base = mask_canvas(7, 4, seeds).distance_transform
      transposed_seeds = seeds.map { |(x, y)| [y, x] }
      transposed = mask_canvas(4, 7, transposed_seeds).distance_transform
      4.times do |y|
        7.times do |x|
          expect(transposed.distance_at(y, x)).to eql base.distance_at(x, y)
          # The coordinate order of the nearest seed is only preserved for
          # uniquely determined winners: transposition swaps the coordinate
          # priority used to break ties between equidistant seeds.
          tied = seeds.select { |(sx, sy)| (x - sx)**2 + (y - sy)**2 == base.distance_at(x, y) }
          winner = transposed.nearest_at(y, x)
          if tied.one?
            nearest = base.nearest_at(x, y)
            expect(winner).to eql ChunkyPNG::Point.new(nearest.y, nearest.x)
          else
            expect(tied.map { |(sx, sy)| [sy, sx] }).to include winner.to_a
          end
        end
      end
    end
  end
end
