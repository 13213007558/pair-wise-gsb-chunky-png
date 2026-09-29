# frozen-string-literal: true

module ChunkyPNG
  class Canvas
    # The ChunkyPNG::Canvas::SeamCarving module implements content-aware image
    # resizing using the seam carving algorithm. Instead of scaling every
    # pixel uniformly, it removes the "least important" seams: connected
    # paths of pixels that cross the image from one side to the other with
    # the lowest total energy.
    #
    # The energy of a pixel is based on the gradient between its neighbors,
    # using the forward energy criterion: the cost of a seam pixel includes
    # the energy introduced by the new neighbors that become adjacent once
    # the pixel is removed. Because removing a seam changes the image, the
    # energy map is recomputed from scratch before every seam removal.
    #
    # Two optional masks influence seam selection:
    #
    # * A protection mask marks pixels that seams are not allowed to cross.
    #   If the protected pixels block every possible seam, an exception is
    #   raised instead of silently carving through them.
    # * A removal mask marks pixels that seams should preferably cross,
    #   e.g. content you want to get rid of first.
    #
    # Both masks can be given as an Array of booleans (row-major, one element
    # per pixel) or as a {ChunkyPNG::Canvas} of the same dimensions in which
    # every non-transparent pixel counts as masked.
    #
    # @see ChunkyPNG::Canvas
    module SeamCarving
      # Energy assigned to protected pixels. This is deliberately orders of
      # magnitude larger than any gradient-based energy, so a seam will only
      # cross a protected pixel when no unprotected path exists at all.
      # @private
      SEAM_INFINITE_ENERGY = 1 << 62

      # Energy bonus assigned to pixels marked for priority removal. Large
      # enough to outweigh gradient-based energies, small enough to never
      # cancel out {SEAM_INFINITE_ENERGY}.
      # @private
      SEAM_REMOVAL_BONUS = 1 << 30

      # The result of a seam carving operation: the carved image together
      # with the position of every removed seam, mapped back to the
      # coordinate system of the original image.
      class CarveResult
        # @return [ChunkyPNG::Canvas] The image after removing the seams.
        attr_reader :image

        # @return [Array<Array<Array(Integer, Integer)>>] One entry per
        #   removed seam, in removal order. Each entry lists the
        #   <tt>[x, y]</tt> coordinates of the removed pixels in the
        #   coordinate system of the original image, ordered from top to
        #   bottom for vertical seams and from left to right for horizontal
        #   seams.
        attr_reader :seams

        # @private
        def initialize(image, seams)
          @image = image
          @seams = seams
        end
      end

      # Removes seams from the canvas using seam carving, leaving the current
      # canvas intact.
      #
      # @param (see #carve_seams!)
      # @return (see #carve_seams!)
      # @see #carve_seams!
      def carve_seams(count, orientation: :vertical, protect_mask: nil, remove_mask: nil)
        dup.carve_seams!(count, orientation: orientation, protect_mask: protect_mask, remove_mask: remove_mask)
      end

      # Removes seams from the canvas using seam carving, modifying the
      # current canvas.
      #
      # Reducing the width (for vertical seams) or height (for horizontal
      # seams) down to a single pixel is allowed; requesting more removals
      # than that raises an {ArgumentError}.
      #
      # @param [Integer] count The number of seams to remove.
      # @param [Symbol] orientation Either +:vertical+ to remove vertical
      #   seams (reducing the width) or +:horizontal+ to remove horizontal
      #   seams (reducing the height).
      # @param [nil, Array, ChunkyPNG::Canvas] protect_mask Pixels that seams
      #   may never cross. See the module description for accepted formats.
      # @param [nil, Array, ChunkyPNG::Canvas] remove_mask Pixels that seams
      #   should preferably cross. See the module description for accepted
      #   formats.
      # @return [ChunkyPNG::Canvas::SeamCarving::CarveResult] The carving
      #   result, containing the carved image and the removed seam positions
      #   mapped to the original image's coordinates.
      # @raise [ArgumentError] when the number of seams is negative, when
      #   more seams are requested than can be removed while keeping at
      #   least one row/column, or when the orientation is invalid.
      # @raise [ChunkyPNG::ExpectationFailed] when a mask does not match the
      #   canvas dimensions.
      # @raise [ChunkyPNG::Exception] when the protected pixels block every
      #   possible seam.
      def carve_seams!(count, orientation: :vertical, protect_mask: nil, remove_mask: nil)
        unless count.is_a?(Integer) && count >= 0
          raise ArgumentError, "The number of seams to remove should be a non-negative integer, got #{count.inspect}"
        end
        unless [:vertical, :horizontal].include?(orientation)
          raise ArgumentError, "The orientation should be :vertical or :horizontal, got #{orientation.inspect}"
        end

        length = (orientation == :vertical) ? width : height
        if count > length - 1
          raise ArgumentError,
            "Cannot remove #{count} #{orientation} seams from a #{width}x#{height} canvas: " +            "at least one #{(orientation == :vertical) ? "column" : "row"} should remain"
        end

        protect = seam_carving_mask(protect_mask, :protect_mask)
        remove = seam_carving_mask(remove_mask, :remove_mask)

        # Horizontal seams are carved by transposing the image, removing
        # vertical seams, and transposing the result back. The coordinate
        # map is transposed along, so seam positions are always reported in
        # the original image's coordinate system.
        transposed = (orientation == :horizontal)
        coordinates = Array.new(width * height) { |i| [i % width, i / width] }
        grid = transposed ? seam_carving_transpose(pixels, width, height) : pixels.dup
        coordinates = seam_carving_transpose(coordinates, width, height) if transposed
        protect = seam_carving_transpose(protect, width, height) if protect && transposed
        remove = seam_carving_transpose(remove, width, height) if remove && transposed
        grid_width = transposed ? height : width
        grid_height = transposed ? width : height

        seams = []
        count.times do
          # The energy map is recomputed for every seam, so the energy
          # always reflects the adjacencies created by earlier removals.
          seam = seam_carving_find_seam(grid, grid_width, grid_height, protect, remove)
          seams << seam.each_with_index.map { |x, y| coordinates[y * grid_width + x] }
          grid = seam_carving_remove_seam(grid, grid_width, grid_height, seam)
          coordinates = seam_carving_remove_seam(coordinates, grid_width, grid_height, seam)
          protect = seam_carving_remove_seam(protect, grid_width, grid_height, seam) if protect
          remove = seam_carving_remove_seam(remove, grid_width, grid_height, seam) if remove
          grid_width -= 1
        end

        if transposed
          replace_canvas!(grid_height, grid_width, seam_carving_transpose(grid, grid_width, grid_height))
        else
          replace_canvas!(grid_width, grid_height, grid)
        end
        CarveResult.new(self, seams)
      end

      private

      # Normalizes a seam carving mask to an array of booleans, or nil when
      # no mask was given.
      # @private
      def seam_carving_mask(mask, name)
        case mask
        when nil
          nil
        when ChunkyPNG::Canvas
          unless mask.width == width && mask.height == height
            raise ChunkyPNG::ExpectationFailed,
              "The #{name} canvas (#{mask.width}x#{mask.height}) should have the same dimensions as this canvas (#{width}x#{height})!"
          end
          mask.pixels.map { |pixel| ChunkyPNG::Color.a(pixel) > 0 }
        when Array
          unless mask.length == width * height
            raise ChunkyPNG::ExpectationFailed,
              "The #{name} should have #{width * height} elements, got #{mask.length}!"
          end
          mask.map { |value| !!value }
        else
          raise ArgumentError, "The #{name} should be a ChunkyPNG::Canvas, an Array of booleans, or nil"
        end
      end

      # Transposes a row-major matrix of +width+ x +height+ elements.
      # @private
      def seam_carving_transpose(values, width, height)
        result = Array.new(width * height)
        for y in 0...height
          for x in 0...width
            result[x * height + y] = values[y * width + x]
          end
        end
        result
      end

      # Sum of the absolute differences of the red, green and blue channels
      # of two pixels.
      # @private
      def seam_carving_color_distance(pixel_a, pixel_b)
        (ChunkyPNG::Color.r(pixel_a) - ChunkyPNG::Color.r(pixel_b)).abs +
          (ChunkyPNG::Color.g(pixel_a) - ChunkyPNG::Color.g(pixel_b)).abs +
          (ChunkyPNG::Color.b(pixel_a) - ChunkyPNG::Color.b(pixel_b)).abs
      end

      # Finds the lowest-energy vertical seam in a row-major pixel grid,
      # using forward energy: the cost of a pixel includes the gradient
      # between the neighbors that become adjacent when the pixel (and the
      # rest of the seam) is removed.
      #
      # @return [Array<Integer>] The column index of the seam for every row.
      # @raise [ChunkyPNG::Exception] when protected pixels block every seam.
      # @private
      def seam_carving_find_seam(grid, grid_width, grid_height, protect, remove)
        cost = Array.new(grid_width * grid_height, 0)
        choice = Array.new(grid_width * grid_height, 0)

        for y in 0...grid_height
          row = y * grid_width
          for x in 0...grid_width
            i = row + x

            base = 0
            base += SEAM_INFINITE_ENERGY if protect && protect[i]
            base -= SEAM_REMOVAL_BONUS if remove && remove[i]

            if y == 0
              cost[i] = base
              next
            end

            left = grid[row + ((x == 0) ? 0 : x - 1)]
            right = grid[row + ((x == grid_width - 1) ? grid_width - 1 : x + 1)]
            up = grid[row - grid_width + x]

            cost_up = seam_carving_color_distance(left, right)
            cost_left = cost_up + seam_carving_color_distance(up, left)
            cost_right = cost_up + seam_carving_color_distance(up, right)

            best_cost = nil
            best_offset = 0
            [[-1, cost_left], [0, cost_up], [1, cost_right]].each do |offset, energy|
              predecessor_x = x + offset
              next if predecessor_x < 0 || predecessor_x >= grid_width
              total = cost[row - grid_width + predecessor_x] + energy
              if best_cost.nil? || total < best_cost
                best_cost = total
                best_offset = offset
              end
            end

            cost[i] = base + best_cost
            choice[i] = best_offset
          end
        end

        last_row = (grid_height - 1) * grid_width
        best_x = 0
        for x in 1...grid_width
          best_x = x if cost[last_row + x] < cost[last_row + best_x]
        end

        if cost[last_row + best_x] >= SEAM_INFINITE_ENERGY
          raise ChunkyPNG::Exception,
            "Cannot carve a seam: the protected pixels block every possible seam across the image"
        end

        seam = Array.new(grid_height)
        x = best_x
        (grid_height - 1).downto(0) do |y|
          seam[y] = x
          x -= choice[y * grid_width + x]
        end
        seam
      end

      # Removes a vertical seam from a row-major grid, returning a new grid
      # with one column less.
      # @private
      def seam_carving_remove_seam(grid, grid_width, grid_height, seam)
        new_width = grid_width - 1
        result = Array.new(new_width * grid_height)
        for y in 0...grid_height
          source_row = y * grid_width
          target_row = y * new_width
          seam_x = seam[y]
          for x in 0...grid_width
            next if x == seam_x
            result[target_row + ((x < seam_x) ? x : x - 1)] = grid[source_row + x]
          end
        end
        result
      end
    end
  end
end
