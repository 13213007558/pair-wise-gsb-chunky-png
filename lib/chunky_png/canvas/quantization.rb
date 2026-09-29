# frozen-string-literal: true

module ChunkyPNG
  class Canvas
    # The ChunkyPNG::Canvas::Quantization module defines methods to reduce
    # the number of colors used on a canvas, so that the canvas can be
    # encoded as an indexed PNG image with at most a given number of colors.
    #
    # Two approaches are supported:
    #
    # * Generating an optimal palette for the image using median cut
    #   quantization (see {#quantize} and {#quantize!}). Colors that must be
    #   part of the resulting palette can be locked by the caller.
    # * Mapping the image onto a palette provided by the caller (see
    #   {#quantize_to_palette} and {#quantize_to_palette!}).
    #
    # Dithering is controlled independently from the palette being used: both
    # approaches can optionally apply Floyd-Steinberg dithering to spread the
    # quantization error over neighboring pixels.
    #
    # Color distances are calculated in RGBA space, so the alpha channel
    # participates in finding the closest palette color. Fully transparent
    # pixels are mapped to the palette color closest to full transparency,
    # but they never diffuse quantization error to their neighbors: the color
    # channels of a fully transparent pixel are invisible, so spreading their
    # error would introduce meaningless color noise in (partially) opaque
    # regions.
    #
    # All methods in this module are deterministic: colors are always
    # processed in sorted order, and ties between equally distant palette
    # colors are broken by palette position, never by Hash iteration order.
    # Repeated runs on the same canvas always yield identical results.
    module Quantization
      # The Floyd-Steinberg error diffusion kernel, as [dx, dy, numerator]
      # tuples. The denominator for all weights is 16.
      # @private
      DITHERING_KERNEL = [[1, 0, 7], [-1, 1, 3], [0, 1, 5], [1, 1, 1]].freeze

      # The bit shifts used to extract the r, g, b and a channels from a
      # color value, in tie-breaking order.
      # @private
      CHANNEL_SHIFTS = [24, 16, 8, 0].freeze

      # Quantizes the canvas to at most +num_colors+ colors, returning a new
      # canvas. The current canvas is left unchanged.
      #
      # The resulting canvas uses at most +num_colors+ colors, so it can be
      # saved as an indexed PNG image. Because the number of colors is
      # limited, the encoder will automatically pick the indexed color mode
      # for non-grayscale results; pass <tt>color_mode: ChunkyPNG::COLOR_INDEXED</tt>
      # to {ChunkyPNG::Canvas::PNGEncoding#to_datastream} to force indexed
      # encoding.
      #
      # @param num_colors [Integer] The maximum number of colors in the
      #   generated palette, between 1 and 256.
      # @param dithering [true, false] Whether to apply Floyd-Steinberg
      #   dithering while mapping pixels to the palette.
      # @param locked [Array<Integer>] Colors that must be included in the
      #   generated palette as-is. The remaining palette entries are filled
      #   by median cut quantization of the other colors in the image.
      # @return [ChunkyPNG::Canvas] A new, quantized canvas.
      # @raise [ArgumentError] If +num_colors+ is out of range.
      # @raise [ChunkyPNG::ExpectationFailed] If more colors are locked than
      #   +num_colors+ allows.
      # @see #quantize!
      def quantize(num_colors = 256, dithering: true, locked: [])
        dup.quantize!(num_colors, dithering: dithering, locked: locked)
      end

      # Quantizes the canvas to at most +num_colors+ colors, modifying the
      # current canvas.
      #
      # @param (see #quantize)
      # @return [ChunkyPNG::Canvas] Returns itself, quantized.
      # @raise (see #quantize)
      # @see #quantize
      def quantize!(num_colors = 256, dithering: true, locked: [])
        palette = build_quantization_palette(num_colors, locked)
        remap_to_palette!(palette, dithering)
      end

      # Quantizes the canvas using a palette provided by the caller,
      # returning a new canvas. The current canvas is left unchanged.
      #
      # Every pixel is replaced by the color from the given palette that is
      # closest to it in RGBA space. The resulting canvas can be saved as an
      # indexed PNG image.
      #
      # @param colors [Enumerable<Integer>] The palette to map the canvas
      #   onto. Accepts color values or any values that
      #   {ChunkyPNG::Color.parse} can handle, e.g. a {ChunkyPNG::Palette}.
      # @param dithering [true, false] Whether to apply Floyd-Steinberg
      #   dithering while mapping pixels to the palette.
      # @return [ChunkyPNG::Canvas] A new, quantized canvas.
      # @raise [ArgumentError] If the palette is empty or has more than 256
      #   colors.
      # @see #quantize_to_palette!
      def quantize_to_palette(colors, dithering: true)
        dup.quantize_to_palette!(colors, dithering: dithering)
      end

      # Quantizes the canvas using a palette provided by the caller,
      # modifying the current canvas.
      #
      # @param (see #quantize_to_palette)
      # @return [ChunkyPNG::Canvas] Returns itself, quantized.
      # @raise (see #quantize_to_palette)
      # @see #quantize_to_palette
      def quantize_to_palette!(colors, dithering: true)
        palette = colors.map { |color| ChunkyPNG::Color.parse(color) }.uniq
        if palette.empty?
          raise ArgumentError, "Cannot quantize to an empty palette"
        end
        if palette.size > 256
          raise ArgumentError, "An indexed PNG palette supports at most 256 colors"
        end
        remap_to_palette!(palette, dithering)
      end

      private

      # Builds a palette of at most +num_colors+ colors for this canvas,
      # honoring the colors locked by the caller.
      # @return [Array<Integer>] The generated palette.
      def build_quantization_palette(num_colors, locked)
        unless num_colors.is_a?(Integer) && num_colors >= 1 && num_colors <= 256
          raise ArgumentError, "The number of colors should be an integer between 1 and 256"
        end

        locked = locked.map { |color| ChunkyPNG::Color.parse(color) }.uniq
        if locked.length > num_colors
          raise ChunkyPNG::ExpectationFailed,
            "Cannot lock #{locked.length} colors in a palette of at most #{num_colors} colors"
        end

        histogram = quantization_histogram
        locked.each { |color| histogram.delete(color) }
        locked + median_cut_palette(histogram, num_colors - locked.length)
      end

      # Counts how often every color occurs on this canvas. Fully
      # transparent pixels are normalized to {ChunkyPNG::Color::TRANSPARENT},
      # because their color channels are invisible and should not claim
      # palette entries.
      # @return [Hash] A hash mapping colors to their occurrence count.
      def quantization_histogram
        histogram = Hash.new(0)
        pixels.each do |pixel|
          pixel = ChunkyPNG::Color::TRANSPARENT if ChunkyPNG::Color.a(pixel) == 0
          histogram[pixel] += 1
        end
        histogram
      end

      # Builds a palette of at most +box_count+ colors from a color
      # histogram, using median cut quantization.
      # @param histogram [Hash] A hash mapping colors to occurrence counts.
      # @param box_count [Integer] The maximum number of colors to generate.
      # @return [Array<Integer>] The generated colors, sorted by color value.
      def median_cut_palette(histogram, box_count)
        return [] if box_count <= 0 || histogram.empty?

        # Sort the colors explicitly, so that the result never depends on
        # the iteration order of the histogram hash.
        boxes = [histogram.keys.sort.map { |color| [color, histogram[color]] }]

        while boxes.length < box_count
          split_index = splittable_box_index(boxes)
          break if split_index.nil?
          boxes[split_index..split_index] = split_color_box(boxes[split_index])
        end

        boxes.map { |box| average_box_color(box) }.sort
      end

      # Returns the index of the box with the most pixels that can still be
      # split, or nil if no box can be split further. Ties are broken by
      # position, so the result is deterministic.
      def splittable_box_index(boxes)
        best_index = nil
        best_population = 0
        boxes.each_with_index do |box, index|
          next if box.length < 2
          population = box.sum { |_, count| count }
          if population > best_population
            best_population = population
            best_index = index
          end
        end
        best_index
      end

      # Splits a box of [color, count] entries in two at the weighted median
      # along the channel with the widest range.
      # @return [Array] An array with exactly two non-empty boxes.
      def split_color_box(box)
        shift = widest_channel_shift(box)
        sorted = box.sort_by { |color, _| [(color >> shift) & 0xff, color] }
        total = sorted.sum { |_, count| count }

        cumulative = 0
        split_at = sorted.length - 2
        sorted.each_with_index do |(_, count), index|
          cumulative += count
          if cumulative * 2 >= total
            split_at = index
            break
          end
        end
        split_at = 0 if split_at < 0
        split_at = sorted.length - 2 if split_at > sorted.length - 2

        [sorted[0..split_at], sorted[(split_at + 1)..-1]]
      end

      # Returns the shift of the channel with the widest range within the
      # box. Ties are broken by channel order (r, g, b, a), so the result is
      # deterministic.
      def widest_channel_shift(box)
        best_shift = CHANNEL_SHIFTS[0]
        best_range = -1
        CHANNEL_SHIFTS.each do |shift|
          range = channel_range(box, shift)
          if range > best_range
            best_range = range
            best_shift = shift
          end
        end
        best_shift
      end

      # Returns the range of a single channel within a box of colors.
      def channel_range(box, shift)
        min = 255
        max = 0
        box.each do |color, _|
          value = (color >> shift) & 0xff
          min = value if value < min
          max = value if value > max
        end
        max - min
      end

      # Returns the weighted average color of a box of [color, count]
      # entries.
      def average_box_color(box)
        total = box.sum { |_, count| count }
        r = g = b = a = 0
        box.each do |color, count|
          r += ChunkyPNG::Color.r(color) * count
          g += ChunkyPNG::Color.g(color) * count
          b += ChunkyPNG::Color.b(color) * count
          a += ChunkyPNG::Color.a(color) * count
        end
        ChunkyPNG::Color.rgba(
          (r.to_f / total).round,
          (g.to_f / total).round,
          (b.to_f / total).round,
          (a.to_f / total).round
        )
      end

      # Replaces all pixels on this canvas by the closest color from the
      # given palette, optionally applying dithering.
      # @return [ChunkyPNG::Canvas] Returns itself.
      def remap_to_palette!(palette, dithering)
        dithering ? remap_with_dithering!(palette) : remap_without_dithering!(palette)
        self
      end

      # Replaces all pixels by their closest palette color, without
      # dithering.
      def remap_without_dithering!(palette)
        pixels.map! do |pixel|
          pixel = ChunkyPNG::Color::TRANSPARENT if ChunkyPNG::Color.a(pixel) == 0
          closest_palette_color(pixel, palette)
        end
      end

      # Replaces all pixels by their closest palette color, spreading the
      # quantization error over the neighboring pixels using Floyd-Steinberg
      # dithering. Fully transparent pixels are mapped to the palette color
      # closest to full transparency and do not diffuse error.
      def remap_with_dithering!(palette)
        source = pixels
        work = source.map do |pixel|
          [ChunkyPNG::Color.r(pixel), ChunkyPNG::Color.g(pixel),
            ChunkyPNG::Color.b(pixel), ChunkyPNG::Color.a(pixel)]
        end
        quantized = Array.new(source.length)

        0.upto(height - 1) do |y|
          0.upto(width - 1) do |x|
            index = y * width + x

            if ChunkyPNG::Color.a(source[index]) == 0
              quantized[index] = closest_palette_color(ChunkyPNG::Color::TRANSPARENT, palette)
              next
            end

            r, g, b, a = work[index]
            old_color = ChunkyPNG::Color.rgba(
              clamp_channel(r), clamp_channel(g), clamp_channel(b), clamp_channel(a)
            )
            new_color = closest_palette_color(old_color, palette)
            quantized[index] = new_color

            error = [
              r - ChunkyPNG::Color.r(new_color),
              g - ChunkyPNG::Color.g(new_color),
              b - ChunkyPNG::Color.b(new_color),
              a - ChunkyPNG::Color.a(new_color)
            ]
            DITHERING_KERNEL.each do |dx, dy, numerator|
              nx = x + dx
              ny = y + dy
              next unless include_xy?(nx, ny)
              neighbor = work[ny * width + nx]
              4.times do |channel|
                neighbor[channel] += (error[channel] * numerator) / 16
              end
            end
          end
        end

        @pixels = quantized
      end

      # Returns the color from the palette that is closest to the given
      # color in RGBA space. Ties are broken by palette position, so the
      # result is deterministic.
      def closest_palette_color(color, palette)
        best_color = palette[0]
        best_distance = color_distance_squared(color, best_color)
        index = 1
        while index < palette.length
          distance = color_distance_squared(color, palette[index])
          if distance < best_distance
            best_distance = distance
            best_color = palette[index]
          end
          index += 1
        end
        best_color
      end

      # Returns the squared Euclidean distance between two colors in RGBA
      # space, so the alpha channel participates in the comparison.
      def color_distance_squared(color, other)
        dr = ChunkyPNG::Color.r(color) - ChunkyPNG::Color.r(other)
        dg = ChunkyPNG::Color.g(color) - ChunkyPNG::Color.g(other)
        db = ChunkyPNG::Color.b(color) - ChunkyPNG::Color.b(other)
        da = ChunkyPNG::Color.a(color) - ChunkyPNG::Color.a(other)
        (dr * dr) + (dg * dg) + (db * db) + (da * da)
      end

      # Clamps a channel value to the 0-255 range.
      def clamp_channel(value)
        value < 0 ? 0 : (value > 255 ? 255 : value)
      end
    end
  end
end
