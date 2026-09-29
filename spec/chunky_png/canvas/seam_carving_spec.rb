require "spec_helper"

describe ChunkyPNG::Canvas::SeamCarving do
  def grayscale_canvas(values, width, height)
    raise "incorrect number of values" unless values.length == width * height
    ChunkyPNG::Canvas.new(width, height, values.map { |v| ChunkyPNG::Color.rgb(v, v, v) })
  end

  def grayscale_values(canvas)
    canvas.pixels.map { |pixel| ChunkyPNG::Color.r(pixel) }
  end

  def mask_canvas(width, height, masked_coords)
    canvas = ChunkyPNG::Canvas.new(width, height, ChunkyPNG::Color::TRANSPARENT)
    masked_coords.each { |x, y| canvas[x, y] = ChunkyPNG::Color::WHITE }
    canvas
  end

  # Independent re-implementation of the energy map, used to verify the
  # seam costs by exhaustively enumerating all possible seams.
  def energy_map(canvas)
    gray = canvas.pixels.map do |pixel|
      (ChunkyPNG::Color.r(pixel) * 299 + ChunkyPNG::Color.g(pixel) * 587 + ChunkyPNG::Color.b(pixel) * 114) / 1000
    end
    w = canvas.width
    h = canvas.height
    Array.new(w * h) do |i|
      x = i % w
      y = i / w
      gx = gray[y * w + [x + 1, w - 1].min] - gray[y * w + [x - 1, 0].max]
      gy = gray[[y + 1, h - 1].min * w + x] - gray[[y - 1, 0].max * w + x]
      gx.abs + gy.abs
    end
  end

  # Enumerates every possible vertical seam and returns the minimum cost.
  def exhaustive_vertical_cost(energy, w, h)
    best = Float::INFINITY
    walk = lambda do |x, y, total|
      total += energy[y * w + x]
      if y == h - 1
        best = total if total < best
      else
        walk.call(x - 1, y + 1, total) if x > 0
        walk.call(x, y + 1, total)
        walk.call(x + 1, y + 1, total) if x < w - 1
      end
    end
    (0...w).each { |x| walk.call(x, 0, 0) }
    best
  end

  def seam_cost(energy, w, seam)
    seam.each_with_index.sum { |x, y| energy[y * w + x] }
  end

  describe "#carve_seams" do
    it "should not modify the original canvas" do
      canvas = grayscale_canvas([0, 0, 255, 0, 0, 255], 3, 2)
      expect { canvas.carve_seams(vertical: 1) }.to_not change { canvas.pixels }
    end

    it "should remove the lowest energy column" do
      canvas = grayscale_canvas([0, 0, 255, 0, 0, 255], 3, 2)
      result = canvas.carve_seams(vertical: 1)
      expect(result.width).to eql 2
      expect(result.height).to eql 2
      expect(grayscale_values(result.canvas)).to eql [0, 255, 0, 255]
      expect(result.seams.length).to eql 1
      expect(result.seams[0].orientation).to eql :vertical
      expect(result.seams[0].points).to eql [[0, 0], [0, 1]]
    end

    it "should remove the lowest energy row for horizontal seams" do
      canvas = grayscale_canvas([0, 0, 0, 0, 255, 255, 255, 255], 4, 2)
      result = canvas.carve_seams(horizontal: 1)
      expect(result.width).to eql 4
      expect(result.height).to eql 1
      expect(grayscale_values(result.canvas)).to eql [255, 255, 255, 255]
      expect(result.seams[0].orientation).to eql :horizontal
      expect(result.seams[0].points).to eql [[0, 0], [1, 0], [2, 0], [3, 0]]
    end

    it "should return an empty seam list when nothing is removed" do
      canvas = grayscale_canvas([0, 0, 255, 0, 0, 255], 3, 2)
      result = canvas.carve_seams
      expect(result.canvas).to eql canvas
      expect(result.seams).to be_empty
    end

    context "argument validation" do
      let(:canvas) { grayscale_canvas([0, 0, 255, 0, 0, 255], 3, 2) }

      it "should raise an ArgumentError for negative seam counts" do
        expect { canvas.carve_seams(vertical: -1) }.to raise_error(ArgumentError)
        expect { canvas.carve_seams(horizontal: -1) }.to raise_error(ArgumentError)
      end

      it "should allow carving down to a width or height of 1" do
        expect(canvas.carve_seams(vertical: 2).width).to eql 1
        expect(canvas.carve_seams(horizontal: 1).height).to eql 1
      end

      it "should raise an ArgumentError when the width or height would drop below 1" do
        expect { canvas.carve_seams(vertical: 3) }.to raise_error(ArgumentError)
        expect { canvas.carve_seams(horizontal: 2) }.to raise_error(ArgumentError)
        expect { canvas.carve_seams(vertical: 2, horizontal: 2) }.to raise_error(ArgumentError)
      end

      it "should raise an ArgumentError when removing another seam from a 1 pixel wide canvas" do
        one_wide = grayscale_canvas([0, 0], 1, 2)
        expect { one_wide.carve_seams(vertical: 1) }.to raise_error(ArgumentError)
        expect(one_wide.carve_seams(horizontal: 1).height).to eql 1
      end

      it "should raise an ArgumentError when a mask has the wrong dimensions" do
        mask = ChunkyPNG::Canvas.new(2, 2, ChunkyPNG::Color::WHITE)
        expect { canvas.carve_seams(vertical: 1, protect_mask: mask) }.to raise_error(ArgumentError)
        expect { canvas.carve_seams(vertical: 1, remove_mask: mask) }.to raise_error(ArgumentError)
      end
    end

    context "energy recomputation" do
      # After removing the first seam (column 1), columns 0 and 2 become
      # adjacent. The energy of this new adjacency only exists after
      # recomputing the gradient map: reusing the initial gradient map
      # would remove original column 2 next, leaving [7, 128].
      it "should account for new adjacencies formed by removed seams" do
        canvas = grayscale_canvas([7, 255, 0, 128], 4, 1)
        result = canvas.carve_seams(vertical: 2)
        expect(grayscale_values(result.canvas)).to eql [0, 128]
        expect(result.seams.map(&:points)).to eql [[[1, 0]], [[0, 0]]]
      end
    end

    context "exhaustive cost verification" do
      let(:canvas) do
        random = Random.new(12_345)
        grayscale_canvas(Array.new(30) { random.rand(256) }, 6, 5)
      end

      it "should find a vertical seam with the exhaustively minimal cost" do
        energy = energy_map(canvas)
        result = canvas.carve_seams(vertical: 1)
        seam = result.seams[0].points.map(&:first)
        expect(seam_cost(energy, 6, seam)).to eql exhaustive_vertical_cost(energy, 6, 5)
      end

      it "should find a horizontal seam with the exhaustively minimal cost" do
        energy = energy_map(canvas)
        transposed = Array.new(30) { |i| energy[(i % 5) * 6 + i / 5] }
        result = canvas.carve_seams(horizontal: 1)
        seam = result.seams[0].points.map(&:last)
        expect(seam_cost(transposed, 5, seam)).to eql exhaustive_vertical_cost(transposed, 5, 6)
      end
    end

    context "consecutive removals" do
      let(:canvas) do
        random = Random.new(999)
        ChunkyPNG::Canvas.new(8, 6, Array.new(48) { ChunkyPNG::Color.rgb(random.rand(256), random.rand(256), random.rand(256)) })
      end

      it "should return carved pixels that match the original coordinates of the seams" do
        result = canvas.carve_seams(vertical: 3, horizontal: 2)
        expect(result.width).to eql 5
        expect(result.height).to eql 4
        expect(result.seams.length).to eql 5

        # Replay the removals on a grid of original coordinates.
        grid = (0...6).map { |y| (0...8).map { |x| [x, y] } }
        result.seams.each do |seam|
          expected_length = (seam.orientation == :vertical) ? grid.length : grid.first.length
          expect(seam.points.length).to eql expected_length
          if seam.orientation == :vertical
            # A vertical seam removes one pixel from every row.
            seam.points.each do |point|
              row = grid.find { |r| r.include?(point) }
              expect(row).to_not be_nil
              row.delete_at(row.index(point))
            end
          else
            # A horizontal seam removes one pixel from every column; the
            # pixels below shift up within their column.
            new_grid = Array.new(grid.length - 1) { Array.new(grid.first.length) }
            grid.first.length.times do |x|
              removed_y = grid.index { |r| r.include?(seam.points[x]) }
              expect(removed_y).to_not be_nil
              yi = 0
              grid.length.times do |y|
                next if y == removed_y
                new_grid[yi][x] = grid[y][x]
                yi += 1
              end
            end
            grid = new_grid
          end
        end

        remaining = grid.flatten(1)
        expect(remaining.length).to eql 20
        result.canvas.pixels.each_with_index do |pixel, i|
          original_x, original_y = remaining[i]
          expect(pixel).to eql canvas[original_x, original_y]
        end
      end

      it "should map every removed seam pixel to unique original coordinates" do
        result = canvas.carve_seams(vertical: 3, horizontal: 2)
        all_points = result.seams.flat_map(&:points)
        expect(all_points.uniq.length).to eql all_points.length
        all_points.each do |x, y|
          expect(x).to be_between(0, 7)
          expect(y).to be_between(0, 5)
        end
      end
    end

    context "with a protection mask" do
      let(:canvas) do
        random = Random.new(77)
        grayscale_canvas(Array.new(12) { random.rand(256) }, 4, 3)
      end

      it "should never cross protected pixels" do
        protected = (0...3).flat_map { |y| (0...4).map { |x| [x, y] } } - [[1, 0], [1, 1], [1, 2]]
        mask = mask_canvas(4, 3, protected)
        result = canvas.carve_seams(vertical: 1, protect_mask: mask)
        expect(result.seams[0].points).to eql [[1, 0], [1, 1], [1, 2]]
      end

      it "should stop and explain when the mask blocks every feasible path" do
        full_row = (0...4).map { |x| [x, 1] }
        mask = mask_canvas(4, 3, full_row)
        expect { canvas.carve_seams(vertical: 1, protect_mask: mask) }
          .to raise_error(ChunkyPNG::Canvas::SeamCarving::NoFeasibleSeamError, /protection mask blocks every feasible path/)
      end

      it "should stop and explain when the whole canvas is protected" do
        mask = ChunkyPNG::Canvas.new(4, 3, ChunkyPNG::Color::WHITE)
        expect { canvas.carve_seams(vertical: 1, protect_mask: mask) }
          .to raise_error(ChunkyPNG::Canvas::SeamCarving::NoFeasibleSeamError)
        expect { canvas.carve_seams(horizontal: 1, protect_mask: mask) }
          .to raise_error(ChunkyPNG::Canvas::SeamCarving::NoFeasibleSeamError)
      end

      it "should carve the seams that are feasible before stopping" do
        canvas = grayscale_canvas([0, 0, 0, 255, 0, 0, 0, 255], 4, 2)
        # Protect the two rightmost columns; after two carvings only
        # protected columns remain and every vertical path is blocked.
        mask = mask_canvas(4, 2, [[2, 0], [2, 1], [3, 0], [3, 1]])
        expect { canvas.carve_seams(vertical: 3, protect_mask: mask) }
          .to raise_error(ChunkyPNG::Canvas::SeamCarving::NoFeasibleSeamError, /seam 3 of 3/)
      end
    end

    context "with a removal priority mask" do
      it "should prefer carving through the marked pixels" do
        canvas = ChunkyPNG::Canvas.new(4, 3, ChunkyPNG::Color.rgb(100, 100, 100))
        mask = mask_canvas(4, 3, [[2, 0], [2, 1], [2, 2]])
        result = canvas.carve_seams(vertical: 1, remove_mask: mask)
        expect(result.seams[0].points).to eql [[2, 0], [2, 1], [2, 2]]
      end

      it "should carve the mask along with the image across consecutive removals" do
        canvas = ChunkyPNG::Canvas.new(4, 3, ChunkyPNG::Color.rgb(100, 100, 100))
        mask = mask_canvas(4, 3, [[3, 0], [3, 1], [3, 2]])
        result = canvas.carve_seams(vertical: 2, remove_mask: mask)
        expect(result.seams[0].points).to eql [[3, 0], [3, 1], [3, 2]]
        expect(result.seams[1].points).to eql [[0, 0], [0, 1], [0, 2]]
      end

      it "should let protection win over removal priority" do
        canvas = ChunkyPNG::Canvas.new(4, 3, ChunkyPNG::Color.rgb(100, 100, 100))
        column = [[2, 0], [2, 1], [2, 2]]
        result = canvas.carve_seams(vertical: 1,
          remove_mask: mask_canvas(4, 3, column),
          protect_mask: mask_canvas(4, 3, column))
        expect(result.seams[0].points.map(&:first)).to_not include(2)
      end
    end
  end
end
