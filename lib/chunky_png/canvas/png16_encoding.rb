# frozen-string-literal: true

module ChunkyPNG
  class Canvas
    # PNG encoding for canvases with 16 bits per sample.
    module PNG16Encoding
      def to_datastream(constraints = {})
        encoding = determine_png16_encoding(constraints)

        ds = Datastream.new
        ds.header_chunk = Chunk::Header.new(
          width: width,
          height: height,
          color: encoding[:color_mode],
          depth: 16,
          interlace: encoding[:interlace]
        )

        data = encode_png16_pixelstream(
          encoding[:color_mode],
          encoding[:interlace],
          encoding[:filtering]
        )
        ds.data_chunks = Chunk::ImageData.split_in_chunks(data, encoding[:compression])
        ds.end_chunk = Chunk::End.new
        ds
      end

      protected

      def determine_png16_encoding(constraints)
        encoding = case constraints
          when :fast_rgb         then {color_mode: ChunkyPNG::COLOR_TRUECOLOR, compression: Zlib::BEST_SPEED}
          when :fast_rgba        then {color_mode: ChunkyPNG::COLOR_TRUECOLOR_ALPHA, compression: Zlib::BEST_SPEED}
          when :best_compression then {compression: Zlib::BEST_COMPRESSION, filtering: ChunkyPNG::FILTER_PAETH}
          when :good_compression then {compression: Zlib::BEST_COMPRESSION, filtering: ChunkyPNG::FILTER_NONE}
          when :no_compression   then {compression: Zlib::NO_COMPRESSION, filtering: ChunkyPNG::FILTER_NONE}
          when Hash              then constraints.dup
          else raise ChunkyPNG::Exception, "Unknown encoding preset: #{constraints.inspect}"
        end

        encoding[:color_mode] ||= pixels.all? { |pixel| Color16.a(pixel) == Color16::MAX } ?
          (pixels.all? { |pixel| Color16.r(pixel) == Color16.g(pixel) && Color16.g(pixel) == Color16.b(pixel) } ?
            ChunkyPNG::COLOR_GRAYSCALE : ChunkyPNG::COLOR_TRUECOLOR) :
          (pixels.all? { |pixel| Color16.r(pixel) == Color16.g(pixel) && Color16.g(pixel) == Color16.b(pixel) } ?
            ChunkyPNG::COLOR_GRAYSCALE_ALPHA : ChunkyPNG::COLOR_TRUECOLOR_ALPHA)

        unless [
          ChunkyPNG::COLOR_GRAYSCALE,
          ChunkyPNG::COLOR_GRAYSCALE_ALPHA,
          ChunkyPNG::COLOR_TRUECOLOR,
          ChunkyPNG::COLOR_TRUECOLOR_ALPHA,
        ].include?(encoding[:color_mode])
          raise ChunkyPNG::NotSupported, "Canvas16 cannot encode color mode #{encoding[:color_mode]}!"
        end

        if encoding.key?(:bit_depth) && encoding[:bit_depth] != 16
          raise ChunkyPNG::NotSupported, "Canvas16 only supports a 16-bit sample depth!"
        end

        encoding[:compression] ||= Zlib::DEFAULT_COMPRESSION
        encoding[:interlace] = case encoding[:interlace]
          when nil, false then ChunkyPNG::INTERLACING_NONE
          when true then ChunkyPNG::INTERLACING_ADAM7
          else encoding[:interlace]
        end

        encoding[:filtering] ||= case encoding[:compression]
          when Zlib::BEST_COMPRESSION then ChunkyPNG::FILTER_PAETH
          when Zlib::NO_COMPRESSION..Zlib::BEST_SPEED then ChunkyPNG::FILTER_NONE
          else ChunkyPNG::FILTER_UP
        end
        encoding
      end

      def encode_png16_pixelstream(
        color_mode,
        interlace = ChunkyPNG::INTERLACING_NONE,
        filtering = ChunkyPNG::FILTER_NONE
      )
        case interlace
          when ChunkyPNG::INTERLACING_NONE then encode_png16_image_without_interlacing(color_mode, filtering)
          when ChunkyPNG::INTERLACING_ADAM7 then encode_png16_image_with_interlacing(color_mode, filtering)
          else raise ChunkyPNG::NotSupported, "Unknown interlacing method: #{interlace}!"
        end
      end

      def encode_png16_image_without_interlacing(color_mode, filtering)
        stream = "".b
        encode_png16_image_pass_to_stream(stream, color_mode, filtering)
        stream
      end

      def encode_png16_image_with_interlacing(color_mode, filtering)
        stream = "".b
        0.upto(6) do |pass|
          subcanvas = self.class.adam7_extract_pass(pass, self)
          subcanvas.encode_png16_image_pass_to_stream(stream, color_mode, filtering)
        end
        stream
      end

      def encode_png16_image_pass_to_stream(stream, color_mode, filtering)
        start_pos = stream.bytesize
        pixel_size = Color.pixel_bytesize(color_mode, 16)
        line_width = Color.scanline_bytesize(color_mode, 16, width)
        encode_method = encode_png16_pixels_to_scanline_method(color_mode)

        filter_method = case filtering
          when ChunkyPNG::FILTER_NONE then nil
          when ChunkyPNG::FILTER_SUB then :encode_png_str_scanline_sub
          when ChunkyPNG::FILTER_UP then :encode_png_str_scanline_up
          when ChunkyPNG::FILTER_AVERAGE then :encode_png_str_scanline_average
          when ChunkyPNG::FILTER_PAETH then :encode_png_str_scanline_paeth
          else raise ArgumentError, "Filtering method #{filtering} is not supported"
        end

        if width > 0
          0.upto(height - 1) { |y| stream << send(encode_method, row(y)) }
        end

        if width > 0 && filter_method
          (height - 1).downto(0) do |y|
            pos = start_pos + y * (line_width + 1)
            prev_pos = y.zero? ? nil : pos - (line_width + 1)
            send(filter_method, stream, pos, prev_pos, line_width, pixel_size)
          end
        end
      end

      def encode_png16_pixels_to_scanline_truecolor(pixels)
        values = pixels.flat_map { |pixel| Color16.to_truecolor_bytes(pixel) }
        values.pack("xn#{values.length}")
      end

      def encode_png16_pixels_to_scanline_truecolor_alpha(pixels)
        values = pixels.flat_map { |pixel| Color16.to_truecolor_alpha_bytes(pixel) }
        values.pack("xn#{values.length}")
      end

      def encode_png16_pixels_to_scanline_grayscale(pixels)
        values = pixels.map { |pixel| Color16.r(pixel) }
        values.pack("xn#{values.length}")
      end

      def encode_png16_pixels_to_scanline_grayscale_alpha(pixels)
        values = pixels.flat_map { |pixel| Color16.to_grayscale_alpha_bytes(pixel) }
        values.pack("xn#{values.length}")
      end

      def encode_png16_pixels_to_scanline_method(color_mode)
        case color_mode
          when ChunkyPNG::COLOR_TRUECOLOR then :encode_png16_pixels_to_scanline_truecolor
          when ChunkyPNG::COLOR_TRUECOLOR_ALPHA then :encode_png16_pixels_to_scanline_truecolor_alpha
          when ChunkyPNG::COLOR_GRAYSCALE then :encode_png16_pixels_to_scanline_grayscale
          when ChunkyPNG::COLOR_GRAYSCALE_ALPHA then :encode_png16_pixels_to_scanline_grayscale_alpha
          else raise ChunkyPNG::NotSupported, "No 16-bit encoder found for color mode #{color_mode}!"
        end
      end
    end
  end
end
