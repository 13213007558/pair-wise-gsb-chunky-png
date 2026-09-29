# frozen-string-literal: true

module ChunkyPNG
  class Canvas
    # The ChunkyPNG::Canvas::ProjectiveTransform module defines methods to
    # warp a {ChunkyPNG::Canvas} using a 3x3 homography (projective)
    # matrix, for example to rectify a photographed rectangle onto a target
    # canvas.
    #
    # The transformation is performed by inverse mapping: for every pixel of
    # the target canvas, the corresponding location in the source canvas is
    # looked up through the inverse of the provided matrix. Sampling is done
    # with premultiplied alpha, and the anti-aliasing footprint adapts to the
    # local Jacobian of the mapping, so minified and strongly sheared regions
    # are averaged over an area that matches their local sampling footprint.
    #
    # @see ChunkyPNG::Canvas
    module ProjectiveTransform
      # The maximum number of subsamples taken per axis for a single output
      # pixel. This bounds the work done for extreme minification, so a
      # pathological matrix can never cause runaway sampling loops.
      MAX_SUBSAMPLES = 8

      # Projective denominators smaller than this value are treated as zero,
      # i.e. the pixel maps to the horizon (infinity) of the source plane.
      MIN_DENOMINATOR = 1e-12

      # Source coordinates with a magnitude larger than this value are
      # treated as out of bounds, so degenerate matrices can never produce
      # randomly huge pixel offsets.
      MAX_SOURCE_COORDINATE = 1e9

      # Warps the canvas onto a new canvas of the given dimensions, using a
      # 3x3 homography matrix.
      #
      # The matrix maps source pixel coordinates to target pixel coordinates
      # in homogeneous form: [x', y', w] = M * [x, y, 1], with the final
      # target coordinate (x' / w, y' / w). Pixel centers are located at
      # half-integer coordinates, so the identity matrix maps the canvas
      # onto itself exactly. The matrix can be given as a flat array of 9
      # numbers in row-major order, or as an array of 3 rows of 3 numbers.
      #
      # @param [Array<Numeric>] matrix The 3x3 homography matrix mapping
      #   source coordinates to target coordinates.
      # @param [Integer] new_width The width of the warped canvas.
      # @param [Integer] new_height The height of the warped canvas.
      # @param [Integer, ...] background The color to use for target pixels
      #   that map outside of the source canvas. This can be a color value
      #   or any value that ChunkyPNG::Color.parse can handle.
      # @return [ChunkyPNG::Canvas] A new canvas instance with the warped
      #   pixels.
      # @raise [ArgumentError] when the matrix is not a 3x3 matrix, contains
      #   non-finite values, or is singular.
      def warp_homography(matrix, new_width, new_height, background: ChunkyPNG::Color::TRANSPARENT)
        dup.warp_homography!(matrix, new_width, new_height, background: background)
      end

      # Warps the canvas in place, replacing its content and dimensions.
      #
      # @param (see #warp_homography)
      # @return [ChunkyPNG::Canvas] This canvas, with its content replaced
      #   by the warped result.
      # @raise [ArgumentError] when the matrix is not a 3x3 matrix, contains
      #   non-finite values, or is singular.
      def warp_homography!(matrix, new_width, new_height, background: ChunkyPNG::Color::TRANSPARENT)
        inverse = invert_homography(normalize_homography(matrix))
        background_color = ChunkyPNG::Color.parse(background)

        new_width = new_width.to_i
        new_height = new_height.to_i
        if new_width <= 0 || new_height <= 0
          raise ArgumentError, "The target dimensions must be positive!"
        end

        a, b, c, d, e, f, g, h, i = inverse

        src_pixels = pixels
        src_width = width
        src_height = height

        bg_a = ChunkyPNG::Color.a(background_color)
        bg_r = ChunkyPNG::Color.r(background_color)
        bg_g = ChunkyPNG::Color.g(background_color)
        bg_b = ChunkyPNG::Color.b(background_color)

        new_pixels = Array.new(new_width * new_height)
        index = 0
        for dy in 0...new_height
          for dx in 0...new_width
            new_pixels[index] = warp_sample_pixel(
              dx, dy, a, b, c, d, e, f, g, h, i,
              src_pixels, src_width, src_height,
              bg_r, bg_g, bg_b, bg_a
            )
            index += 1
          end
        end

        replace_canvas!(new_width, new_height, new_pixels)
      end

      private

      # Normalizes a homography matrix given as a flat array of 9 elements
      # or as 3 rows of 3 elements into a flat array of 9 floats.
      #
      # @param [Array<Numeric>] matrix The matrix to normalize.
      # @return [Array<Float>] The 9 matrix elements in row-major order.
      # @raise [ArgumentError] when the matrix does not have 3x3 elements
      #   or contains non-finite values.
      def normalize_homography(matrix)
        unless matrix.is_a?(Array)
          raise ArgumentError, "The homography matrix must be an array!"
        end
        flat = (matrix.length == 3 && matrix.all? { |row| row.is_a?(Array) }) ? matrix.flatten : matrix.dup
        unless flat.length == 9 && flat.all? { |element| element.is_a?(Numeric) }
          raise ArgumentError, "The homography matrix must contain exactly 9 numeric elements (3x3)!"
        end
        flat = flat.map(&:to_f)
        unless flat.all?(&:finite?)
          raise ArgumentError, "The homography matrix must only contain finite values!"
        end
        flat
      end

      # Inverts a 3x3 homography matrix using the adjugate matrix.
      #
      # @param [Array<Float>] m The 9 matrix elements in row-major order.
      # @return [Array<Float>] The 9 elements of the inverted matrix.
      # @raise [ArgumentError] when the matrix is singular.
      def invert_homography(m)
        a, b, c, d, e, f, g, h, i = m
        cofactor_a = (e * i) - (f * h)
        cofactor_b = (f * g) - (d * i)
        cofactor_c = (d * h) - (e * g)
        determinant = (a * cofactor_a) + (b * cofactor_b) + (c * cofactor_c)

        if !determinant.finite? || determinant == 0.0
          raise ArgumentError, "The homography matrix is singular and cannot be inverted!"
        end

        inverse = [
          cofactor_a / determinant,
          ((c * h) - (b * i)) / determinant,
          ((b * f) - (c * e)) / determinant,
          cofactor_b / determinant,
          ((a * i) - (c * g)) / determinant,
          ((c * d) - (a * f)) / determinant,
          cofactor_c / determinant,
          ((b * g) - (a * h)) / determinant,
          ((a * e) - (b * d)) / determinant
        ]
        unless inverse.all?(&:finite?)
          raise ArgumentError, "The homography matrix is singular and cannot be inverted!"
        end
        inverse
      end

      # Computes the color of a single target pixel by inverse mapping it
      # onto the source canvas. The number of subsamples adapts to the
      # local Jacobian of the mapping, so minified or strongly sheared
      # regions are averaged over a footprint that matches the local
      # sampling density.
      #
      # @return [Integer] The color value for the target pixel.
      # @private
      def warp_sample_pixel(dx, dy, a, b, c, d, e, f, g, h, i, src_pixels, src_width, src_height, bg_r, bg_g, bg_b, bg_a)
        center_x = dx + 0.5
        center_y = dy + 0.5

        w = (g * center_x) + (h * center_y) + i
        return ChunkyPNG::Color.rgba(bg_r, bg_g, bg_b, bg_a) if !w.finite? || w.abs < MIN_DENOMINATOR

        sx = ((a * center_x) + (b * center_y) + c) / w
        sy = ((d * center_x) + (e * center_y) + f) / w
        unless mappable_source_coordinate?(sx) && mappable_source_coordinate?(sy)
          return ChunkyPNG::Color.rgba(bg_r, bg_g, bg_b, bg_a)
        end

        # Analytic Jacobian of the inverse mapping at the pixel center.
        # Each column describes how fast the source coordinate moves when
        # stepping one target pixel along x or y, i.e. the local footprint.
        dsx_dx = (a - (sx * g)) / w
        dsx_dy = (b - (sx * h)) / w
        dsy_dx = (d - (sy * g)) / w
        dsy_dy = (e - (sy * h)) / w

        step_x = Math.sqrt((dsx_dx * dsx_dx) + (dsy_dx * dsy_dx))
        step_y = Math.sqrt((dsx_dy * dsx_dy) + (dsy_dy * dsy_dy))

        samples_x = subsample_count(step_x)
        samples_y = subsample_count(step_y)

        if samples_x == 1 && samples_y == 1
          pr, pg, pb, pa = bilinear_premultiplied(sx, sy, src_pixels, src_width, src_height, bg_r, bg_g, bg_b, bg_a)
          return unpremultiplied_color(pr, pg, pb, pa, 1.0)
        end

        pr = pg = pb = pa = 0.0
        samples_taken = 0
        for sample_y in 0...samples_y
          py = dy + ((sample_y + 0.5) / samples_y)
          for sample_x in 0...samples_x
            px = dx + ((sample_x + 0.5) / samples_x)
            sample_w = (g * px) + (h * py) + i
            next if !sample_w.finite? || sample_w.abs < MIN_DENOMINATOR
            sample_sx = ((a * px) + (b * py) + c) / sample_w
            sample_sy = ((d * px) + (e * py) + f) / sample_w
            next unless mappable_source_coordinate?(sample_sx) && mappable_source_coordinate?(sample_sy)
            sr, sg, sb, sa = bilinear_premultiplied(sample_sx, sample_sy, src_pixels, src_width, src_height, bg_r, bg_g, bg_b, bg_a)
            pr += sr
            pg += sg
            pb += sb
            pa += sa
            samples_taken += 1
          end
        end

        return ChunkyPNG::Color.rgba(bg_r, bg_g, bg_b, bg_a) if samples_taken == 0

        unpremultiplied_color(pr, pg, pb, pa, samples_taken.to_f)
      end

      # Determines the number of subsamples along one axis, based on the
      # length of the source footprint per target pixel step. The count is
      # bounded so extreme minification cannot cause runaway loops.
      #
      # @private
      def subsample_count(step)
        return 1 unless step.finite? && step > 1.0
        [[(step * 2.0).ceil, 1].max, MAX_SUBSAMPLES].min
      end

      # Checks whether a source coordinate is finite and small enough to
      # be safely used as a pixel offset.
      #
      # @private
      def mappable_source_coordinate?(coordinate)
        coordinate.finite? && coordinate.abs <= MAX_SOURCE_COORDINATE
      end

      # Fetches a bilinearly interpolated sample from the source canvas at
      # a fractional position, using premultiplied alpha. Taps outside of
      # the source canvas contribute the background color.
      #
      # @return [Array(Float, Float, Float, Float)] The premultiplied red,
      #   green, blue and alpha sums of the four taps.
      # @private
      def bilinear_premultiplied(sx, sy, src_pixels, src_width, src_height, bg_r, bg_g, bg_b, bg_a)
        fx = sx - 0.5
        fy = sy - 0.5
        x0 = fx.floor
        y0 = fy.floor
        tx = fx - x0
        ty = fy - y0

        pr = pg = pb = pa = 0.0
        for tap_y in y0..(y0 + 1)
          weight_y = (tap_y == y0) ? (1.0 - ty) : ty
          next if weight_y == 0.0
          for tap_x in x0..(x0 + 1)
            weight = weight_y * ((tap_x == x0) ? (1.0 - tx) : tx)
            next if weight == 0.0
            if tap_x >= 0 && tap_x < src_width && tap_y >= 0 && tap_y < src_height
              pixel = src_pixels[(tap_y * src_width) + tap_x]
              alpha = ChunkyPNG::Color.a(pixel)
              pa += weight * alpha
              premul = alpha / 255.0
              pr += weight * ChunkyPNG::Color.r(pixel) * premul
              pg += weight * ChunkyPNG::Color.g(pixel) * premul
              pb += weight * ChunkyPNG::Color.b(pixel) * premul
            else
              pa += weight * bg_a
              premul = bg_a / 255.0
              pr += weight * bg_r * premul
              pg += weight * bg_g * premul
              pb += weight * bg_b * premul
            end
          end
        end
        [pr, pg, pb, pa]
      end

      # Converts accumulated premultiplied channel sums back into a
      # straight (non-premultiplied) color value.
      #
      # @private
      def unpremultiplied_color(pr, pg, pb, pa, total_weight)
        alpha = (pa / total_weight).round
        alpha = 0 if alpha < 0
        alpha = 255 if alpha > 255
        return ChunkyPNG::Color::TRANSPARENT if alpha == 0 || pa <= 0.0

        scale = 255.0 / pa
        r = (pr * scale).round
        g = (pg * scale).round
        b = (pb * scale).round
        r = 0 if r < 0
        r = 255 if r > 255
        g = 0 if g < 0
        g = 255 if g > 255
        b = 0 if b < 0
        b = 255 if b > 255
        ChunkyPNG::Color.rgba(r, g, b, alpha)
      end
    end
  end
end
