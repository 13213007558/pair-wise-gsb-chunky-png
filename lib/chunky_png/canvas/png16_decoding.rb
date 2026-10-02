# frozen-string-literal: true

module ChunkyPNG
  class Canvas
    # PNG decoding that preserves 16 bits per sample.
    module PNG16Decoding
      def from_blob(str)
        from_datastream(Datastream.from_blob(str))
      end

      alias from_string from_blob

      def from_file(filename)
        from_datastream(Datastream.from_file(filename))
      end

      def from_io(io)
        from_datastream(Datastream.from_io(io))
      end

      alias from_stream from_io

      def from_datastream(ds)
        header = ds.header_chunk
        unless header.depth == 16
          raise NotSupported, "Canvas16 can only decode 16-bit images, got #{header.depth}-bit!"
        end

        unless [COLOR_GRAYSCALE, COLOR_GRAYSCALE_ALPHA, COLOR_TRUECOLOR, COLOR_TRUECOLOR_ALPHA].include?(header.color)
          raise NotSupported, "Canvas16 cannot decode color mode #{header.color}!"
        end

        transparent_color = nil
        if ds.transparency_chunk
          transparent_color = case header.color
            when COLOR_TRUECOLOR then Color16.rgb(*ds.transparency_chunk.content.unpack("nnn"))
            when COLOR_GRAYSCALE then Color16.grayscale(ds.transparency_chunk.content.unpack("n").first)
          end
        end

        decode_png16_pixelstream(
          ds.imagedata,
          header.width,
          header.height,
          header.color,
          header.interlace,
          transparent_color
        )
      end

      protected

      def decode_png16_pixelstream(stream, width, height, color_mode, interlace, transparent_color)
        image = case interlace
          when INTERLACING_NONE
            decode_png16_without_interlacing(stream, width, height, color_mode)
          when INTERLACING_ADAM7
            decode_png16_with_adam7_interlacing(stream, width, height, color_mode)
          else raise NotSupported, "Don't know how to handle interlacing method #{interlace}!"
        end

        if transparent_color
          image.pixels.map! do |pixel|
            pixel == transparent_color ? pixel & 0xffffffffffff0000 : pixel
          end
        end
        image
      end

      def decode_png16_without_interlacing(stream, width, height, color_mode)
        decode_png16_image_pass(stream, width, height, color_mode, 0)
      end

      def decode_png16_with_adam7_interlacing(stream, width, height, color_mode)
        canvas = new(width, height)
        start_pos = 0

        0.upto(6) do |pass|
          pass_width, pass_height = adam7_pass_size(pass, width, height)
          subcanvas = decode_png16_image_pass(stream, pass_width, pass_height, color_mode, start_pos)
          adam7_merge_pass(pass, canvas, subcanvas)
          start_pos += Color.pass_bytesize(color_mode, 16, pass_width, pass_height)
        end

        canvas
      end

      def decode_png16_image_pass(stream, width, height, color_mode, start_pos)
        pixels = []
        if width > 0 && height > 0
          pixel_decoder = decode_png16_pixels_from_scanline_method(color_mode)
          line_length = Color.scanline_bytesize(color_mode, 16, width)
          pixel_size = Color.pixel_bytesize(color_mode, 16)
          required_size = Color.pass_bytesize(color_mode, 16, width, height)

          unless stream.bytesize - start_pos >= required_size
            raise ExpectationFailed, "Invalid stream length!"
          end

          pos = start_pos
          previous_pos = nil
          height.times do
            send(:decode_png_str_scanline, stream, pos, previous_pos, line_length, pixel_size)
            pixels.concat(send(pixel_decoder, stream, pos, width))
            previous_pos = pos
            pos += line_length + 1
          end
        end

        new(width, height, pixels)
      end

      def decode_png16_pixels_from_scanline_truecolor(stream, pos, width)
        stream.unpack("@#{pos + 1}n#{width * 3}").each_slice(3).map do |r, g, b|
          Color16.rgb(r, g, b)
        end
      end

      def decode_png16_pixels_from_scanline_truecolor_alpha(stream, pos, width)
        stream.unpack("@#{pos + 1}n#{width * 4}").each_slice(4).map do |r, g, b, a|
          Color16.rgba(r, g, b, a)
        end
      end

      def decode_png16_pixels_from_scanline_grayscale(stream, pos, width)
        stream.unpack("@#{pos + 1}n#{width}").map { |value| Color16.grayscale(value) }
      end

      def decode_png16_pixels_from_scanline_grayscale_alpha(stream, pos, width)
        stream.unpack("@#{pos + 1}n#{width * 2}").each_slice(2).map do |value, alpha|
          Color16.grayscale_alpha(value, alpha)
        end
      end

      def decode_png16_pixels_from_scanline_method(color_mode)
        case color_mode
          when COLOR_TRUECOLOR then :decode_png16_pixels_from_scanline_truecolor
          when COLOR_TRUECOLOR_ALPHA then :decode_png16_pixels_from_scanline_truecolor_alpha
          when COLOR_GRAYSCALE then :decode_png16_pixels_from_scanline_grayscale
          when COLOR_GRAYSCALE_ALPHA then :decode_png16_pixels_from_scanline_grayscale_alpha
          else raise NotSupported, "No 16-bit decoder found for color mode #{color_mode}!"
        end
      end
    end
  end
end
