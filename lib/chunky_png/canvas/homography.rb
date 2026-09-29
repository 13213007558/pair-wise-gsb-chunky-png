# frozen-string-literal: true

module ChunkyPNG
  class Canvas
    # The ChunkyPNG::Canvas::Homography module defines a method to warp a
    # canvas using a 3x3 homography (projective) matrix, e.g. to rectify a
    # photographed rectangle onto a target canvas.
    #
    # The transformation uses backward mapping: for every pixel of the
    # destination canvas, the inverse matrix determines the position to
    # sample from the source canvas. Where the transformation minifies or
    # shears the image, the local sampling footprint is estimated from the
    # Jacobian of the inverse mapping, and a matching number of sub-samples
    # is averaged to anti-alias the result. All sampling is performed on
    # premultiplied alpha values, so semi-transparent pixels interpolate
    # correctly.
    #
    # @see ChunkyPNG::Canvas
    module Homography
      # The maximum number of sub-samples taken per axis for anti-aliasing.
      # This bounds the amount of work done for extremely minifying
      # transformations.
      MAX_SAMPLES_PER_AXIS = 8

      # The smallest absolute value of the homogeneous denominator that is
      # still considered safe to divide by. Pixels whose denominator is
      # smaller than this value lie (practically) on the horizon line of
      # the projective transformation and are mapped to the background.
      MIN_HOMOGENEOUS_DENOMINATOR = 1.0e-9

      # Mapped source coordinates with an absolute value larger than this
      # are considered to lie outside of the source canvas. This guards
      # against arbitrarily large coordinates caused by nearly-singular
      # projective denominators.
      MAX_SOURCE_COORDINATE = 1.0e6

      # Warps the canvas using a 3x3 homography matrix onto a new canvas
      # with the given dimensions.
      #
      # The matrix maps source coordinates to destination coordinates and
      # can be given as a flat array of 9 numbers (row by row) or as an
      # array of 3 rows of 3 numbers. Coordinates are continuous: pixel
      # (x, y) covers the square [x, x + 1] x [y, y + 1], so its center is
      # at (x + 0.5, y + 0.5). Matrices that only differ by a scalar factor
      # describe the same transformation.
      #
      # @param [Array<Numeric>] matrix The 3x3 homography matrix, mapping
      #   source coordinates to destination coordinates.
      # @param [Integer] width The width of the new canvas.
      # @param [Integer] height The height of the new canvas.
      # @param [Integer] background The color used for destination pixels
      #   that map (partially) outside of the source canvas.
      # @return [ChunkyPNG::Canvas] A new canvas with the warped image.
      # @raise [ArgumentError] if the matrix is not a 3x3 matrix of finite
      #   numbers, or if the matrix is singular.
      def homography_transform(matrix, width, height, background = ChunkyPNG::Color::TRANSPARENT)
        inverse = invert_homography(coerce_homography_matrix(matrix))

        pixels = Array.new(width * height)
        height.times do |y|
          width.times do |x|
            pixels[(y * width) + x] = homography_sample(inverse, x + 0.5, y + 0.5, background)
          end
        end
        self.class.new(width, height, pixels)
      end

      private

      # Validates the given matrix and returns it as a flat array of 9
      # floats, normalized so the largest absolute element equals 1.
      #
      # @raise [ArgumentError] if the matrix is malformed or all-zero.
      def coerce_homography_matrix(matrix)
        values = matrix.to_a.flatten if matrix.respond_to?(:to_a)
        unless values && values.length == 9 && values.all? { |v| v.is_a?(Numeric) && v.to_f.finite? }
          raise ArgumentError, "Expected a 3x3 matrix of finite numbers"
        end

        values = values.map(&:to_f)
        scale = values.map(&:abs).max
        raise ArgumentError, "Cannot transform with an all-zero matrix" if scale == 0.0
        values.map { |v| v / scale }
      end

      # Inverts a normalized 3x3 matrix, given as a flat array of 9 floats.
      #
      # @raise [ArgumentError] if the matrix is singular.
      def invert_homography(m)
        m0, m1, m2, m3, m4, m5, m6, m7, m8 = m
        det = (m0 * ((m4 * m8) - (m5 * m7))) -
              (m1 * ((m3 * m8) - (m5 * m6))) +
              (m2 * ((m3 * m7) - (m4 * m6)))
        raise ArgumentError, "Cannot transform with a singular matrix" if det.zero?

        [
          ((m4 * m8) - (m5 * m7)) / det, ((m2 * m7) - (m1 * m8)) / det, ((m1 * m5) - (m2 * m4)) / det,
          ((m5 * m6) - (m3 * m8)) / det, ((m0 * m8) - (m2 * m6)) / det, ((m2 * m3) - (m0 * m5)) / det,
          ((m3 * m7) - (m4 * m6)) / det, ((m1 * m6) - (m0 * m7)) / det, ((m0 * m4) - (m1 * m3)) / det
        ]
      end

      # Samples the source canvas at the position that the inverse matrix
      # maps the destination pixel center (cx, cy) to, anti-aliased over
      # the local sampling footprint, and composited over the background.
      def homography_sample(inverse, cx, cy, background)
        i0, i1, i2, i3, i4, i5, i6, i7, i8 = inverse

        n0 = (i0 * cx) + (i1 * cy) + i2
        n1 = (i3 * cx) + (i4 * cy) + i5
        w = (i6 * cx) + (i7 * cy) + i8
        return background if w.abs < MIN_HOMOGENEOUS_DENOMINATOR

        sx = n0 / w
        sy = n1 / w
        return background unless sx.finite? && sy.finite?
        return background if sx.abs > MAX_SOURCE_COORDINATE || sy.abs > MAX_SOURCE_COORDINATE

        w_squared = w * w
        j00 = ((i0 * w) - (n0 * i6)) / w_squared
        j01 = ((i1 * w) - (n0 * i7)) / w_squared
        j10 = ((i3 * w) - (n1 * i6)) / w_squared
        j11 = ((i4 * w) - (n1 * i7)) / w_squared

        reach_x = 0.5 * (j00.abs + j01.abs)
        reach_y = 0.5 * (j10.abs + j11.abs)
        return background if (sx + reach_x < 0) || (sx - reach_x > width) ||
                             (sy + reach_y < 0) || (sy - reach_y > height)

        count_x = [[Math.sqrt((j00 * j00) + (j10 * j10)).ceil, 1].max, MAX_SAMPLES_PER_AXIS].min
        count_y = [[Math.sqrt((j01 * j01) + (j11 * j11)).ceil, 1].max, MAX_SAMPLES_PER_AXIS].min

        r = g = b = a = 0.0
        count_y.times do |iy|
          oy = ((iy + 0.5) / count_y) - 0.5
          count_x.times do |ix|
            ox = ((ix + 0.5) / count_x) - 0.5
            sr, sg, sb, sa = bilinear_sample_premultiplied(
              sx + (j00 * ox) + (j01 * oy),
              sy + (j10 * ox) + (j11 * oy)
            )
            r += sr
            g += sg
            b += sb
            a += sa
          end
        end

        total = (count_x * count_y).to_f
        compose_over_background(r / total, g / total, b / total, a / total, background)
      end

      # Bilinearly samples the canvas at source position (sx, sy), where
      # pixel (x, y) has its center at (x + 0.5, y + 0.5). Returns the
      # color as premultiplied channel values in the 0-255 range. Pixels
      # outside of the canvas are treated as fully transparent.
      def bilinear_sample_premultiplied(sx, sy)
        fx = sx - 0.5
        fy = sy - 0.5
        x0 = fx.floor
        y0 = fy.floor
        tx = fx - x0
        ty = fy - y0

        r = g = b = a = 0.0
        [[x0, y0, (1.0 - tx) * (1.0 - ty)], [x0 + 1, y0, tx * (1.0 - ty)],
         [x0, y0 + 1, (1.0 - tx) * ty], [x0 + 1, y0 + 1, tx * ty]].each do |px, py, weight|
          next if weight <= 0.0 || px < 0 || py < 0 || px >= width || py >= height
          color = self[px, py]
          alpha = color & 0xff
          premultiplied = weight * alpha / 255.0
          r += ((color >> 24) & 0xff) * premultiplied
          g += ((color >> 16) & 0xff) * premultiplied
          b += ((color >> 8) & 0xff) * premultiplied
          a += alpha * weight
        end
        [r, g, b, a]
      end

      # Converts a premultiplied, averaged sample back to a straight-alpha
      # color, composited over the background color.
      def compose_over_background(r, g, b, a, background)
        background_alpha = background & 0xff
        coverage = 1.0 - (a / 255.0)
        out_a = a + (background_alpha * coverage)
        return ChunkyPNG::Color::TRANSPARENT if out_a <= 0.0

        background_factor = background_alpha / 255.0 * coverage
        out_r = r + (((background >> 24) & 0xff) * background_factor)
        out_g = g + (((background >> 16) & 0xff) * background_factor)
        out_b = b + (((background >> 8) & 0xff) * background_factor)

        unpremultiply = 255.0 / out_a
        ChunkyPNG::Color.rgba(
          clamp_homography_channel(out_r * unpremultiply),
          clamp_homography_channel(out_g * unpremultiply),
          clamp_homography_channel(out_b * unpremultiply),
          clamp_homography_channel(out_a)
        )
      end

      # Rounds a channel value and clamps it to the 0-255 range.
      def clamp_homography_channel(value)
        [[value.round, 0].max, 255].min
      end
    end
  end
end
