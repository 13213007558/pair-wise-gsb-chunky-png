require "spec_helper"

describe ChunkyPNG::Canvas::SeamCarving do
  INFINITE_ENERGY = ChunkyPNG::Canvas::SeamCarving::SEAM_INFINITE_ENERGY
  REMOVAL_BONUS = ChunkyPNG::Canvas::SeamCarving::SEAM_REMOVAL_BONUS

  def color_distance(pixel_a, pixel_b)
    (ChunkyPNG::Color.r(pixel_a) - ChunkyPNG::Color.r(pixel_b)).abs +
      (ChunkyPNG::Color.g(pixel_a) - ChunkyPNG::Color.g(pixel_b)).abs +
      (ChunkyPNG::Color.b(pixel_a) - ChunkyPNG::Color.b(pixel_b)).abs
  end

  # Computes the cost of a single seam using the same forward energy
  # definition as the implementation, so an exhaustive search over all
  # possible seams can verify that the optimal seam was selected.
  def seam_cost(pixels, width, seam, protect: nil, remove: nil)
    total = 0
    seam.each_with_index do |x, y|
      i = y * width + x
      total += INFINITE_ENERGY if protect && protect[i]
      total -= REMOVAL_BONUS if remove && remove[i]
      next if y == 0

      left = pixels[y * width + [x - 1, 0].max]
      right = pixels[y * width + [x + 1, width - 1].min]
      up = pixels[(y - 1) * width + x]
      cost_up = color_distance(left, right)

      case x - seam[y - 1]
      when -1 then total += cost_up + color_distance(up, left)
      when 0  then total += cost_up
      when 1  then total += cost_up + color_distance(up, right)
      end
    end
    total
  end

  # Enumerates every possible vertical seam: all paths from top to bottom
  # that move at most one column sideways per row.
  def all_seams(width, height)
    seams = []
    walk = lambda do |seam|
      if seam.length == height
        seams << seam.dup
      else
        x = seam.last
        ([x - 1, 0].max..[x + 1, width - 1].min).each { |nx| walk.call(seam + [nx]) }
      end
    end
    (0...width).each { |x| walk.call([x]) }
    seams
  end

  # Builds a canvas in which every pixel encodes its own coordinates, so
  # that pixel positions can be verified after carving.
  def coordinate_canvas(width, height)
    pixels = (0...width * height).map { |i| ChunkyPNG::Color.rgb(i % width, i / width, 0) }
    ChunkyPNG::Canvas.new(width, height, pixels)
  end

  # Removes the given seam positions (in original coordinates) from the
  # coordinate grid of the original image, mimicking what the carved image
  # should contain, in row-major order.
  def remaining_coordinates(width, height, seams)
    coordinates = (0...height).flat_map { |y| (0...width).map { |x| [x, y] } }
    seams.each do |seam|
      seam.each do |point|
        index = coordinates.index(point)
        raise "Seam point #{point.inspect} was already removed or is invalid" if index.nil?
        coordinates.delete_at(index)
      end
    end
    coordinates
  end

  def varied_canvas(width, height)
    pixels = (0...width * height).map do |i|
      ChunkyPNG::Color.rgb((i * 37) % 256, (i * 91) % 256, (i * 53) % 256)
    end
    ChunkyPNG::Canvas.new(width, height, pixels)
  end

  describe "seam optimality" do
    it "finds a minimal-cost seam, verified by exhaustive search" do
      canvas = varied_canvas(4, 4)
      result = canvas.carve_seams(1)
      seam = result.seams[0].map(&:first)

      chosen_cost = seam_cost(canvas.pixels, 4, seam)
      best_cost = all_seams(4, 4).map { |s| seam_cost(canvas.pixels, 4, s) }.min
      expect(chosen_cost).to eql best_cost
    end

    it "finds a minimal-cost seam with protection and removal masks, verified by exhaustive search" do
      canvas = varied_canvas(4, 4)
      protect = Array.new(16, false)
      protect[5] = true
      protect[9] = true
      remove = Array.new(16, false)
      remove[2] = true
      remove[14] = true

      result = canvas.carve_seams(1, protect_mask: protect, remove_mask: remove)
      seam = result.seams[0].map(&:first)

      chosen_cost = seam_cost(canvas.pixels, 4, seam, protect: protect, remove: remove)
      best_cost = all_seams(4, 4).map { |s| seam_cost(canvas.pixels, 4, s, protect: protect, remove: remove) }.min
      expect(chosen_cost).to eql best_cost
    end

    it "recomputes the energy after every removal, matching sequential single-seam carving" do
      canvas = varied_canvas(6, 5)
      multi = canvas.carve_seams(3)

      sequential = canvas
      3.times { sequential = sequential.carve_seams(1).image }

      expect(multi.image).to eql sequential
    end
  end

  describe "coordinate mapping" do
    it "maps every removed vertical seam position back to the original coordinates" do
      result = coordinate_canvas(6, 5).carve_seams(3, orientation: :vertical)

      expect(result.image.dimension).to eql ChunkyPNG::Dimension.new(3, 5)
      expect(result.seams.length).to eql 3
      result.seams.each { |seam| expect(seam.length).to eql 5 }

      expected = remaining_coordinates(6, 5, result.seams).map { |x, y| ChunkyPNG::Color.rgb(x, y, 0) }
      expect(result.image.pixels).to eql expected
    end

    it "maps every removed horizontal seam position back to the original coordinates" do
      result = coordinate_canvas(5, 6).carve_seams(3, orientation: :horizontal)

      expect(result.image.dimension).to eql ChunkyPNG::Dimension.new(5, 3)
      expect(result.seams.length).to eql 3
      result.seams.each { |seam| expect(seam.length).to eql 5 }

      expected = remaining_coordinates(5, 6, result.seams).map { |x, y| ChunkyPNG::Color.rgb(x, y, 0) }
      expect(result.image.pixels).to eql expected
    end
  end

  describe "protection mask" do
    it "never crosses protected pixels when an unprotected path exists" do
      protect = Array.new(16, false)
      4.times { |y| protect[y * 4] = true } # protect the leftmost column

      result = coordinate_canvas(4, 4).carve_seams(2, protect_mask: protect)
      result.seams.each do |seam|
        seam.each { |x, _y| expect(x).to be > 0 }
      end
    end

    it "raises an error instead of crossing protected pixels when every vertical seam is blocked" do
      protect = Array.new(16, false)
      4.times { |x| protect[4 + x] = true } # protect a full row

      expect { coordinate_canvas(4, 4).carve_seams(1, protect_mask: protect) }
        .to raise_error(ChunkyPNG::Exception, /protected/)
    end

    it "raises an error instead of crossing protected pixels when every horizontal seam is blocked" do
      protect = Array.new(16, false)
      4.times { |y| protect[y * 4 + 2] = true } # protect a full column

      expect { coordinate_canvas(4, 4).carve_seams(1, orientation: :horizontal, protect_mask: protect) }
        .to raise_error(ChunkyPNG::Exception, /protected/)
    end
  end

  describe "removal mask" do
    it "prefers pixels marked for priority removal" do
      canvas = ChunkyPNG::Canvas.new(5, 4, ChunkyPNG::Color::WHITE)
      remove = Array.new(20, false)
      4.times { |y| remove[y * 5 + 2] = true }

      result = canvas.carve_seams(1, remove_mask: remove)
      expect(result.seams[0].map(&:first)).to eql [2, 2, 2, 2]
    end
  end

  describe "masks" do
    it "accepts a canvas as mask, in which non-transparent pixels count as masked" do
      mask = ChunkyPNG::Canvas.new(4, 4, ChunkyPNG::Color::TRANSPARENT)
      4.times { |x| mask[x, 2] = ChunkyPNG::Color::BLACK } # protect a full row

      expect { coordinate_canvas(4, 4).carve_seams(1, protect_mask: mask) }
        .to raise_error(ChunkyPNG::Exception, /protected/)
    end

    it "raises an error when a mask does not match the canvas dimensions" do
      expect { coordinate_canvas(3, 3).carve_seams(1, protect_mask: [true]) }
        .to raise_error(ChunkyPNG::ExpectationFailed)
      expect { coordinate_canvas(3, 3).carve_seams(1, remove_mask: ChunkyPNG::Canvas.new(2, 2)) }
        .to raise_error(ChunkyPNG::ExpectationFailed)
    end
  end

  describe "size limits" do
    it "allows carving down to a single column or row" do
      expect(coordinate_canvas(3, 2).carve_seams(2).image.dimension)
        .to eql ChunkyPNG::Dimension.new(1, 2)
      expect(coordinate_canvas(2, 3).carve_seams(2, orientation: :horizontal).image.dimension)
        .to eql ChunkyPNG::Dimension.new(2, 1)
    end

    it "raises ArgumentError when more seams are requested than can be removed" do
      expect { coordinate_canvas(3, 2).carve_seams(3) }.to raise_error(ArgumentError)
      expect { coordinate_canvas(1, 2).carve_seams(1) }.to raise_error(ArgumentError)
      expect { coordinate_canvas(2, 1).carve_seams(1, orientation: :horizontal) }.to raise_error(ArgumentError)
    end

    it "raises ArgumentError for a negative count or an invalid orientation" do
      expect { coordinate_canvas(3, 3).carve_seams(-1) }.to raise_error(ArgumentError)
      expect { coordinate_canvas(3, 3).carve_seams(1, orientation: :diagonal) }.to raise_error(ArgumentError)
    end
  end

  describe "#carve_seams" do
    it "does not modify the original canvas" do
      canvas = coordinate_canvas(4, 4)
      expect { canvas.carve_seams(2) }.to_not(change { canvas.dimension })
    end
  end

  describe "#carve_seams!" do
    it "modifies the canvas in place and returns it in the result" do
      canvas = coordinate_canvas(4, 4)
      result = canvas.carve_seams!(2)
      expect(result.image).to equal canvas
      expect(canvas.dimension).to eql ChunkyPNG::Dimension.new(2, 4)
    end
  end
end
