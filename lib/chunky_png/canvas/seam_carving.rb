# frozen-string-literal: true

module ChunkyPNG
  class Canvas
    # Raised when shrinking would require a seam to cross a protected pixel.
    class ProtectedAreaCrossing < ChunkyPNG::ExpectationFailed
    end

    # Content-aware image shrinking by repeatedly removing low-energy seams.
    #
    # The energy of a pixel is the sum of the absolute differences of all four
    # RGBA channels between its immediate left/right and above/below neighbors.
    # Neighbors outside the image boundary repeat the boundary pixel.
    # The energy map is calculated again after every seam removal.
    #
    # A vertical seam contains one pixel in every row, and consecutive pixels
    # are connected by the upper-left, directly above, or upper-right pixel. A
    # horizontal seam is defined analogously with upper-left, directly left, or
    # lower-left connections.
    #
    # Dynamic programming minimizes the sum of pixel energies along a seam.
    # When two parent paths have equal cost, the directly connected parent is
    # preferred. The remaining tie is resolved by first trying the parent with
    # the smaller cross-axis coordinate (upper-left for a vertical seam, and
    # upper for a horizontal seam). At the final edge, the smallest path cost is
    # selected; endpoint ties are resolved toward the image center, then toward
    # the smaller coordinate.
    #
    # A protection mask marks pixels that no seam may cross. A mask pixel is
    # protected when its alpha channel is greater than zero. When an unprotected
    # seam does not exist, the operation stops rather than crossing protected
    # pixels to satisfy the requested dimensions.
    module SeamCarving
      # Returns a content-aware shrunk copy of this canvas.
      # @param new_width [Integer] The desired width. Only shrinking is
      #   supported.
      # @param new_height [Integer] The desired height. Only shrinking is
      #   supported.
      # @param protection_mask [ChunkyPNG::Canvas, nil] A canvas of the same
      #   dimensions, where non-transparent pixels cannot be removed.
      # @return [ChunkyPNG::Canvas] The resized canvas.
      def resample_seam_carving(new_width, new_height, protection_mask = nil)
        working_mask = protection_mask && protection_mask.dup
        dup.resample_seam_carving!(new_width, new_height, working_mask)
      end

      alias seam_carve resample_seam_carving

      # Shrinks this canvas in place by repeatedly removing low-energy seams.
      # @param new_width [Integer] The desired width. Only shrinking is
      #   supported.
      # @param new_height [Integer] The desired height. Only shrinking is
      #   supported.
      # @param protection_mask [ChunkyPNG::Canvas, nil] A canvas of the same
      #   dimensions, where non-transparent pixels cannot be removed. It is
      #   resized together with the image.
      # @return [ChunkyPNG::Canvas] This canvas, resized in place.
      # @raise [ChunkyPNG::Canvas::ProtectedAreaCrossing] if the requested size
      #   cannot be reached without removing a protected pixel.
      def resample_seam_carving!(new_width, new_height, protection_mask = nil)
        new_width = new_width.to_i
        new_height = new_height.to_i

        assert_seam_carving_target!(new_width, new_height)
        assert_protection_mask!(protection_mask)

        remove_seams!(new_width, :vertical, protection_mask)
        remove_seams!(new_height, :horizontal, protection_mask)
        self
      end

      alias seam_carve! resample_seam_carving!

      private

      def assert_seam_carving_target!(new_width, new_height)
        if new_width <= 0 || new_height <= 0
          raise ArgumentError, "Seam carving dimensions must be positive!"
        elsif new_width > width || new_height > height
          raise ChunkyPNG::NotSupported, "Seam carving can only shrink images!"
        end
      end

      def assert_protection_mask!(protection_mask)
        return if protection_mask.nil?

        unless protection_mask.is_a?(ChunkyPNG::Canvas)
          raise ArgumentError, "The protection mask must be a ChunkyPNG::Canvas!"
        end

        unless protection_mask.width == width && protection_mask.height == height
          raise ChunkyPNG::ExpectationFailed, "The protection mask dimensions must match the image dimensions!"
        end
      end

      def remove_seams!(target_size, orientation, protection_mask)
        removed = 0
        removals = orientation == :vertical ? width - target_size : height - target_size

        while removed < removals
          seam = orientation == :vertical ? vertical_seam(protection_mask) : horizontal_seam(protection_mask)
          if seam.nil?
            axis = orientation == :vertical ? "width" : "height"
            direction = orientation == :vertical ? "top-to-bottom" : "left-to-right"
            raise ChunkyPNG::Canvas::ProtectedAreaCrossing,
              "No unprotected #{orientation} seam exists after removing #{removed} of #{removals} #{axis} pixels; " \
              "every 8-connected #{direction} path crosses a protected pixel."
          end

          if orientation == :vertical
            remove_vertical_seam!(seam, protection_mask)
          else
            remove_horizontal_seam!(seam, protection_mask)
          end
          removed += 1
        end
      end

      def vertical_seam(protection_mask)
        costs = Array.new(width)
        parents = Array.new(width * height)

        width.times do |x|
          costs[x] = protected_pixel?(protection_mask, x, 0) ? Float::INFINITY : seam_energy(x, 0)
        end

        previous_costs = costs.dup
        (1...height).each do |y|
          width.times do |x|
            if protected_pixel?(protection_mask, x, y)
              costs[x] = Float::INFINITY
              next
            end

            parent_x = vertical_parent_x(previous_costs, x)
            if parent_x.nil?
              costs[x] = Float::INFINITY
            else
              parents[y * width + x] = parent_x
              costs[x] = previous_costs[parent_x] + seam_energy(x, y)
            end
          end
          previous_costs.replace(costs)
        end

        endpoint_x = seam_endpoint(costs, width)
        return nil if endpoint_x.nil?

        seam = Array.new(height)
        seam[height - 1] = endpoint_x
        (height - 2).downto(0) do |y|
          seam[y] = parents[(y + 1) * width + seam[y + 1]]
        end
        seam
      end

      def vertical_parent_x(previous_costs, x)
        candidates = [x]
        candidates << x - 1 if x > 0
        candidates << x + 1 if x < width - 1
        candidates.select! { |candidate| previous_costs[candidate] != Float::INFINITY }
        return nil if candidates.empty?

        minimum_cost = candidates.map { |candidate| previous_costs[candidate] }.min
        candidates.find { |candidate| previous_costs[candidate] == minimum_cost }
      end

      def horizontal_seam(protection_mask)
        costs = Array.new(height)
        parents = Array.new(width * height)

        height.times do |y|
          costs[y] = protected_pixel?(protection_mask, 0, y) ? Float::INFINITY : seam_energy(0, y)
        end

        previous_costs = costs.dup
        (1...width).each do |x|
          height.times do |y|
            if protected_pixel?(protection_mask, x, y)
              costs[y] = Float::INFINITY
              next
            end

            parent_y = horizontal_parent_y(previous_costs, y)
            if parent_y.nil?
              costs[y] = Float::INFINITY
            else
              parents[y * width + x] = parent_y
              costs[y] = previous_costs[parent_y] + seam_energy(x, y)
            end
          end
          previous_costs.replace(costs)
        end

        endpoint_y = seam_endpoint(costs, height)
        return nil if endpoint_y.nil?

        seam = Array.new(width)
        seam[width - 1] = endpoint_y
        (width - 2).downto(0) do |x|
          seam[x] = parents[seam[x + 1] * width + (x + 1)]
        end
        seam
      end

      def horizontal_parent_y(previous_costs, y)
        candidates = [y]
        candidates << y - 1 if y > 0
        candidates << y + 1 if y < height - 1
        candidates.select! { |candidate| previous_costs[candidate] != Float::INFINITY }
        return nil if candidates.empty?

        minimum_cost = candidates.map { |candidate| previous_costs[candidate] }.min
        candidates.find { |candidate| previous_costs[candidate] == minimum_cost }
      end

      def seam_endpoint(costs, size)
        minimum_cost = costs.min
        return nil if minimum_cost == Float::INFINITY

        center = (size - 1) / 2.0
        (0...size).min_by do |index|
          cost = costs[index]
          cost == minimum_cost ? [0, (index - center).abs, index] : [1, 0, 0]
        end
      end

      def seam_energy(x, y)
        left = pixels[y * width + (x.zero? ? 0 : x - 1)]
        right = pixels[y * width + (x == width - 1 ? x : x + 1)]
        above = pixels[(y.zero? ? 0 : y - 1) * width + x]
        below = pixels[(y == height - 1 ? y : y + 1) * width + x]

        color_difference(left, right) + color_difference(above, below)
      end

      def color_difference(first, second)
        (ChunkyPNG::Color.r(first) - ChunkyPNG::Color.r(second)).abs +
          (ChunkyPNG::Color.g(first) - ChunkyPNG::Color.g(second)).abs +
          (ChunkyPNG::Color.b(first) - ChunkyPNG::Color.b(second)).abs +
          (ChunkyPNG::Color.a(first) - ChunkyPNG::Color.a(second)).abs
      end

      def protected_pixel?(protection_mask, x, y)
        protection_mask && ChunkyPNG::Color.a(protection_mask.pixels[y * protection_mask.width + x]) > 0
      end

      def remove_vertical_seam!(seam, protection_mask)
        new_width = width - 1
        new_pixels = Array.new(new_width * height)
        new_mask_pixels = protection_mask && Array.new(new_width * height)

        height.times do |y|
          removed_x = seam[y]
          source_start = y * width
          destination_start = y * new_width

          new_pixels[destination_start, removed_x] = pixels[source_start, removed_x]
          new_pixels[destination_start + removed_x, new_width - removed_x] =
            pixels[source_start + removed_x + 1, new_width - removed_x]

          next unless protection_mask
          new_mask_pixels[destination_start, removed_x] = protection_mask.pixels[source_start, removed_x]
          new_mask_pixels[destination_start + removed_x, new_width - removed_x] =
            protection_mask.pixels[source_start + removed_x + 1, new_width - removed_x]
        end

        replace_canvas!(new_width, height, new_pixels)
        protection_mask.replace_canvas!(new_width, height, new_mask_pixels) if protection_mask
      end

      def remove_horizontal_seam!(seam, protection_mask)
        new_height = height - 1
        new_pixels = Array.new(width * new_height)
        new_mask_pixels = protection_mask && Array.new(width * new_height)

        width.times do |x|
          removed_y = seam[x]
          destination_y = 0
          height.times do |source_y|
            next if source_y == removed_y

            source_index = source_y * width + x
            destination_index = destination_y * width + x
            new_pixels[destination_index] = pixels[source_index]
            if protection_mask
              new_mask_pixels[destination_index] = protection_mask.pixels[source_index]
            end
            destination_y += 1
          end
        end

        replace_canvas!(width, new_height, new_pixels)
        protection_mask.replace_canvas!(width, new_height, new_mask_pixels) if protection_mask
      end
    end
  end
end
