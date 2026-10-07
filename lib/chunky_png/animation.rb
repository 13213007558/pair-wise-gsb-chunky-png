# frozen-string-literal: true

module ChunkyPNG
  # The Animation class represents an animated PNG (APNG) image: a sequence
  # of frames that are rendered onto a shared output canvas, each with its
  # own position, size, display delay and dispose/blend operations.
  #
  # An animation can be loaded from a PNG datastream that contains an
  # animation control (acTL) chunk, and can be encoded back into such a
  # datastream. The raw frames only contain the pixels of their own
  # rectangular region; use {#display_frames} to get the fully rendered
  # output canvas for every frame.
  #
  # @see ChunkyPNG::Animation::Frame
  # @see https://wiki.mozilla.org/APNG_Specification
  class Animation
    # Dispose operation: leave the output buffer as it was rendered.
    DISPOSE_OP_NONE = 0

    # Dispose operation: clear the frame's region to fully transparent
    # black before rendering the next frame.
    DISPOSE_OP_BACKGROUND = 1

    # Dispose operation: restore the frame's region to the content it had
    # before the frame was rendered, i.e. to the output of the frame before
    # the previous one.
    DISPOSE_OP_PREVIOUS = 2

    # Blend operation: overwrite the region with the frame's pixels,
    # including fully transparent pixels.
    BLEND_OP_SOURCE = 0

    # Blend operation: alpha-compose the frame's pixels over the current
    # content of the output canvas.
    BLEND_OP_OVER = 1

    # @return [Integer] The width of the animation's output canvas.
    attr_reader :width

    # @return [Integer] The height of the animation's output canvas.
    attr_reader :height

    # @return [Integer] The number of times the animation should be played.
    #   A value of 0 means the animation loops indefinitely.
    attr_accessor :loop_count

    # @return [ChunkyPNG::Canvas, nil] The default image of the animation,
    #   which is shown by renderers that do not support APNG. This image is
    #   not part of the animation itself. Returns nil if the first frame of
    #   the animation doubles as the default image.
    attr_accessor :default_image

    # @return [Array<ChunkyPNG::Animation::Frame>] The frames of this
    #   animation, in display order.
    attr_reader :frames

    # Initializes a new Animation instance.
    # @param [Integer] width The width of the animation's output canvas.
    # @param [Integer] height The height of the animation's output canvas.
    # @param [Integer] loop_count The number of times the animation should
    #   be played; 0 loops indefinitely.
    def initialize(width, height, loop_count: 0)
      @width = width
      @height = height
      @loop_count = loop_count
      @frames = []
    end

    # Adds a frame to the end of this animation.
    #
    # @param [ChunkyPNG::Animation::Frame, ChunkyPNG::Canvas] frame_or_canvas
    #   The frame to add, or a canvas to build a frame from using the
    #   provided attributes.
    # @param [Hash] attributes The attributes for the frame, if a canvas is
    #   provided.
    # @return [ChunkyPNG::Animation::Frame] The frame that was added.
    # @raise [ChunkyPNG::OutOfBounds] If the frame's region does not fit on
    #   the animation's output canvas.
    def add_frame(frame_or_canvas, **attributes)
      frame = frame_or_canvas.is_a?(Frame) ? frame_or_canvas : Frame.new(frame_or_canvas, **attributes)
      validate_frame!(frame)
      @frames << frame
      frame
    end

    # Returns the number of frames in this animation.
    # @return [Integer] The number of frames.
    def frame_count
      frames.length
    end

    # Renders every frame of the animation onto the output canvas, applying
    # each frame's blend operation, and applying the dispose operations
    # between frames.
    #
    # @return [Array<ChunkyPNG::Canvas>] The fully rendered output canvas
    #   for every frame of the animation, in display order.
    def display_frames
      output = ChunkyPNG::Canvas.new(width, height, ChunkyPNG::Color::TRANSPARENT)
      previous_frame = nil
      snapshot = nil

      frames.map do |frame|
        if previous_frame
          case previous_frame.dispose_op
          when DISPOSE_OP_BACKGROUND
            clear_region!(output, previous_frame)
          when DISPOSE_OP_PREVIOUS
            restore_region!(output, previous_frame, snapshot)
          end
        end

        snapshot = save_region(output, frame) if frame.dispose_op == DISPOSE_OP_PREVIOUS

        case frame.blend_op
        when BLEND_OP_SOURCE then output.replace!(frame.canvas, frame.x_offset, frame.y_offset)
        when BLEND_OP_OVER   then output.compose!(frame.canvas, frame.x_offset, frame.y_offset)
        end

        previous_frame = frame
        ChunkyPNG::Canvas.from_canvas(output)
      end
    end

    ########################################################################
    # READING
    ########################################################################

    class << self
      # Reads an animation from an APNG encoded string.
      # @param [String] str The string to read from.
      # @return [ChunkyPNG::Animation] The decoded animation.
      def from_blob(str)
        from_io(StringIO.new(str, "rb"))
      end

      alias from_string from_blob

      # Reads an animation from an APNG encoded file.
      # @param [String] filename The file to read from.
      # @return [ChunkyPNG::Animation] The decoded animation.
      def from_file(filename)
        animation = nil
        File.open(filename, "rb") { |f| animation = from_io(f) }
        animation
      end

      # Reads an animation from an APNG encoded stream.
      # @param [IO, #read] io The stream to read from.
      # @return [ChunkyPNG::Animation] The decoded animation.
      # @raise [ChunkyPNG::ExpectationFailed] If the stream is not an
      #   animated PNG, or if its structure is invalid.
      def from_io(io)
        io.set_encoding(::Encoding::BINARY)
        ChunkyPNG::Datastream.verify_signature!(io)

        reader = StreamReader.new
        reader.read(io)
        reader.to_animation
      end

      alias from_stream from_io
    end

    ########################################################################
    # WRITING
    ########################################################################

    # Encodes the animation as an APNG formatted string.
    # @param [Hash] constraints The encoding constraints.
    # @option constraints [Integer] :color_mode The color mode to encode the
    #   frames with. Defaults to 8-bit truecolor with alpha. Indexed color
    #   mode is not supported for animations.
    # @option constraints [Integer] :compression The Zlib compression level.
    # @return [String] The APNG encoded animation as string.
    def to_blob(constraints = {})
      stream = StringIO.new
      stream.set_encoding("ASCII-8BIT")
      write(stream, constraints)
      stream.string
    end

    alias to_string to_blob
    alias to_s to_blob

    # Saves the animation as an APNG file.
    # @param [String] filename The filename to use.
    # @param [Hash] constraints The constraints to use when encoding.
    # @return [void]
    # @see #to_blob
    def save(filename, constraints = {})
      File.open(filename, "wb") { |io| write(io, constraints) }
    end

    # Writes the APNG encoded animation to an output stream.
    # @param [IO] io The output stream to write to.
    # @param [Hash] constraints The constraints to use when encoding.
    # @return [void]
    # @see #to_blob
    def write(io, constraints = {})
      raise ChunkyPNG::ExpectationFailed, "Cannot encode an animation without frames!" if frames.empty?

      encoding = determine_animation_encoding(constraints)

      io << ChunkyPNG::Datastream::SIGNATURE
      header_chunk(encoding).write(io)
      ChunkyPNG::Chunk::AnimationControl.new(num_frames: frames.length, num_plays: loop_count).write(io)

      sequence_number = 0
      if default_image
        encode_image_data(default_image, encoding).each { |chunk| chunk.write(io) }
      end

      frames.each_with_index do |frame, index|
        validate_frame!(frame)
        as_default_image = default_image.nil? && index.zero?
        sequence_number = write_frame(io, frame, encoding, sequence_number, as_default_image)
      end

      ChunkyPNG::Chunk::End.new.write(io)
      io
    end

    private

    # Validates that a frame's region fits on this animation's canvas and
    # that its dispose and blend operations are valid.
    # @param [ChunkyPNG::Animation::Frame] frame The frame to validate.
    # @raise [ChunkyPNG::OutOfBounds] If the frame's region does not fit on
    #   the animation's output canvas.
    # @raise [ChunkyPNG::ExpectationFailed] If the frame's dispose or blend
    #   operation is invalid.
    def validate_frame!(frame)
      if frame.width <= 0 || frame.height <= 0 ||
          frame.x_offset < 0 || frame.y_offset < 0 ||
          frame.x_offset + frame.width > width ||
          frame.y_offset + frame.height > height
        raise ChunkyPNG::OutOfBounds,
          "Frame region #{frame.width}x#{frame.height} at (#{frame.x_offset}, #{frame.y_offset}) " +          "does not fit on the #{width}x#{height} animation canvas!"
      end

      unless (DISPOSE_OP_NONE..DISPOSE_OP_PREVIOUS).cover?(frame.dispose_op)
        raise ChunkyPNG::ExpectationFailed, "Invalid dispose operation: #{frame.dispose_op.inspect}!"
      end

      unless (BLEND_OP_SOURCE..BLEND_OP_OVER).cover?(frame.blend_op)
        raise ChunkyPNG::ExpectationFailed, "Invalid blend operation: #{frame.blend_op.inspect}!"
      end
    end

    # Clears the region of the given frame on the output canvas to fully
    # transparent black.
    def clear_region!(output, frame)
      for y in 0...frame.height
        for x in 0...frame.width
          output.set_pixel(frame.x_offset + x, frame.y_offset + y, ChunkyPNG::Color::TRANSPARENT)
        end
      end
    end

    # Saves the pixels of the frame's region on the output canvas, so they
    # can be restored later to implement the previous dispose operation.
    # @return [Array<Integer>] The saved pixel values.
    def save_region(output, frame)
      pixels = []
      for y in 0...frame.height
        for x in 0...frame.width
          pixels << output.get_pixel(frame.x_offset + x, frame.y_offset + y)
        end
      end
      pixels
    end

    # Restores the frame's region on the output canvas to the given pixels,
    # which were saved before the frame was rendered.
    def restore_region!(output, frame, pixels)
      for y in 0...frame.height
        for x in 0...frame.width
          output.set_pixel(frame.x_offset + x, frame.y_offset + y, pixels[y * frame.width + x])
        end
      end
    end

    # Determines the encoding variables to use for all frames of the
    # animation, so that every frame is encoded consistently.
    # @param [Hash] constraints The constraints provided by the caller.
    # @return [Hash] The encoding variables.
    def determine_animation_encoding(constraints)
      encoding = {
        color_mode: ChunkyPNG::COLOR_TRUECOLOR_ALPHA,
        bit_depth: 8,
        interlace: ChunkyPNG::INTERLACING_NONE,
        compression: Zlib::DEFAULT_COMPRESSION,
        filtering: ChunkyPNG::FILTER_NONE,
      }.merge(constraints)

      if encoding[:color_mode] == ChunkyPNG::COLOR_INDEXED
        raise ChunkyPNG::NotSupported, "Indexed color mode is not supported for animations!"
      end
      unless encoding[:bit_depth] == 8
        raise ChunkyPNG::NotSupported, "Only 8-bit color depth is supported for animations!"
      end
      unless encoding[:interlace] == ChunkyPNG::INTERLACING_NONE
        raise ChunkyPNG::NotSupported, "Interlacing is not supported for animations!"
      end
      encoding
    end

    # Builds the header chunk for this animation.
    # @return [ChunkyPNG::Chunk::Header] The header chunk.
    def header_chunk(encoding)
      ChunkyPNG::Chunk::Header.new(
        width: width,
        height: height,
        color: encoding[:color_mode],
        depth: encoding[:bit_depth],
        interlace: encoding[:interlace]
      )
    end

    # Encodes a canvas into a list of image data chunks, using the
    # animation's encoding.
    # @return [Array<ChunkyPNG::Chunk::ImageData>] The image data chunks.
    def encode_image_data(canvas, encoding)
      pixelstream = canvas.send(
        :encode_png_pixelstream,
        encoding[:color_mode],
        encoding[:bit_depth],
        encoding[:interlace],
        encoding[:filtering]
      )
      ChunkyPNG::Chunk::ImageData.split_in_chunks(pixelstream, encoding[:compression])
    end

    # Writes a single frame to the output stream: a frame control chunk,
    # followed by the frame's image data.
    #
    # @param [IO] io The output stream to write to.
    # @param [ChunkyPNG::Animation::Frame] frame The frame to write.
    # @param [Hash] encoding The encoding variables for the animation.
    # @param [Integer] sequence_number The next sequence number to use.
    # @param [Boolean] as_default_image Whether the frame's data should be
    #   written as IDAT chunks, making the frame double as the PNG's default
    #   image. Otherwise, the data is written as fdAT chunks.
    # @return [Integer] The next available sequence number.
    def write_frame(io, frame, encoding, sequence_number, as_default_image)
      ChunkyPNG::Chunk::FrameControl.new(
        sequence_number: sequence_number,
        width: frame.width,
        height: frame.height,
        x_offset: frame.x_offset,
        y_offset: frame.y_offset,
        delay_num: frame.delay_num,
        delay_den: frame.delay_den,
        dispose_op: frame.dispose_op,
        blend_op: frame.blend_op
      ).write(io)
      sequence_number += 1

      encode_image_data(frame.canvas, encoding).each do |chunk|
        if as_default_image
          chunk.write(io)
        else
          ChunkyPNG::Chunk::FrameData.new(sequence_number: sequence_number, data: chunk.content).write(io)
          sequence_number += 1
        end
      end
      sequence_number
    end
  end
end

require "chunky_png/animation/frame"
require "chunky_png/animation/stream_reader"
