# frozen-string-literal: true

module ChunkyPNG
  # The ChunkyPNG::DistanceTransform module computes Euclidean distance
  # transforms of binary masks, e.g. a thresholded alpha channel, for font
  # post-processing and similar use cases.
  #
  # All methods in this module share a single set of conventions, so every
  # entry point (this module, or {ChunkyPNG::Canvas::DistanceTransform})
  # produces identical results:
  #
  # * Masks are flat arrays of +width * height+ booleans in row-major order,
  #   the same ordering as {ChunkyPNG::Canvas#pixels}. +true+ marks a
  #   foreground ("inside") pixel, +false+ a background ("outside") pixel.
  # * Distances are measured between pixel centers: the centers of two
  #   horizontally or vertically adjacent pixels are exactly 1.0 apart.
  # * The mask is not padded. Pixels outside the image bounds are neither
  #   foreground nor background and are never used as distance sources;
  #   distances are only defined for pixels inside the image.
  # * If the mask has no foreground pixels at all, every signed distance is
  #   <tt>-Float::INFINITY</tt>. If the mask has no background pixels at all,
  #   every signed distance is <tt>+Float::INFINITY</tt>.
  #
  # The transform uses the separable algorithm by Felzenszwalb and
  # Huttenlocher, which runs in O(width * height) time: it never compares
  # every pixel against every edge pixel, so it is suitable for large images.
  module DistanceTransform
    # Squared distance used internally as "infinitely far away". It is a
    # finite value so the parabola intersection arithmetic below never has
    # to deal with NaN, and it is far larger than any squared distance that
    # can occur inside an image, so real distances never reach it.
    # @private
    INFINITE_SQUARED_DISTANCE = 1 << 62

    # Computes the signed Euclidean distance field of a binary mask.
    #
    # The sign convention is: foreground pixels get a positive distance,
    # background pixels a negative distance. The absolute value is the
    # Euclidean distance from the pixel's center to the center of the
    # nearest pixel of the opposite class, so a foreground pixel directly
    # adjacent to a background pixel has a value of +1.0.
    #
    # @param [Array] mask Flat array of +width * height+ booleans in
    #   row-major order; truthy values mark foreground pixels.
    # @param [Integer] width The width of the mask.
    # @param [Integer] height The height of the mask.
    # @return [Array<Float>] Flat array of +width * height+ signed
    #   distances in row-major order: positive inside the foreground,
    #   negative outside, +-Infinity for masks without an opposite class.
    # @raise [ArgumentError] when the mask size does not match the given
    #   dimensions.
    def self.signed_distance_field(mask, width, height)
      unless mask.length == width * height
        raise ArgumentError,
          "Mask contains #{mask.length} pixels, but the dimensions are #{width} x #{height}"
      end
      return [] if mask.empty?

      to_foreground = squared_euclidean_distance_transform(mask, width, height)
      to_background = squared_euclidean_distance_transform(mask.map { |pixel| !pixel }, width, height)

      mask.each_with_index.map do |foreground, i|
        if foreground
          squared = to_background[i]
          squared >= INFINITE_SQUARED_DISTANCE ? Float::INFINITY : Math.sqrt(squared)
        else
          squared = to_foreground[i]
          squared >= INFINITE_SQUARED_DISTANCE ? -Float::INFINITY : -Math.sqrt(squared)
        end
      end
    end

    # Computes the squared Euclidean distance from every pixel to the
    # nearest foreground (+true+) pixel of the mask.
    #
    # @param [Array] mask Flat array of +width * height+ booleans in
    #   row-major order.
    # @param [Integer] width The width of the mask.
    # @param [Integer] height The height of the mask.
    # @return [Array<Integer>] Flat array of squared distances. Pixels
    #   without any foreground pixel in the mask get a value of at least
    #   {INFINITE_SQUARED_DISTANCE}.
    def self.squared_euclidean_distance_transform(mask, width, height)
      distances = Array.new(width * height)

      width.times do |x|
        column = Array.new(height) { |y| mask[y * width + x] ? 0 : INFINITE_SQUARED_DISTANCE }
        transformed = euclidean_distance_transform_1d(column)
        height.times { |y| distances[y * width + x] = transformed[y] }
      end

      height.times do |y|
        distances[y * width, width] = euclidean_distance_transform_1d(distances[y * width, width])
      end

      distances
    end

    # One-dimensional squared Euclidean distance transform, using the
    # linear-time lower-envelope-of-parabolas algorithm by Felzenszwalb
    # and Huttenlocher.
    #
    # @param [Array<Integer>] values Per-position squared distances, where
    #   0 marks a source position.
    # @return [Array<Integer>] The squared distance of every position to
    #   the nearest source position.
    # @private
    def self.euclidean_distance_transform_1d(values)
      length = values.length
      result = Array.new(length)
      locations = Array.new(length)
      boundaries = Array.new(length + 1)

      k = 0
      locations[0] = 0
      boundaries[0] = -Float::INFINITY
      boundaries[1] = Float::INFINITY

      1.upto(length - 1) do |q|
        intersection = nil
        loop do
          p = locations[k]
          intersection = ((values[q] + q * q) - (values[p] + p * p)).to_f / (2 * (q - p))
          break if intersection > boundaries[k]
          k -= 1
        end
        k += 1
        locations[k] = q
        boundaries[k] = intersection
        boundaries[k + 1] = Float::INFINITY
      end

      k = 0
      0.upto(length - 1) do |q|
        k += 1 while boundaries[k + 1] < q
        p = locations[k]
        result[q] = (q - p) * (q - p) + values[p]
      end

      result
    end
    private_class_method :euclidean_distance_transform_1d
  end
end
