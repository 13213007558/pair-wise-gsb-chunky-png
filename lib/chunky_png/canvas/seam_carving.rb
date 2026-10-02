# frozen-string-literal: true

module ChunkyPNG
  class Canvas
    # The ChunkyPNG::Canvas::SeamCarving module implements content-aware
    # image resizing by removing seams: connected paths of low-energy
    # pixels that run from one edge of the image to the opposite edge.
    #
    # Instead of uniformly squashing every pixel like resampling does, seam
    # carving removes pixels from the least interesting (flattest) regions
    # of the image, so important content such as logos or text is not
    # deformed. Only shrinking is supported; use the resampling methods to
    # enlarge an image.
    #
    # == Energy function
    #
    # The energy of a pixel measures how much it differs from its
    # neighbors. It is defined as the sum of the absolute differences of
    # all four channels (red, green, blue and alpha) between its left and
    # right neighbor, plus the same sum between its upper and lower
    # neighbor:
    #
    #   E(x, y) = |c(x-1, y) - c(x+1, y)| + |c(x, y-1) - c(x, y+1)|
    #
    # where |c(a) - c(b)| sums the per-channel absolute differences. For
    # pixels on the border of the image, the missing neighbor is replaced
    # by the pixel itself, so that term contributes 0. Flat regions have
    # an energy of (close to) zero; edges and details have high energy.
    #
    # == Seam selection and tie-breaking
    #
    # A vertical seam contains exactly one pixel per row; consecutive
    # pixels may move at most one column to the left or right. The cost of
    # a seam is the sum of the energies of its pixels, and the seam with
    # the lowest total cost is found with dynamic programming. Ties are
    # broken deterministically:
    #
    # - When the predecessors of a cell have equal cumulative cost, the
    #   leftmost predecessor is chosen (for horizontal seams: the topmost).
    # - When several seams have the same minimal total cost, the leftmost
    #   seam is chosen (for horizontal seams: the topmost).
    #
    # == Protection masks
    #
    # An optional protection mask (a canvas of the same dimensions, in
    # which every pixel with a non-zero alpha channel is protected) marks
    # pixels that no seam may cross. Protected pixels are given an
    # effectively infinite energy, so seams route around them whenever
    # any feasible path exists. The mask is carved together with the
    # image: every time a seam is removed from the image, the same seam
    # is removed from the mask, so both stay in sync.
    #
    # If the requested size cannot be reached because every remaining
    # seam would cross protected pixels, a
    # {ChunkyPNG::Canvas::SeamCarving::ProtectionConflict} exception is
    # raised that explains why. The protected region is never crossed
    # just to reach the requested dimensions.
    #
    # @see ChunkyPNG::Canvas::Resampling
    module SeamCarving
      # Exception raised when the requested dimensions cannot be reached
      # because every remaining seam would cross protected pixels.
      class ProtectionConflict < ChunkyPNG::Exception
      end

      # The energy assigned to protected pixels. Any seam that crosses a
      # protected pixel costs at least this much, while any unprotected
      # seam costs strictly less (a single pixel contributes at most
      # 8 * 255), so protected pixels are avoided whenever a feasible
      # seam exists.
      # @private
      PROTECTED_ENERGY = (1 << 62)

      # Returns a copy of the canvas, shrunk to the given dimensions by
      # removing low-energy seams.
      #
      # @param [Integer] new_width The width of the carved canvas. Must be
      #   between 1 and the current width.
      # @param [Integer] new_height The height of the carved canvas. Must
      #   be between 1 and the current height.
      # @param [ChunkyPNG::Canvas, nil] mask Optional protection mask: a
      #   canvas of the same dimensions in which pixels with a non-zero
      #   alpha channel may not be crossed by any seam.
      # @return [Array(ChunkyPNG::Canvas, ChunkyPNG::Canvas)] The carved
      #   canvas and the carved protection mask (+nil+ when no mask was
      #   given). Both are new instances; the receiver and the given mask
      #   are left untouched.
      # @raise [ArgumentError] when the requested dimensions are larger
      #   than the current ones, or when the mask dimensions do not match.
      # @raise [ChunkyPNG::Canvas::SeamCarving::ProtectionConflict] when
      #   the requested dimensions cannot be reached without crossing
      #   protected pixels.
      def seam_carve(new_width, new_height, mask: nil)
        carved_mask = mask && ChunkyPNG::Canvas.from_canvas(mask)
        carved = dup.seam_carve!(new_width, new_height, mask: carved_mask)
        [carved, carved_mask]
      end

      # Shrinks the canvas in place to the given dimensions by removing
      # low-energy seams. When a protection mask is given, it is carved in
      # place as well: after every seam removal both the image and the
      # mask are updated, so they always stay in sync.
      #
      # @param (see #seam_carve)
      # @return [ChunkyPNG::Canvas] The receiver, carved to the new
      #   dimensions.
      # @raise (see #seam_carve)
      def seam_carve!(new_width, new_height, mask: nil)
        assert_carve_dimensions!(new_width, new_height, mask)

        carved_pixels, carved_mask_pixels = carve_pixels(
          pixels, width, height,
          mask && mask.pixels,
          width - new_width, height - new_height
        )

        replace_canvas!(new_width, new_height, carved_pixels)
        mask.send(:replace_canvas!, new_width, new_height, carved_mask_pixels) if mask
        self
      end

      private

      # @private
      def assert_carve_dimensions!(new_width, new_height, mask)
        if new_width > width || new_height > height
          raise ArgumentError,
            "Seam carving only supports shrinking: cannot carve #{width}x#{height} to #{new_width}x#{new_height}."
        end
        if new_width < 1 || new_height < 1
          raise ArgumentError,
            "Seam carving cannot carve #{width}x#{height} to #{new_width}x#{new_height}: dimensions must be at least 1."
        end
        if mask && (mask.width != width || mask.height != height)
          raise ArgumentError,
            "The protection mask dimensions (#{mask.width}x#{mask.height}) do not match the canvas dimensions (#{width}x#{height})!"
        end
        true
      end

      # Removes the given number of vertical and horizontal seams from the
      # pixel array. The mask pixel array is kept in sync: the same seams
      # are removed from it.
      #
      # @private
      # @return [Array(Array<Integer>, Array<Integer>)] The carved pixel
      #   array and the carved mask pixel array.
      def carve_pixels(pixels, width, height, mask_pixels, vertical_seams, horizontal_seams)
        pixels = pixels.dup
        mask_pixels = mask_pixels.dup if mask_pixels

        vertical_seams.times do |removed|
          seam = minimal_vertical_seam(pixels, width, height, mask_pixels)
          if seam.nil?
            raise ProtectionConflict,
              "Cannot reduce the width from #{width} to #{width - (vertical_seams - removed)}: " +              "every remaining vertical seam crosses protected pixels, so the protected region " +              "forms a barrier from the top to the bottom edge. Removed #{removed} seam(s) " +              "before getting stuck; protected pixels were not crossed to reach the requested size."
          end
          pixels = remove_vertical_seam(pixels, width, height, seam)
          mask_pixels = remove_vertical_seam(mask_pixels, width, height, seam) if mask_pixels
          width -= 1
        end

        horizontal_seams.times do |removed|
          # Work on the transposed image, so horizontal seams can be found
          # and removed with the vertical seam logic.
          pixels = transpose_pixels(pixels, width, height)
          mask_pixels = transpose_pixels(mask_pixels, width, height) if mask_pixels
          seam = minimal_vertical_seam(pixels, height, width, mask_pixels)
          if seam.nil?
            raise ProtectionConflict,
              "Cannot reduce the height from #{height} to #{height - (horizontal_seams - removed)}: " +              "every remaining horizontal seam crosses protected pixels, so the protected region " +              "forms a barrier from the left to the right edge. Removed #{removed} seam(s) " +              "before getting stuck; protected pixels were not crossed to reach the requested size."
          end
          pixels = transpose_pixels(remove_vertical_seam(pixels, height, width, seam), height - 1, width)
          if mask_pixels
            mask_pixels = transpose_pixels(remove_vertical_seam(mask_pixels, height, width, seam), height - 1, width)
          end
          height -= 1
        end

        [pixels, mask_pixels]
      end

      # Finds the lowest-cost vertical seam for the given pixel array, or
      # +nil+ when every seam crosses at least one protected pixel.
      #
      # @private
      # @return [Array<Integer>, nil] The column index of the seam pixel
      #   for every row, or nil when no feasible seam exists.
      def minimal_vertical_seam(pixels, width, height, mask_pixels)
        energy = seam_energy_map(pixels, width, height, mask_pixels)

        # prev_cost[x] holds the minimal cumulative energy of a seam
        # ending at (x, y - 1); back[y * width + x] holds the column of
        # the chosen predecessor on the previous row.
        prev_cost = energy[0, width].dup
        back = Array.new(width * (height - 1))

        for y in 1...height
          this_row = y * width
          curr_cost = Array.new(width)
          for x in 0...width
            best_x = x
            best = prev_cost[x]
            if x > 0 && prev_cost[x - 1] < best
              best = prev_cost[x - 1]
              best_x = x - 1
            end
            if x < width - 1 && prev_cost[x + 1] < best
              best = prev_cost[x + 1]
              best_x = x + 1
            end
            curr_cost[x] = best + energy[this_row + x]
            back[(y - 1) * width + x] = best_x
          end
          prev_cost = curr_cost
        end

        # The leftmost cell on the last row with minimal cumulative cost
        # is the end of the chosen seam.
        seam_x = 0
        for x in 1...width
          seam_x = x if prev_cost[x] < prev_cost[seam_x]
        end
        return nil if prev_cost[seam_x] >= PROTECTED_ENERGY

        seam = Array.new(height)
        seam[height - 1] = seam_x
        (height - 2).downto(0) do |y|
          seam_x = back[y * width + seam_x]
          seam[y] = seam_x
        end
        seam
      end

      # Builds the energy map for the given pixel array. Protected pixels
      # get PROTECTED_ENERGY; see the module documentation for the exact
      # energy definition.
      #
      # @private
      # @return [Array<Integer>] The energy of every pixel.
      def seam_energy_map(pixels, width, height, mask_pixels)
        energy = Array.new(width * height)
        for y in 0...height
          row = y * width
          up_row = (y > 0) ? (y - 1) * width : row
          down_row = (y < height - 1) ? (y + 1) * width : row
          for x in 0...width
            i = row + x
            if mask_pixels && (mask_pixels[i] & 0xff) > 0
              energy[i] = PROTECTED_ENERGY
            else
              left = pixels[row + ((x > 0) ? x - 1 : x)]
              right = pixels[row + ((x < width - 1) ? x + 1 : x)]
              up = pixels[up_row + x]
              down = pixels[down_row + x]
              energy[i] = channel_distance(left, right) + channel_distance(up, down)
            end
          end
        end
        energy
      end

      # The sum of the absolute differences of the red, green, blue and
      # alpha channels of two packed color values.
      #
      # @private
      def channel_distance(color_a, color_b)
        (((color_a >> 24) & 0xff) - ((color_b >> 24) & 0xff)).abs +
          (((color_a >> 16) & 0xff) - ((color_b >> 16) & 0xff)).abs +
          (((color_a >> 8) & 0xff) - ((color_b >> 8) & 0xff)).abs +
          ((color_a & 0xff) - (color_b & 0xff)).abs
      end

      # Removes one vertical seam from the pixel array.
      #
      # @private
      # @return [Array<Integer>] A new pixel array of
      #   <tt>(width - 1) * height</tt> pixels.
      def remove_vertical_seam(pixels, width, height, seam)
        carved = Array.new((width - 1) * height)
        for y in 0...height
          row = y * width
          carved_row = y * (width - 1)
          seam_x = seam[y]
          for x in 0...seam_x
            carved[carved_row + x] = pixels[row + x]
          end
          for x in (seam_x + 1)...width
            carved[carved_row + x - 1] = pixels[row + x]
          end
        end
        carved
      end

      # Transposes a pixel array of the given dimensions.
      #
      # @private
      # @return [Array<Integer>] A new pixel array of
      #   <tt>height * width</tt> pixels.
      def transpose_pixels(pixels, width, height)
        transposed = Array.new(width * height)
        for y in 0...height
          row = y * width
          for x in 0...width
            transposed[x * height + y] = pixels[row + x]
          end
        end
        transposed
      end
    end
  end
end
