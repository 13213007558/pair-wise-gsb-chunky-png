# frozen-string-literal: true

module ChunkyPNG
  # The Animation class represents an animated PNG (APNG) image: a canvas
  # size, a loop count, and a list of frames. Every frame has its own canvas,
  # the rectangle on the output buffer it should be rendered on, the time it
  # should be displayed, and blend and dispose operations that determine how
  # the frames are combined into the image that is shown for every frame.
  #
  # Besides the animation frames, an APNG can carry a default image (the
  # image stored in the IDAT chunks) that is shown by decoders that do not
  # support animation. This default image may, but does not have to, be part
  # of the animation itself.
  #
  # @example Reading an animated PNG
  #   animation = ChunkyPNG::Animation.from_file("animated.png")
  #   animation.num_plays       # => 0 (loop forever)
  #   animation.frame_count     # => 3
  #   animation.frames[0].delay # => (1/10) seconds
  #   animation.frame_canvas(0) # => fully rendered canvas for the first frame
  #
  # @example Creating an animated PNG
  #   animation = ChunkyPNG::Animation.new(10, 10, num_plays: 0)
  #   animation.frames << ChunkyPNG::Animation::Frame.new(red_canvas)
  #   animation.frames << ChunkyPNG::Animation::Frame.new(green_square, x_offset: 2, y_offset: 3)
  #   animation.save("animated.png")
  #
  # @see https://wiki.mozilla.org/APNG_Specification
  class Animation
    # The default encoding settings used when saving an animation. These can
    # be overridden by passing constraints to {#to_datastream}.
    # @private
    DEFAULT_ENCODING = {
      color_mode: ChunkyPNG::COLOR_TRUECOLOR_ALPHA,
      compression: Zlib::DEFAULT_COMPRESSION,
      filtering: ChunkyPNG::FILTER_NONE,
    }.freeze

    # The width of the animation's canvas in pixels.
    # @return [Integer]
    attr_reader :width

    # The height of the animation's canvas in pixels.
    # @return [Integer]
    attr_reader :height

    # The number of times the animation should be played. A value of 0 means
    # the animation loops forever.
    # @return [Integer]
    attr_accessor :num_plays

    # The frames of this animation, in play order.
    # @return [Array<ChunkyPNG::Animation::Frame>]
    attr_accessor :frames

    # The default image of the animation, i.e. the image that decoders
    # without animation support will display. This image is not part of the
    # animation itself. +nil+ if the animation's first frame doubles as the
    # default image.
    # @return [ChunkyPNG::Canvas, nil]
    attr_accessor :default_image

    # Initializes a new Animation instance.
    # @param [Integer] width The width of the animation's canvas in pixels.
    # @param [Integer] height The height of the animation's canvas in pixels.
    # @param [Integer] num_plays The number of times the animation should be
    #   played, or 0 to loop forever.
    # @param [ChunkyPNG::Canvas, nil] default_image The image to show in
    #   decoders that do not support animation. When +nil+, the first frame
    #   of the animation is used as the default image.
    def initialize(width, height, num_plays: 0, default_image: nil)
      @width  = width
      @height = height
      @num_plays = num_plays
      @default_image = default_image
      @frames = []
    end

    ##############################################################################
    # LOADING ANIMATIONS
    ##############################################################################

    class << self
      # Reads an animated PNG from a string.
      # @param [String] str The APNG encoded string to load from.
      # @return [ChunkyPNG::Animation] The loaded animation instance.
      # @raise [ChunkyPNG::ExpectationFailed] If the string is not an animated PNG.
      def from_blob(str)
        from_datastream(ChunkyPNG::Datastream.from_blob(str))
      end

      alias from_string from_blob

      # Reads an animated PNG from a file.
      # @param [String] filename The path of the file to load from.
      # @return [ChunkyPNG::Animation] The loaded animation instance.
      # @raise [ChunkyPNG::ExpectationFailed] If the file is not an animated PNG.
      def from_file(filename)
        from_datastream(ChunkyPNG::Datastream.from_file(filename))
      end

      # Reads an animated PNG from an input stream.
      # @param [IO] io The stream to read from.
      # @return [ChunkyPNG::Animation] The loaded animation instance.
      # @raise [ChunkyPNG::ExpectationFailed] If the stream is not an animated PNG.
      def from_io(io)
        from_datastream(ChunkyPNG::Datastream.from_io(io))
      end

      alias from_stream from_io

      # Decodes an Animation from a PNG datastream instance.
      # @param [ChunkyPNG::Datastream] ds The datastream to decode.
      # @return [ChunkyPNG::Animation] The decoded animation instance.
      # @raise [ChunkyPNG::ExpectationFailed] If the datastream is not an
      #   animated PNG, or if its frame structure is invalid.
      def from_datastream(ds)
        unless ds.animated?
          raise ChunkyPNG::ExpectationFailed, "This datastream is not an animated PNG!"
        end

        header     = ds.header_chunk
        width      = header.width
        height     = header.height
        color_mode = header.color
        depth      = header.depth
        interlace  = header.interlace

        decoding_palette, transparent_color = nil, nil
        case color_mode
          when ChunkyPNG::COLOR_INDEXED
            decoding_palette = ChunkyPNG::Palette.from_chunks(ds.palette_chunk, ds.transparency_chunk)
          when ChunkyPNG::COLOR_TRUECOLOR
            transparent_color = ds.transparency_chunk.truecolor_entry(depth) if ds.transparency_chunk
          when ChunkyPNG::COLOR_GRAYSCALE
            transparent_color = ds.transparency_chunk.grayscale_entry(depth) if ds.transparency_chunk
        end

        control = ds.animation_control_chunk
        if control.num_frames != ds.animation_frames.length
          raise ChunkyPNG::ExpectationFailed,
            "The acTL chunk announces #{control.num_frames} frames, but the stream contains #{ds.animation_frames.length} frames!"
        end

        animation = new(width, height, num_plays: control.num_plays)

        sequence_number = 0
        ds.animation_frames.each do |animation_frame|
          frame_control = animation_frame.control_chunk
          if !frame_control.sequence_number.nil? && frame_control.sequence_number != sequence_number
            raise ChunkyPNG::ExpectationFailed,
              "Invalid frame control sequence number: expected #{sequence_number}, got #{frame_control.sequence_number}!"
          end
          sequence_number += 1

          assert_frame_control!(frame_control, width, height)

          if animation_frame.uses_default_image
            stream          = ds.imagedata
            frame_interlace = interlace
          else
            animation_frame.data_chunks.each do |data_chunk|
              if !data_chunk.sequence_number.nil? && data_chunk.sequence_number != sequence_number
                raise ChunkyPNG::ExpectationFailed,
                  "Invalid frame data sequence number: expected #{sequence_number}, got #{data_chunk.sequence_number}!"
              end
              sequence_number += 1
            end
            stream          = ChunkyPNG::Chunk::FrameData.combine_chunks(animation_frame.data_chunks)
            frame_interlace = ChunkyPNG::INTERLACING_NONE
          end

          canvas = ChunkyPNG::Canvas.decode_png_pixelstream(
            stream, frame_control.width, frame_control.height,
            color_mode, depth, frame_interlace, decoding_palette, transparent_color
          )

          animation.frames << Frame.new(
            canvas,
            x_offset: frame_control.x_offset,
            y_offset: frame_control.y_offset,
            delay_num: frame_control.delay_num,
            delay_den: frame_control.delay_den,
            dispose_op: frame_control.dispose_op,
            blend_op: frame_control.blend_op
          )
        end

        first_frame_is_default = ds.animation_frames.first && ds.animation_frames.first.uses_default_image
        if !ds.data_chunks.empty? && !first_frame_is_default
          animation.default_image = ChunkyPNG::Canvas.decode_png_pixelstream(
            ds.imagedata, width, height,
            color_mode, depth, interlace, decoding_palette, transparent_color
          )
        end

        animation
      end

      private

      # Validates the frame control chunk of a single frame against the
      # animation's canvas dimensions.
      # @raise [ChunkyPNG::ExpectationFailed] If the frame's rectangle does
      #   not fit on the animation's canvas.
      # @raise [ChunkyPNG::NotSupported] If the frame uses unknown dispose or
      #   blend operations.
      def assert_frame_control!(frame_control, width, height)
        if frame_control.width.nil? || frame_control.width == 0 ||
            frame_control.height.nil? || frame_control.height == 0
          raise ChunkyPNG::ExpectationFailed, "Frames cannot have an empty rectangle!"
        end

        if frame_control.x_offset + frame_control.width > width ||
            frame_control.y_offset + frame_control.height > height
          raise ChunkyPNG::ExpectationFailed,
            "Frame rectangle #{frame_control.width}x#{frame_control.height} at #{frame_control.x_offset},#{frame_control.y_offset} does not fit on the #{width}x#{height} canvas!"
        end

        unless [ChunkyPNG::APNG_DISPOSE_OP_NONE, ChunkyPNG::APNG_DISPOSE_OP_BACKGROUND,
            ChunkyPNG::APNG_DISPOSE_OP_PREVIOUS].include?(frame_control.dispose_op)
          raise ChunkyPNG::NotSupported, "Unknown dispose operation: #{frame_control.dispose_op}!"
        end

        unless [ChunkyPNG::APNG_BLEND_OP_SOURCE, ChunkyPNG::APNG_BLEND_OP_OVER].include?(frame_control.blend_op)
          raise ChunkyPNG::NotSupported, "Unknown blend operation: #{frame_control.blend_op}!"
        end
      end
    end

    ##############################################################################
    # FRAMES
    ##############################################################################

    # The number of frames in this animation.
    # @return [Integer]
    def frame_count
      frames.length
    end

    # The total duration of one play of the animation in seconds.
    # @return [Rational] The summed delay of all frames.
    def duration
      frames.inject(0.to_r) { |sum, frame| sum + frame.delay }
    end

    # Iterates over the animation's frames, yielding the fully rendered
    # canvas that should be displayed for every frame.
    #
    # The frames are rendered onto an output buffer that starts out fully
    # transparent. Every frame is rendered onto this buffer using its blend
    # operation, and the resulting canvas is yielded. Before moving on to the
    # next frame, the frame's dispose operation is applied to the buffer:
    #
    # * +APNG_DISPOSE_OP_NONE+: the buffer is left as is;
    # * +APNG_DISPOSE_OP_BACKGROUND+: the frame's region is cleared to fully
    #   transparent black;
    # * +APNG_DISPOSE_OP_PREVIOUS+: the frame's region is reverted to the
    #   contents it had before the frame was rendered.
    #
    # @yield [canvas] Yields the rendered canvas for every frame in order.
    # @yieldparam [ChunkyPNG::Canvas] canvas The canvas to display for a frame.
    # @return [ChunkyPNG::Animation, Enumerator] Returns an enumerator if no
    #   block is given, otherwise returns itself.
    def each_frame_canvas
      return enum_for(:each_frame_canvas) unless block_given?

      output = ChunkyPNG::Canvas.new(width, height, ChunkyPNG::Color::TRANSPARENT)
      frames.each do |frame|
        if frame.dispose_op == ChunkyPNG::APNG_DISPOSE_OP_PREVIOUS
          previous = output.crop(frame.x_offset, frame.y_offset, frame.width, frame.height)
        end

        case frame.blend_op
          when ChunkyPNG::APNG_BLEND_OP_SOURCE
            output.replace!(frame.canvas, frame.x_offset, frame.y_offset)
          when ChunkyPNG::APNG_BLEND_OP_OVER
            output.compose!(frame.canvas, frame.x_offset, frame.y_offset)
          else
            raise ChunkyPNG::NotSupported, "Unknown blend operation: #{frame.blend_op}!"
        end

        yield output.dup

        case frame.dispose_op
          when ChunkyPNG::APNG_DISPOSE_OP_NONE
            # The output buffer is left as is.
          when ChunkyPNG::APNG_DISPOSE_OP_BACKGROUND
            output.replace!(ChunkyPNG::Canvas.new(frame.width, frame.height), frame.x_offset, frame.y_offset)
          when ChunkyPNG::APNG_DISPOSE_OP_PREVIOUS
            output.replace!(previous, frame.x_offset, frame.y_offset)
          else
            raise ChunkyPNG::NotSupported, "Unknown dispose operation: #{frame.dispose_op}!"
        end
      end
      self
    end

    # Returns the fully rendered canvases that should be displayed for every
    # frame of the animation.
    # @return [Array<ChunkyPNG::Canvas>] The rendered canvas for every frame.
    # @see #each_frame_canvas
    def frame_canvases
      each_frame_canvas.to_a
    end

    # Returns the fully rendered canvas that should be displayed for the
    # frame at the given index.
    # @param [Integer] index The index of the frame, starting at 0.
    # @return [ChunkyPNG::Canvas] The rendered canvas for the frame.
    # @raise [ChunkyPNG::OutOfBounds] If the index is negative, or greater
    #   than or equal to the number of frames in the animation.
    # @see #each_frame_canvas
    def frame_canvas(index)
      unless index.is_a?(Integer) && index >= 0 && index < frame_count
        raise ChunkyPNG::OutOfBounds,
          "Frame index #{index.inspect} is out of bounds for an animation with #{frame_count} frames!"
      end
      each_frame_canvas.with_index { |canvas, i| return canvas if i == index }
    end

    ##############################################################################
    # SAVING ANIMATIONS
    ##############################################################################

    # Writes the animation to an IO stream, encoded as an animated PNG.
    # @param [IO] io The output stream to write to.
    # @param constraints (see ChunkyPNG::Animation#to_datastream)
    # @return [void]
    def write(io, constraints = {})
      to_datastream(constraints).write(io)
    end

    # Writes the animation to a file, encoded as an animated PNG.
    # @param [String] filename The file to save the animation to.
    # @param constraints (see ChunkyPNG::Animation#to_datastream)
    # @return [void]
    def save(filename, constraints = {})
      File.open(filename, "wb") { |io| write(io, constraints) }
    end

    # Encodes the animation to an APNG formatted string.
    # @param constraints (see ChunkyPNG::Animation#to_datastream)
    # @return [String] The APNG encoded animation as string.
    def to_blob(constraints = {})
      to_datastream(constraints).to_blob
    end

    alias to_string to_blob
    alias to_s to_blob

    # Converts this animation to a datastream, so that it can be saved as an
    # animated PNG image.
    #
    # If the animation has no separate {#default_image}, the first frame
    # doubles as the default image and is stored in the datastream's IDAT
    # chunks. In that case, the first frame is required to cover the entire
    # canvas. Otherwise, the default image is stored in the IDAT chunks and
    # all frames are stored in fdAT chunks.
    #
    # @param [Hash] constraints The constraints to use when encoding the
    #   animation.
    # @option constraints [Integer] :color_mode The color mode to use. Use
    #   one of the ChunkyPNG::COLOR_* constants. Defaults to
    #   {ChunkyPNG::COLOR_TRUECOLOR_ALPHA}.
    # @option constraints [Integer] :bit_depth The bit depth to use. Defaults
    #   to 8, or the minimal suitable bit depth for indexed images.
    # @option constraints [Integer] :compression The compression level for
    #   Zlib, between 0 and 9.
    # @option constraints [Integer] :filtering The filtering method to use.
    # @return [ChunkyPNG::Datastream] The datastream containing the encoded
    #   animation.
    # @raise [ChunkyPNG::ExpectationFailed] If the animation has no frames,
    #   if a frame does not fit on the canvas, or if the first frame does not
    #   cover the entire canvas while no default image is set.
    def to_datastream(constraints = {})
      raise ChunkyPNG::ExpectationFailed, "Cannot encode an animation without frames!" if frames.empty?

      encoding   = DEFAULT_ENCODING.merge(constraints)
      color_mode = encoding[:color_mode]
      bit_depth  = encoding[:bit_depth]
      interlace  = encoding[:interlace] || ChunkyPNG::INTERLACING_NONE
      unless interlace == ChunkyPNG::INTERLACING_NONE
        raise ChunkyPNG::NotSupported, "Interlaced animated PNGs are not supported!"
      end

      frames.each { |frame| assert_frame_bounds!(frame) }
      if default_image && (default_image.width != width || default_image.height != height)
        raise ChunkyPNG::ExpectationFailed,
          "The default image must have the same dimensions as the animation canvas!"
      end

      encoding_palette = nil
      if color_mode == ChunkyPNG::COLOR_INDEXED
        pixels = frames.flat_map { |frame| frame.canvas.pixels }
        pixels += default_image.pixels if default_image
        encoding_palette = ChunkyPNG::Palette.from_pixels(pixels)
        bit_depth ||= encoding_palette.determine_bit_depth
      end
      bit_depth ||= 8

      ds = ChunkyPNG::Datastream.new
      ds.header_chunk = ChunkyPNG::Chunk::Header.new(
        width: width, height: height,
        color: color_mode, depth: bit_depth, interlace: interlace
      )
      ds.animation_control_chunk = ChunkyPNG::Chunk::AnimationControl.new(
        num_frames: frames.length, num_plays: num_plays
      )
      ds.end_chunk = ChunkyPNG::Chunk::End.new
      if encoding_palette
        ds.palette_chunk = encoding_palette.to_plte_chunk
        ds.transparency_chunk = encoding_palette.to_trns_chunk unless encoding_palette.opaque?
      end

      sequence_number = 0
      frames.each_with_index do |frame, index|
        control = ChunkyPNG::Chunk::FrameControl.new(
          sequence_number: sequence_number,
          width: frame.width, height: frame.height,
          x_offset: frame.x_offset, y_offset: frame.y_offset,
          delay_num: frame.delay_num, delay_den: frame.delay_den,
          dispose_op: frame.dispose_op, blend_op: frame.blend_op
        )
        sequence_number += 1
        animation_frame = ChunkyPNG::Datastream::AnimationFrame.new(control)

        if index == 0 && default_image.nil?
          unless frame.x_offset == 0 && frame.y_offset == 0 &&
              frame.width == width && frame.height == height
            raise ChunkyPNG::ExpectationFailed,
              "The first frame must cover the entire canvas when the animation has no separate default image!"
          end
          animation_frame.uses_default_image = true
          ds.data_chunks = ChunkyPNG::Chunk::ImageData.split_in_chunks(
            encode_frame_stream(frame.canvas, color_mode, bit_depth, encoding[:filtering], encoding_palette),
            encoding[:compression]
          )
        else
          stream = encode_frame_stream(frame.canvas, color_mode, bit_depth, encoding[:filtering], encoding_palette)
          animation_frame.data_chunks << ChunkyPNG::Chunk::FrameData.from_pixelstream(
            sequence_number, stream, encoding[:compression]
          )
          sequence_number += 1
        end
        ds.animation_frames << animation_frame
      end

      if default_image
        ds.data_chunks = ChunkyPNG::Chunk::ImageData.split_in_chunks(
          encode_frame_stream(default_image, color_mode, bit_depth, encoding[:filtering], encoding_palette),
          encoding[:compression]
        )
      end

      ds
    end

    private

    # Validates that a frame's rectangle fits on the animation's canvas, and
    # that its dispose and blend operations are known.
    # @raise [ChunkyPNG::OutOfBounds] If the frame's rectangle does not fit
    #   on the animation's canvas.
    # @raise [ChunkyPNG::ExpectationFailed] If the frame uses unknown dispose
    #   or blend operations.
    def assert_frame_bounds!(frame)
      if frame.width == 0 || frame.height == 0
        raise ChunkyPNG::ExpectationFailed, "Frames cannot have an empty rectangle!"
      end
      if frame.x_offset < 0 || frame.y_offset < 0 ||
          frame.x_offset + frame.width > width || frame.y_offset + frame.height > height
        raise ChunkyPNG::OutOfBounds,
          "Frame rectangle #{frame.width}x#{frame.height} at #{frame.x_offset},#{frame.y_offset} does not fit on the #{width}x#{height} canvas!"
      end
      unless [ChunkyPNG::APNG_DISPOSE_OP_NONE, ChunkyPNG::APNG_DISPOSE_OP_BACKGROUND,
          ChunkyPNG::APNG_DISPOSE_OP_PREVIOUS].include?(frame.dispose_op)
        raise ChunkyPNG::ExpectationFailed, "Unknown dispose operation: #{frame.dispose_op}!"
      end
      unless [ChunkyPNG::APNG_BLEND_OP_SOURCE, ChunkyPNG::APNG_BLEND_OP_OVER].include?(frame.blend_op)
        raise ChunkyPNG::ExpectationFailed, "Unknown blend operation: #{frame.blend_op}!"
      end
    end

    # Encodes a single frame's canvas to a PNG pixelstream.
    # @return [String] The PNG encoded pixelstream for the frame.
    def encode_frame_stream(canvas, color_mode, bit_depth, filtering, encoding_palette)
      canvas = canvas.dup
      canvas.encoding_palette = encoding_palette if encoding_palette
      canvas.send(:encode_png_pixelstream, color_mode, bit_depth, ChunkyPNG::INTERLACING_NONE, filtering)
    end

    public

    # A single frame of an animated PNG (APNG): the image to render, the
    # rectangle on the output buffer to render it on, how long it should be
    # displayed, and how it should be rendered and disposed of.
    #
    # @see ChunkyPNG::Animation
    class Frame
      # The image to render for this frame. Its dimensions define the size
      # of the frame's rectangle on the output buffer.
      # @return [ChunkyPNG::Canvas]
      attr_accessor :canvas

      # The x-offset of the frame's rectangle on the output buffer.
      # @return [Integer]
      attr_accessor :x_offset

      # The y-offset of the frame's rectangle on the output buffer.
      # @return [Integer]
      attr_accessor :y_offset

      # The numerator of the frame's delay fraction.
      # @return [Integer]
      attr_accessor :delay_num

      # The denominator of the frame's delay fraction. A value of 0 is
      # treated as 100, as dictated by the APNG specification.
      # @return [Integer]
      attr_accessor :delay_den

      # The dispose operation for this frame: what should happen with the
      # frame's region on the output buffer before rendering the next frame.
      # One of the ChunkyPNG::APNG_DISPOSE_OP_* constants.
      # @return [Integer]
      attr_accessor :dispose_op

      # The blend operation for this frame: whether the frame's pixels
      # should replace the region on the output buffer, or be alpha
      # composited onto it. One of the ChunkyPNG::APNG_BLEND_OP_* constants.
      # @return [Integer]
      attr_accessor :blend_op

      # Initializes a new Frame instance.
      # @param [ChunkyPNG::Canvas] canvas The image to render for this frame.
      # @param [Integer] x_offset The x-offset of the frame on the output buffer.
      # @param [Integer] y_offset The y-offset of the frame on the output buffer.
      # @param [Integer] delay_num The numerator of the frame's delay fraction.
      # @param [Integer] delay_den The denominator of the frame's delay fraction.
      # @param [Integer] dispose_op The frame's dispose operation.
      # @param [Integer] blend_op The frame's blend operation.
      def initialize(canvas, x_offset: 0, y_offset: 0, delay_num: 1, delay_den: 10,
          dispose_op: ChunkyPNG::APNG_DISPOSE_OP_NONE, blend_op: ChunkyPNG::APNG_BLEND_OP_SOURCE)
        @canvas     = canvas
        @x_offset   = x_offset
        @y_offset   = y_offset
        @delay_num  = delay_num
        @delay_den  = delay_den
        @dispose_op = dispose_op
        @blend_op   = blend_op
      end

      # The width of the frame's rectangle in pixels.
      # @return [Integer]
      def width
        canvas.width
      end

      # The height of the frame's rectangle in pixels.
      # @return [Integer]
      def height
        canvas.height
      end

      # The number of seconds this frame should be displayed.
      #
      # A denominator of 0 is treated as 100, as dictated by the APNG
      # specification.
      # @return [Rational] The delay of the frame in seconds.
      def delay
        delay_num.to_r / (delay_den.nil? || delay_den == 0 ? 100 : delay_den)
      end

      # Sets the number of seconds this frame should be displayed.
      # @param [Numeric] seconds The delay of the frame in seconds.
      def delay=(seconds)
        self.delay_num = (seconds.to_r * 1000).round
        self.delay_den = 1000
      end
    end
  end
end
