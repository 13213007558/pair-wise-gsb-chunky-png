# frozen-string-literal: true

module ChunkyPNG
  class Canvas
    # Methods to reduce the number of colors of a canvas, so that it can be
    # saved as an indexed PNG image.
    #
    # Quantization maps every pixel of the canvas to a color from a palette
    # with a limited number of colors. The palette can either be generated
    # from the canvas itself using a median cut algorithm, or be provided by
    # the caller. Optionally, Floyd-Steinberg dithering can be applied to
    # spread the quantization error over neighboring pixels.
    #
    # The alpha channel participates in color distance calculations, so
    # semi-transparent edges are quantized sensibly. Fully transparent pixels
    # are matched on their alpha channel only, and do not diffuse meaningless
    # color error into (semi-)opaque regions when dithering.
    #
    # All methods in this module are deterministic: the same input canvas and
    # options always produce the same output canvas. Color ordering and
    # tie-breaking between equidistant colors never depend on hash iteration
    # order.
    module Quantization
      # The channel decomposition order used by the quantization routines.
      # @private
      CHANNELS = [:r, :g, :b, :a].freeze

      # The fractions used to distribute quantization error to neighboring
      # pixels when performing Floyd-Steinberg dithering.
      # @private
      DITHER_MATRIX = [[1, 0, 7.0 / 16], [-1, 1, 3.0 / 16], [0, 1, 5.0 / 16], [1, 1, 1.0 / 16]].freeze

      # Returns a copy of this canvas in which every pixel is replaced by a
      # color from a palette of at most +max_colors+ colors.
      #
      # The returned canvas has its +encoding_palette+ set, so it can be
      # saved directly as an indexed PNG image.
      #
      # @param max_colors [Integer] The maximum number of colors in the
      #   palette, between 1 and 256.
      # @param palette [Array<Integer>, ChunkyPNG::Palette, nil] An optional
      #   caller-provided palette to quantize to. When given, these colors
      #   are used as-is instead of generating a palette from the canvas.
      # @param dither [true, false] Whether to apply Floyd-Steinberg dithering
      #   while mapping pixels to palette colors. Defaults to false.
      # @return [ChunkyPNG::Canvas] A new canvas that only uses colors from
      #   the quantization palette.
      # @raise [ArgumentError] If +max_colors+ is out of range.
      # @raise [ChunkyPNG::ExpectationFailed] If the caller-provided palette
      #   contains more colors than +max_colors+ allows.
      def quantize(max_colors = 256, palette: nil, dither: false)
        max_colors = Integer(max_colors)
        unless max_colors.between?(1, 256)
          raise ArgumentError, "The number of colors should be between 1 and 256, got #{max_colors}!"
        end

        colors = palette ? resolve_quantization_palette(palette, max_colors) : generate_quantization_palette(max_colors)
        quantized = dither ? quantize_pixels_dithered(colors) : quantize_pixels(colors)

        canvas = self.class.new(width, height, quantized)
        canvas.encoding_palette = ChunkyPNG::Palette.new(colors)
        canvas
      end

      private

      # Normalizes a caller-provided palette to a deterministic list of
      # unique colors, and checks it against the color limit.
      # @param palette [Array<Integer>, ChunkyPNG::Palette] The palette.
      # @param max_colors [Integer] The maximum allowed number of colors.
      # @return [Array<Integer>] The palette colors.
      def resolve_quantization_palette(palette, max_colors)
        colors = palette.to_a.map { |color| ChunkyPNG::Color.parse(color) }.uniq
        if colors.empty?
          raise ChunkyPNG::ExpectationFailed, "Cannot quantize to an empty palette!"
        end
        if colors.length > max_colors
          raise ChunkyPNG::ExpectationFailed,
            "Palette conflict: the provided palette has #{colors.length} colors, " +            "which exceeds the maximum of #{max_colors} colors!"
        end
        colors
      end

      # Builds a palette of at most +max_colors+ colors from this canvas
      # using median cut. Deterministic: identical canvases always yield
      # identical palettes in identical order.
      # @param max_colors [Integer] The maximum number of palette colors.
      # @return [Array<Integer>] The generated palette colors.
      def generate_quantization_palette(max_colors)
        histogram = Hash.new(0)
        pixels.each do |pixel|
          # The r, g and b channels of fully transparent pixels are
          # meaningless, so they are all counted as fully transparent to
          # avoid wasting palette colors on invisible channel values.
          histogram[ChunkyPNG::Color.fully_transparent?(pixel) ? ChunkyPNG::Color::TRANSPARENT : pixel] += 1
        end
        colors = histogram.keys.sort
        return colors if colors.length <= max_colors

        boxes = [colors]
        while boxes.length < max_colors
          index = quantization_split_candidate(boxes, histogram)
          break if index.nil?

          left, right = quantization_split_box(boxes.delete_at(index), histogram)
          boxes.insert(index, left)
          boxes.insert(index + 1, right)
        end

        boxes.map { |box| [quantization_box_population(box, histogram), quantization_average_color(box, histogram)] }
          .sort_by { |population, color| [-population, color] }
          .map { |_, color| color }
          .uniq
      end

      # Returns the index of the box that is the best candidate for splitting:
      # the splittable box with the largest population. Ties are broken by
      # channel range, and then by position, so the result never depends on
      # hash iteration order.
      # @return [Integer, nil] The index of the box to split, or nil if no
      #   box can be split further.
      def quantization_split_candidate(boxes, histogram)
        best_index = nil
        best_key = nil
        boxes.each_with_index do |box, index|
          next if box.length < 2

          key = [quantization_box_population(box, histogram), quantization_box_range(box)]
          if best_key.nil? || (key <=> best_key) > 0
            best_index = index
            best_key = key
          end
        end
        best_index
      end

      # Splits a box of colors into two boxes at the weighted median along
      # the channel with the largest range.
      # @return [Array(Array<Integer>, Array<Integer>)] The two new boxes.
      def quantization_split_box(box, histogram)
        channel = quantization_widest_channel(box)
        sorted = box.sort_by { |color| [ChunkyPNG::Color.send(channel, color), color] }

        total = sorted.inject(0) { |sum, color| sum + histogram[color] }
        half = total / 2.0
        cumulative = 0
        split_at = sorted.length - 1
        sorted.each_with_index do |color, index|
          cumulative += histogram[color]
          if cumulative >= half
            split_at = index
            break
          end
        end
        split_at = 1 if split_at < 1

        [sorted[0...split_at], sorted[split_at..-1]]
      end

      # @return [Integer] The total number of pixels the colors in the box
      #   account for.
      def quantization_box_population(box, histogram)
        box.inject(0) { |sum, color| sum + histogram[color] }
      end

      # @return [Integer] The largest per-channel value range of the colors
      #   in the box.
      def quantization_box_range(box)
        ranges = quantization_channel_ranges(box)
        ranges.max
      end

      # @return [Integer] The channel (:r, :g, :b or :a) with the largest
      #   range within the box. Ties are broken in r, g, b, a order.
      def quantization_widest_channel(box)
        ranges = quantization_channel_ranges(box)
        index = ranges.each_with_index.max_by { |range, i| [range, -i] }.last
        CHANNELS[index]
      end

      # @return [Array<Integer>] The value range per channel, in r, g, b, a
      #   order.
      def quantization_channel_ranges(box)
        CHANNELS.map do |channel|
          values = box.map { |color| ChunkyPNG::Color.send(channel, color) }
          values.max - values.min
        end
      end

      # @return [Integer] The weighted average color of the box.
      def quantization_average_color(box, histogram)
        total = quantization_box_population(box, histogram)
        sums = [0, 0, 0, 0]
        box.each do |color|
          count = histogram[color]
          sums[0] += ChunkyPNG::Color.r(color) * count
          sums[1] += ChunkyPNG::Color.g(color) * count
          sums[2] += ChunkyPNG::Color.b(color) * count
          sums[3] += ChunkyPNG::Color.a(color) * count
        end
        ChunkyPNG::Color.rgba(*(sums.map { |sum| (sum / total.to_f).round }))
      end

      # Maps every pixel to its nearest palette color without dithering.
      # @param palette [Array<Integer>] The palette colors.
      # @return [Array<Integer>] The quantized pixels.
      def quantize_pixels(palette)
        channels = quantization_palette_channels(palette)
        cache = {}
        pixels.map do |pixel|
          cache[pixel] ||= palette[quantization_nearest_index(channels, pixel, ChunkyPNG::Color.r(pixel), ChunkyPNG::Color.g(pixel), ChunkyPNG::Color.b(pixel), ChunkyPNG::Color.a(pixel))]
        end
      end

      # Maps every pixel to its nearest palette color, diffusing the
      # quantization error to neighboring pixels using Floyd-Steinberg
      # dithering. Fully transparent pixels only carry alpha error, so they
      # do not spread meaningless color error into opaque regions.
      # @param palette [Array<Integer>] The palette colors.
      # @return [Array<Integer>] The quantized pixels.
      def quantize_pixels_dithered(palette)
        channels = quantization_palette_channels(palette)
        quantized = Array.new(pixels.length)
        errors = [Array.new(pixels.length, 0.0), Array.new(pixels.length, 0.0), Array.new(pixels.length, 0.0), Array.new(pixels.length, 0.0)]

        0.upto(height - 1) do |y|
          0.upto(width - 1) do |x|
            position = y * width + x
            pixel = pixels[position]
            transparent = ChunkyPNG::Color.fully_transparent?(pixel)

            adjusted = [
              quantization_clamp_channel(ChunkyPNG::Color.r(pixel) + errors[0][position]),
              quantization_clamp_channel(ChunkyPNG::Color.g(pixel) + errors[1][position]),
              quantization_clamp_channel(ChunkyPNG::Color.b(pixel) + errors[2][position]),
              quantization_clamp_channel(ChunkyPNG::Color.a(pixel) + errors[3][position])
            ]

            index = quantization_nearest_index(channels, pixel, *adjusted)
            chosen = channels[index]
            quantized[position] = palette[index]

            delta = if transparent
              [0.0, 0.0, 0.0, adjusted[3] - chosen[3]]
            else
              [adjusted[0] - chosen[0], adjusted[1] - chosen[1], adjusted[2] - chosen[2], adjusted[3] - chosen[3]]
            end

            DITHER_MATRIX.each do |dx, dy, fraction|
              nx, ny = x + dx, y + dy
              next unless nx >= 0 && nx < width && ny < height

              neighbor = ny * width + nx
              4.times { |component| errors[component][neighbor] += delta[component] * fraction }
            end
          end
        end
        quantized
      end

      # Decomposes the palette into per-color channel arrays once, for fast
      # nearest-color lookups.
      # @return [Array<Array<Integer>>] One [r, g, b, a] array per color.
      def quantization_palette_channels(palette)
        palette.map do |color|
          [ChunkyPNG::Color.r(color), ChunkyPNG::Color.g(color), ChunkyPNG::Color.b(color), ChunkyPNG::Color.a(color)]
        end
      end

      # Finds the index of the palette color closest to the given channel
      # values, using squared euclidean distance over all four channels.
      # Fully transparent pixels are matched on their alpha channel only,
      # because their r, g and b channels are meaningless. Ties are broken
      # by palette position, so the result is deterministic.
      # @return [Integer] The index of the nearest palette color.
      def quantization_nearest_index(channels, pixel, r, g, b, a)
        transparent = ChunkyPNG::Color.fully_transparent?(pixel)
        best_index = 0
        best_distance = nil
        channels.each_with_index do |color, index|
          distance = if transparent
            da = a - color[3]
            da * da
          else
            dr = r - color[0]
            dg = g - color[1]
            db = b - color[2]
            da = a - color[3]
            dr * dr + dg * dg + db * db + da * da
          end
          if best_distance.nil? || distance < best_distance
            best_index = index
            best_distance = distance
          end
        end
        best_index
      end

      # @return [Integer] The channel value clamped to the 0-255 range.
      def quantization_clamp_channel(value)
        value.round.clamp(0, 255)
      end
    end
  end
end
