# frozen_string_literal: true

module ChunkyPNG
  # Computes signed Euclidean distance fields for binary raster masks.
  module DistanceField
    # Positive distance assigned to a foreground mask pixel.
    FOREGROUND = true

    # Negative distance assigned to a background mask pixel.
    BACKGROUND = false

    # Computes the signed Euclidean distance from every pixel center to
    # the nearest pixel center of the opposite mask value.
    #
    # Distances are measured on pixel centers, so horizontally or vertically
    # adjacent centers are one pixel apart and diagonally adjacent centers are
    # sqrt(2) pixels apart. No half-pixel boundary offset is applied.
    #
    # The image exterior is treated as an infinite background (false) region
    # on the same pixel-center grid. Only pixels from the supplied image are
    # returned, but foreground pixels at an image border can find a background
    # center one pixel beyond the border.
    #
    # @param [Array<true, false, Object>] mask A row-major binary mask. Every
    #   truthy value is foreground; +false+ and +nil+ are background.
    # @param [Integer] width Width of the mask in pixels.
    # @param [Integer] height Height of the mask in pixels.
    # @return [Array<Float>] The signed distance for every pixel, in row-major
    #   order. Foreground pixels return a positive distance to the nearest
    #   background pixel. Background pixels return a negative distance to the
    #   nearest foreground pixel. An all-background mask returns negative
    #   infinity. An all-foreground mask has finite distances because the image
    #   exterior is background.
    def self.signed_euclidean_distance(mask, width, height)
      assert_mask!(mask, width, height)

      size = width * height
      foreground = Array.new(size) { |index| !!mask[index] }
      padded = padded_mask(foreground, width, height)
      padded_width = width + 2
      padded_height = height + 2

      background_distance = euclidean_distance_squared(padded, padded_width, padded_height, BACKGROUND)
      foreground_distance = euclidean_distance_squared(padded, padded_width, padded_height, FOREGROUND)

      Array.new(size) do |index|
        x = index % width
        y = index.div(width)
        padded_index = (y + 1) * padded_width + x + 1

        squared_distance =
          if foreground[index]
            background_distance[padded_index]
          else
            -foreground_distance[padded_index]
          end

        if squared_distance.infinite?
          squared_distance.to_f
        elsif foreground[index]
          Math.sqrt(squared_distance)
        else
          -Math.sqrt(-squared_distance)
        end
      end
    end

    class << self
      alias signed_distance_transform signed_euclidean_distance
      alias signed_distance_array signed_euclidean_distance

      private

      def assert_mask!(mask, width, height)
        unless width.is_a?(::Integer) && height.is_a?(::Integer) && width > 0 && height > 0
          raise ArgumentError, "Width and height should be positive integers!"
        end

        expected_size = width * height
        return if mask.length == expected_size

        raise ArgumentError, "The mask should have #{width}x#{height} = #{expected_size} elements!"
      end

      def padded_mask(mask, width, height)
        padded_width = width + 2
        padded = Array.new(padded_width * (height + 2), BACKGROUND)

        height.times do |y|
          padded[(y + 1) * padded_width + 1, width] = mask[y * width, width]
        end

        padded
      end

      def euclidean_distance_squared(mask, width, height, target)
        intermediate = Array.new(width * height, ::Float::INFINITY)
        values = Array.new(width, 0.0)

        height.times do |y|
          values.map!.with_index do |_, x|
            mask[y * width + x] == target ? 0.0 : ::Float::INFINITY
          end

          distance_transform_1d(values).each_with_index do |value, x|
            intermediate[y * width + x] = value
          end
        end

        result = Array.new(width * height, ::Float::INFINITY)
        values = Array.new(height, 0.0)

        width.times do |x|
          height.times { |y| values[y] = intermediate[y * width + x] }
          distance_transform_1d(values).each_with_index do |value, y|
            result[y * width + x] = value
          end
        end

        result
      end

      # Squared one-dimensional Euclidean distance transform using the lower
      # envelope parabola algorithm. This is linear in the number of samples.
      def distance_transform_1d(values)
        sites = []
        boundaries = []

        values.each_with_index do |value, site|
          next if value.infinite?

          if sites.empty?
            sites << site
            boundaries << -::Float::INFINITY
            boundaries << ::Float::INFINITY
            next
          end

          intersection = intersection(site, sites.last, values)

          while intersection <= boundaries[-2]
            sites.pop
            boundaries.pop
            intersection = intersection(site, sites.last, values)
          end

          sites << site
          boundaries[-1] = intersection
          boundaries << ::Float::INFINITY
        end

        return Array.new(values.length, ::Float::INFINITY) if sites.empty?

        active_site = 0
        Array.new(values.length) do |position|
          while active_site + 1 < sites.length && boundaries[active_site + 1] < position
            active_site += 1
          end

          site = sites[active_site]
          values[site] + (position - site) ** 2
        end
      end

      def intersection(left_site, right_site, values)
        left_value = values[left_site] + left_site ** 2
        right_value = values[right_site] + right_site ** 2
        (left_value - right_value) / (2.0 * (left_site - right_site))
      end
    end
  end
end
