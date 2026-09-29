# frozen-string-literal: true

module ChunkyPNG
  class Canvas
    # The ChunkyPNG::Canvas::DistanceTransform module computes the squared
    # Euclidean distance transform of a binary mask image: for every pixel,
    # the squared distance to the closest foreground pixel, together with the
    # coordinates of that foreground pixel.
    #
    # The result is returned as plain arrays of integers and points, so
    # distances are not squeezed into 8-bit color channels and can take any
    # non-negative integer value.
    #
    # The transform uses the separable two-pass algorithm by Felzenszwalb and
    # Huttenlocher, so the amount of work grows linearly with the number of
    # pixels instead of comparing every pixel with every foreground pixel.
    #
    # @see ChunkyPNG::Canvas
    module DistanceTransform
      # The outcome of a distance transform, see #distance_transform.
      class Result
        # @return [Integer] The width of the mask the transform was computed on.
        attr_reader :width

        # @return [Integer] The height of the mask the transform was computed on.
        attr_reader :height

        # @return [Array<Integer, nil>] The squared Euclidean distance to the
        #   nearest foreground pixel for every pixel, in row-major order.
        #   All elements are +nil+ when the mask contained no foreground
        #   pixels at all.
        attr_reader :distances

        # @return [Array<ChunkyPNG::Point, nil>] The coordinates of the
        #   nearest foreground pixel for every pixel, in row-major order.
        #   All elements are +nil+ when the mask contained no foreground
        #   pixels at all.
        attr_reader :nearest

        def initialize(width, height, distances, nearest)
          @width = width
          @height = height
          @distances = distances
          @nearest = nearest
        end

        # Returns the squared distance to the nearest foreground pixel.
        # @param [Integer] x The x-coordinate of the pixel.
        # @param [Integer] y The y-coordinate of the pixel.
        # @return [Integer, nil] The squared distance, or +nil+ when the mask
        #   contained no foreground pixels.
        def distance_at(x, y)
          distances[y * width + x]
        end

        # Returns the coordinates of the nearest foreground pixel.
        # @param [Integer] x The x-coordinate of the pixel.
        # @param [Integer] y The y-coordinate of the pixel.
        # @return [ChunkyPNG::Point, nil] The nearest foreground pixel, or
        #   +nil+ when the mask contained no foreground pixels.
        def nearest_at(x, y)
          nearest[y * width + x]
        end
      end

      # Computes the squared Euclidean distance transform of this canvas,
      # interpreted as a binary mask.
      #
      # Every pixel equal to +foreground_color+ is a foreground (seed) pixel.
      # For every pixel, the result holds the squared Euclidean distance to
      # the closest foreground pixel and the coordinates of that pixel.
      #
      # When two foreground pixels are equally close to a pixel, the one that
      # comes first in coordinate order is chosen: the topmost foreground
      # pixel wins, and ties on the same row are broken by the leftmost one
      # (i.e. ordered by y first, then by x).
      #
      # When the mask contains no foreground pixels at all, every distance
      # and every nearest coordinate in the result is +nil+.
      #
      # @param [Integer] foreground_color The color that marks foreground
      #   pixels in the mask.
      # @return [ChunkyPNG::Canvas::DistanceTransform::Result] The distances
      #   and nearest foreground coordinates for every pixel.
      def distance_transform(foreground_color = ChunkyPNG::Color::WHITE)
        w = width
        h = height
        # A sentinel larger than any real squared distance, which is at most
        # (w - 1)^2 + (h - 1)^2.
        infinite = w * w + h * h + 1

        foreground = pixels.map { |pixel| pixel == foreground_color }

        # Pass 1: per column, find the nearest foreground row for every
        # pixel. Values are scaled by h and offset by the row index, so that
        # ties between equally distant rows resolve to the topmost row.
        column_distance = Array.new(w) { Array.new(h) }
        column_row = Array.new(w) { Array.new(h) }
        w.times do |x|
          values = Array.new(h) { |y| foreground[y * w + x] ? y : infinite * h + y }
          transformed = squared_distance_transform_1d(values, h)
          h.times do |y|
            total = transformed[y]
            if total >= infinite * h
              column_distance[x][y] = infinite
            else
              column_distance[x][y] = total / h
              column_row[x][y] = total % h
            end
          end
        end

        # Pass 2: per row, combine the column results. Values are scaled by
        # h * w and offset by a rank that encodes the (y, x) coordinate
        # order, so that ties resolve to the topmost, then leftmost seed.
        rank_scale = h * w
        distances = Array.new(w * h)
        nearest = Array.new(w * h)
        h.times do |y|
          values = Array.new(w) do |x|
            if column_distance[x][y] >= infinite
              infinite * rank_scale
            else
              column_distance[x][y] * rank_scale + column_row[x][y] * w + x
            end
          end
          transformed = squared_distance_transform_1d(values, rank_scale)
          w.times do |x|
            total = transformed[x]
            index = y * w + x
            if total >= infinite * rank_scale
              distances[index] = nil
              nearest[index] = nil
            else
              rank = total % rank_scale
              distances[index] = total / rank_scale
              nearest[index] = ChunkyPNG::Point.new(rank % w, rank / w)
            end
          end
        end

        Result.new(w, h, distances, nearest)
      end

      private

      # Computes min_p (q - p)^2 * scale + values[p] for every q, in linear
      # time, using the lower-envelope algorithm of Felzenszwalb and
      # Huttenlocher. Intersections are computed with exact rational
      # arithmetic so the result is exact for integer inputs.
      #
      # @param [Array<Integer>] values The value for every position.
      # @param [Integer] scale The multiplier for the squared distance term.
      # @return [Array<Integer>] The transformed value for every position.
      def squared_distance_transform_1d(values, scale)
        n = values.length
        transformed = Array.new(n)
        envelope = Array.new(n)
        bounds = Array.new(n + 1)
        k = 0
        envelope[0] = 0
        bounds[0] = -Float::INFINITY
        bounds[1] = Float::INFINITY
        (1...n).each do |q|
          intersection = nil
          loop do
            p = envelope[k]
            intersection = Rational(
              (values[q] + scale * q * q) - (values[p] + scale * p * p),
              2 * scale * (q - p)
            )
            break if intersection > bounds[k]
            k -= 1
          end
          k += 1
          envelope[k] = q
          bounds[k] = intersection
          bounds[k + 1] = Float::INFINITY
        end
        k = 0
        (0...n).each do |q|
          k += 1 while bounds[k + 1] < q
          p = envelope[k]
          transformed[q] = scale * (q - p) * (q - p) + values[p]
        end
        transformed
      end
    end
  end
end
