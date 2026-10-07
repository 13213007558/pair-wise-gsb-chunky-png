# frozen-string-literal: true

module ChunkyPNG
  class Animation
    # Reads the chunks of an APNG datastream in order, and assembles them
    # into a ChunkyPNG::Animation instance.
    #
    # Because the order in which frame control, image data and frame data
    # chunks appear in the stream determines the structure of the animation,
    # the chunks are processed in stream order instead of going through
    # ChunkyPNG::Datastream.
    #
    # @see ChunkyPNG::Animation.from_io
    # @private
    class StreamReader
      def initialize
        @header = nil
        @animation_control = nil
        @palette_chunk = nil
        @transparency_chunk = nil
        @frame_controls = []
        @frame_data = []
        @default_image_data = []
        @sequence_number = 0
      end

      # Reads all chunks from the stream, up to and including the IEND chunk.
      # @param [IO, #read] io The stream to read from.
      # @return [void]
      def read(io)
        end_chunk = nil
        until end_chunk
          chunk = ChunkyPNG::Chunk.read(io)
          case chunk
          when ChunkyPNG::Chunk::Header           then @header = chunk
          when ChunkyPNG::Chunk::AnimationControl then @animation_control = chunk
          when ChunkyPNG::Chunk::Palette          then @palette_chunk = chunk
          when ChunkyPNG::Chunk::Transparency     then @transparency_chunk = chunk
          when ChunkyPNG::Chunk::FrameControl     then read_frame_control(chunk)
          when ChunkyPNG::Chunk::ImageData        then read_image_data(chunk)
          when ChunkyPNG::Chunk::FrameData        then read_frame_data(chunk)
          when ChunkyPNG::Chunk::End              then end_chunk = chunk
          end
        end
      end

      # Builds the animation from the chunks that were read from the stream.
      # @return [ChunkyPNG::Animation] The decoded animation.
      # @raise [ChunkyPNG::ExpectationFailed] If the stream was not an
      #   animated PNG, or if its structure was invalid.
      def to_animation
        raise ChunkyPNG::ExpectationFailed, "This PNG is not an animated PNG!" if @animation_control.nil?

        if @animation_control.num_frames != @frame_controls.length
          raise ChunkyPNG::ExpectationFailed,
            "The animation control chunk declares #{@animation_control.num_frames} frames, " +            "but #{@frame_controls.length} frames were found!"
        end

        animation = Animation.new(@header.width, @header.height, loop_count: @animation_control.num_plays)

        @frame_controls.each_with_index do |frame_control, index|
          data = @frame_data[index]
          raise ChunkyPNG::ExpectationFailed, "Frame #{index} does not contain any image data!" if data.empty?

          canvas = decode_canvas(data.join, frame_control.width, frame_control.height)
          animation.add_frame(
            Frame.new(
              canvas,
              x_offset: frame_control.x_offset,
              y_offset: frame_control.y_offset,
              delay_num: frame_control.delay_num,
              delay_den: frame_control.delay_den,
              dispose_op: frame_control.dispose_op,
              blend_op: frame_control.blend_op
            )
          )
        end

        unless @default_image_data.empty?
          animation.default_image = decode_canvas(@default_image_data.join, @header.width, @header.height)
        end

        animation
      end

      private

      # Processes a frame control chunk, starting a new frame.
      def read_frame_control(chunk)
        check_sequence_number!(chunk.sequence_number)
        @frame_controls << chunk
        @frame_data << []
      end

      # Processes an image data (IDAT) chunk. The IDAT chunks belong to the
      # animation's first frame if a frame control chunk for the first frame
      # appeared before them; otherwise they make up the default image, which
      # is not part of the animation.
      def read_image_data(chunk)
        if @frame_controls.length == 1 && @frame_data[0].empty? && @default_image_data.empty?
          @frame_data[0] << chunk.content
        else
          @default_image_data << chunk.content
        end
      end

      # Processes a frame data (fdAT) chunk, appending its data to the
      # current frame.
      def read_frame_data(chunk)
        check_sequence_number!(chunk.sequence_number)
        raise ChunkyPNG::ExpectationFailed, "Encountered a frame data chunk without a preceding frame control chunk!" if @frame_controls.empty?
        @frame_data[-1] << chunk.data
      end

      # Verifies that the sequence number of an fcTL or fdAT chunk matches
      # the expected position in the animation sequence.
      # @raise [ChunkyPNG::ExpectationFailed] If the sequence number is not
      #   the expected one.
      def check_sequence_number!(sequence_number)
        unless sequence_number == @sequence_number
          raise ChunkyPNG::ExpectationFailed,
            "Invalid frame sequence number: expected #{@sequence_number}, got #{sequence_number}!"
        end
        @sequence_number += 1
      end

      # Decodes a canvas from a compressed pixelstream, using the color mode,
      # bit depth and interlace method from the animation's header chunk.
      # @return [ChunkyPNG::Canvas] The decoded canvas.
      def decode_canvas(compressed_stream, width, height)
        stream = Zlib::Inflate.inflate(compressed_stream)
        ChunkyPNG::Canvas.decode_png_pixelstream(
          stream, width, height,
          @header.color, @header.depth, @header.interlace,
          decoding_palette, transparent_color
        )
      end

      # @return [ChunkyPNG::Palette, nil] The palette to decode colors with,
      #   for indexed images.
      def decoding_palette
        return nil unless @header.color == ChunkyPNG::COLOR_INDEXED
        ChunkyPNG::Palette.from_chunks(@palette_chunk, @transparency_chunk)
      end

      # @return [Integer, nil] The color that should be considered fully
      #   transparent, for color modes without an alpha channel.
      def transparent_color
        return nil if @transparency_chunk.nil?
        case @header.color
        when ChunkyPNG::COLOR_TRUECOLOR then @transparency_chunk.truecolor_entry(@header.depth)
        when ChunkyPNG::COLOR_GRAYSCALE then @transparency_chunk.grayscale_entry(@header.depth)
        end
      end
    end
  end
end
