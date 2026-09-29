# frozen_string_literal: true

require "chunky_png/color"
require "chunky_png/canvas"

module ChunkyPNG
  # Methods for analyzing image content without encoding results in color
  # channels.
  module ImageAnalysis
    extend self

    # Result of a squared Euclidean foreground distance transform.
    #
    # Arrays are in the same row-major order as ChunkyPNG::Canvas#pixels.
    # Ties are resolved by lexicographic [x, y] order: smaller x wins first,
    # then smaller y. When the mask has no foreground pixels, every distance
    # and coordinate is nil and {#empty_foreground?} returns true.
    class SquaredEuclideanDistanceTransform
      # @return [Integer] Number of columns in the source mask.
      attr_reader :width

      # @return [Integer] Number of rows in the source mask.
      attr_reader :height

      # @return [Array<Integer, nil>] Squared Euclidean distance to the
      #   nearest foreground pixel, or nil for an empty foreground.
      attr_reader :squared_distances

      # @return [Array<Array(Integer, Integer), nil>] Coordinates of the
      #   nearest foreground pixel as [x, y], or nil for an empty foreground.
      attr_reader :nearest_foreground_coordinates

      alias coordinates nearest_foreground_coordinates

      # Calculates the transform for a canvas-like binary mask.
      #
      # @param [#width, #height, #pixels] canvas The mask to analyze. Pixels
      #   matching foreground_color are treated as foreground.
      # @param [Integer] foreground_color The exact pixel color that marks the
      #   foreground. White is used by default.
      # @return [SquaredEuclideanDistanceTransform]
      def self.from_canvas(canvas, foreground_color = ChunkyPNG::Color::WHITE)
        unless canvas.respond_to?(:width) && canvas.respond_to?(:height) &&
            canvas.respond_to?(:pixels)
          raise ArgumentError, "Expected a ChunkyPNG::Canvas-like mask!"
        end

        allocate.tap do |transform|
          transform.send(:calculate!, canvas,
            ChunkyPNG::Color.parse(foreground_color))
        end
      end

      # @return [Boolean] Whether the source mask contained no foreground.
      def empty_foreground?
        @empty_foreground
      end

      alias empty? empty_foreground?

      # Returns the squared distance at one pixel.
      #
      # @param [Integer] x The x-coordinate of the pixel.
      # @param [Integer] y The y-coordinate of the pixel.
      # @return [Integer, nil] The squared Euclidean distance.
      def distance_at(x, y)
        assert_position!(x, y)
        squared_distances[y * width + x]
      end

      # Returns the nearest foreground coordinate at one pixel.
      #
      # @param [Integer] x The x-coordinate of the pixel.
      # @param [Integer] y The y-coordinate of the pixel.
      # @return [Array(Integer, Integer), nil] The foreground coordinate.
      def coordinates_at(x, y)
        assert_position!(x, y)
        nearest_foreground_coordinates[y * width + x]
      end

      # Returns the distance and nearest foreground coordinate at one pixel.
      #
      # @param [Integer] x The x-coordinate of the pixel.
      # @param [Integer] y The y-coordinate of the pixel.
      # @return [Array(Integer, Array(Integer, Integer)), nil]
      def [](x, y)
        [distance_at(x, y), coordinates_at(x, y)]
      end

      private

      def calculate!(canvas, foreground_color)
        @width = canvas.width
        @height = canvas.height
        pixel_count = width * height
        @empty_foreground = true

        horizontal_distances = Array.new(pixel_count)
        horizontal_sources = Array.new(pixel_count)

        calculate_horizontal_pass!(canvas, foreground_color, pixel_count,
          horizontal_distances, horizontal_sources)

        @squared_distances = Array.new(pixel_count)
        @nearest_foreground_coordinates = Array.new(pixel_count)

        unless empty_foreground?
          calculate_vertical_pass!(pixel_count, horizontal_distances,
            horizontal_sources)
        end
      end

      def calculate_horizontal_pass!(canvas, foreground_color, pixel_count,
          horizontal_distances, horizontal_sources)
        height.times do |y|
          row_offset = y * width
          nearest_x = nil

          width.times do |x|
            index = row_offset + x
            if canvas.pixels[index] == foreground_color
              nearest_x = x
              @empty_foreground = false
              horizontal_distances[index] = x * height + y
              horizontal_sources[index] = x
            elsif nearest_x
              set_horizontal_candidate!(index, x, nearest_x, y, pixel_count,
                horizontal_distances, horizontal_sources)
            end
          end

          nearest_x = nil
          (width - 1).downto(0) do |x|
            index = row_offset + x
            if canvas.pixels[index] == foreground_color
              nearest_x = x
            elsif nearest_x
              set_horizontal_candidate!(index, x, nearest_x, y, pixel_count,
                horizontal_distances, horizontal_sources)
            end
          end
        end
      end

      def set_horizontal_candidate!(index, x, source_x, y, pixel_count,
          horizontal_distances, horizontal_sources)
        candidate = (source_x - x) ** 2 * pixel_count +
          source_x * height + y
        existing = horizontal_distances[index]
        return unless existing.nil? || candidate < existing

        horizontal_distances[index] = candidate
        horizontal_sources[index] = source_x
      end

      def calculate_vertical_pass!(pixel_count, horizontal_distances,
          horizontal_sources)
        width.times do |x|
          segments = []

          height.times do |y|
            index = y * width + x
            next if horizontal_distances[index].nil?

            add_vertical_site!(segments, y, horizontal_distances[index],
              horizontal_sources[index], pixel_count)
          end

          evaluate_vertical_segments!(x, segments, pixel_count)
        end
      end

      def add_vertical_site!(segments, y, base_distance, source_x, pixel_count)
        if segments.empty?
          segments << [y, 0, base_distance, source_x]
          return
        end

        start = 0
        until segments.empty?
          previous_y, previous_start, previous_distance, = segments.last
          start = crossover_start(y, base_distance, previous_y,
            previous_distance, pixel_count)
          break if start > previous_start

          segments.pop
        end

        start = 0 if segments.empty?
        segments << [y, start, base_distance, source_x]
      end

      def crossover_start(new_y, new_distance, previous_y, previous_distance,
          pixel_count)
        numerator = new_distance - previous_distance +
          pixel_count * (new_y ** 2 - previous_y ** 2)
        denominator = 2 * pixel_count * (new_y - previous_y)
        numerator.div(denominator) + 1
      end

      def evaluate_vertical_segments!(x, segments, pixel_count)
        segment_index = 0

        height.times do |y|
          while segment_index + 1 < segments.length &&
              y >= segments[segment_index + 1][1]
            segment_index += 1
          end

          source_y, _start, base_distance, source_x = segments[segment_index]
          index = y * width + x
          score = base_distance + (y - source_y) ** 2 * pixel_count
          squared_distances[index] = score / pixel_count
          nearest_foreground_coordinates[index] = [source_x, source_y]
        end
      end

      def assert_position!(x, y)
        return if x >= 0 && x < width && y >= 0 && y < height

        raise ChunkyPNG::OutOfBounds, "Coordinates are out of bounds!"
      end
    end

    # Calculates squared Euclidean distances to the nearest foreground pixel.
    #
    # @param (see SquaredEuclideanDistanceTransform.from_canvas)
    # @return [SquaredEuclideanDistanceTransform]
    def squared_euclidean_distance_transform(canvas,
        foreground_color = ChunkyPNG::Color::WHITE)
      SquaredEuclideanDistanceTransform.from_canvas(canvas, foreground_color)
    end
  end

  class Canvas
    # Calculates squared Euclidean distances to the nearest foreground pixel.
    #
    # Distances are returned as integers in an analysis result object rather
    # than being encoded into 8-bit color channels.
    #
    # @param [Integer] foreground_color The exact pixel color that marks the
    #   foreground. White is used by default.
    # @return [ChunkyPNG::ImageAnalysis::SquaredEuclideanDistanceTransform]
    def squared_euclidean_distance_transform(
        foreground_color = ChunkyPNG::Color::WHITE)
      ChunkyPNG::ImageAnalysis.squared_euclidean_distance_transform(
        self, foreground_color
      )
    end

  end
end
