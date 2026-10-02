# frozen-string-literal: true

module ChunkyPNG
  class Canvas
    # A snapshot of an Adam7 image after one or more complete passes.
    class Adam7ProgressiveSnapshot
      # @return [Integer] The zero-based pass number (0..6).
      attr_reader :pass

      # @return [ChunkyPNG::Canvas] An independent copy of the current canvas.
      attr_reader :canvas

      # @return [Array<Boolean>] A width * height mask for pixels that have a value.
      attr_reader :mask

      alias pass_index pass
      alias valid_pixels mask
      alias valid_pixel_mask mask

      def initialize(pass, canvas, mask)
        @pass = pass
        @canvas = canvas.dup
        @mask = mask.dup
      end

      # @return [Integer] The one-based pass number (1..7).
      def pass_number
        pass + 1
      end

      def to_ary
        [canvas, mask]
      end

      alias to_a to_ary
    end

    # Incrementally decodes Adam7 interlaced pixel data from IDAT chunks.
    #
    # Compressed IDAT payloads can be fed to the decoder in pieces of arbitrary
    # sizes. Snapshots are only emitted after every scanline of a pass has been
    # decompressed and decoded. Empty passes advance without scanline data.
    class Adam7ProgressiveDecoder
      attr_reader :width, :height, :pass, :canvas, :mask, :snapshots

      def initialize(width, height, color_mode, depth, decoding_palette = nil, transparent_color = nil)
        if width == 0 || height == 0
          raise ExpectationFailed, "Invalid image size, width: #{width}, height: #{height}"
        end

        @width = width
        @height = height
        @color_mode = color_mode
        @depth = depth
        @decoding_palette = decoding_palette
        @transparent_color = transparent_color

        if decoding_palette && !decoding_palette.can_decode?
          raise ExpectationFailed, "This palette is not suitable for decoding!"
        end

        @canvas = Canvas.new(width, height)
        @mask = Array.new(width * height, false)
        @inflate = Zlib::Inflate.new
        @buffer = String.new.force_encoding(::Encoding::BINARY)
        @snapshots = []
        @pass = 0
        @finished = false
        @pos = 0

        @pixel_decoder = Canvas.send(:decode_png_pixels_from_scanline_method, color_mode, depth)
        start_pass
      end

      # Feeds a part of the compressed IDAT byte stream.
      # @param [String] data Compressed bytes from one or more IDAT chunks.
      # @return [Array<ChunkyPNG::Canvas::Adam7ProgressiveSnapshot>] Newly completed passes.
      def feed(data)
        raise ChunkyPNG::ExpectationFailed, "Decoder has already been finished!" if @finished
        @buffer << @inflate.inflate(data.to_s.dup.force_encoding(::Encoding::BINARY))
        snapshot_count = @snapshots.length
        process
        completed = @snapshots[snapshot_count, @snapshots.length - snapshot_count] || []
        completed
      end

      alias << feed

      # Waits for the compressed stream to end and validates that all 7 passes decoded.
      # @return [ChunkyPNG::Canvas::Adam7ProgressiveSnapshot] The final pass snapshot.
      def finish
        unless @finished
          @buffer << @inflate.finish
          @inflate.close
          @finished = true
          process
          unless @pass == 7 && @buffer.bytesize == @pos
            raise ChunkyPNG::ExpectationFailed, "Invalid progressive Adam7 pixel stream!"
          end
        end

        @snapshots.last
      end

      def final_canvas
        finish.canvas
      end

      private

      def start_pass
        while @pass < 7
          @pass_width, @pass_height = Canvas.adam7_pass_size(@pass, width, height)
          if @pass_width == 0 || @pass_height == 0
            @line_length = 0
            @scanline_length = 0
            @pass_start_pos = @pos
            @pixel_size = Color.pixel_bytesize(@color_mode, @depth)
            @decoded_rows = 0
            @row_pixels = []
            emit_snapshot
            @pass += 1
          else
            @line_length = Color.scanline_bytesize(@color_mode, @depth, @pass_width)
            @scanline_length = @line_length + 1
            @pass_start_pos = @pos
            @pixel_size = Color.pixel_bytesize(@color_mode, @depth)
            @decoded_rows = 0
            @row_pixels = []
            return
          end
        end
      end

      def process
        while @pass < 7 && @buffer.bytesize - @pass_start_pos >= (@decoded_rows + 1) * @scanline_length
          decode_scanline
        end
      end

      def decode_scanline
        scanline_pos = @pass_start_pos + (@decoded_rows * @scanline_length)
        previous_pos = @decoded_rows.zero? ? nil : scanline_pos - @scanline_length
        Canvas.send(:decode_png_str_scanline, @buffer, scanline_pos, previous_pos, @line_length, @pixel_size)
        pixels = decode_pixels(scanline_pos)
        pixels.map! { |pixel| pixel == @transparent_color ? Color::TRANSPARENT : pixel } if @transparent_color

        @row_pixels.concat(pixels)
        @decoded_rows += 1

        complete_pass if @decoded_rows == @pass_height
      end

      def decode_pixels(scanline_pos)
        Canvas.send(@pixel_decoder, @buffer, scanline_pos, @pass_width, @decoding_palette)
      end

      def complete_pass
        subcanvas = Canvas.new(@pass_width, @pass_height, @row_pixels)
        Canvas.adam7_merge_pass(@pass, @canvas, subcanvas)

        x_shift, x_offset, y_shift, y_offset = Canvas.adam7_multiplier_offset(@pass)
        for y in 0...@pass_height
          for x in 0...@pass_width
            new_x = (x << x_shift) | x_offset
            new_y = (y << y_shift) | y_offset
            @mask[new_y * width + new_x] = true
          end
        end

        @pos = @pass_start_pos + (@pass_height * @scanline_length)
        emit_snapshot
        @pass += 1
        start_pass
      end

      def emit_snapshot
        @snapshots << Adam7ProgressiveSnapshot.new(@pass, @canvas, @mask)
      end
    end
  end
end
