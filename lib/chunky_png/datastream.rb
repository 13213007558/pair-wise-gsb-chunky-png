# frozen-string-literal: true

module ChunkyPNG
  # The Datastream class represents a PNG formatted datastream. It supports
  # both reading from and writing to strings, streams and files.
  #
  # A PNG datastream begins with the PNG signature, and then contains multiple
  # chunks, starting with a header (IHDR) chunk and finishing with an end
  # (IEND) chunk.
  #
  # @see ChunkyPNG::Chunk
  class Datastream
    # The signature that each PNG file or stream should begin with.
    SIGNATURE = [137, 80, 78, 71, 13, 10, 26, 10].pack("C8").force_encoding(::Encoding::BINARY).freeze

    # The header chunk of this datastream.
    # @return [ChunkyPNG::Chunk::Header]
    attr_accessor :header_chunk

    # All other chunks in this PNG file.
    # @return [Array<ChunkyPNG::Chunk::Generic>]
    attr_accessor :other_chunks

    # The chunk containing the image's palette.
    # @return [ChunkyPNG::Chunk::Palette]
    attr_accessor :palette_chunk

    # The chunk containing the transparency information of the palette.
    # @return [ChunkyPNG::Chunk::Transparency]
    attr_accessor :transparency_chunk

    # The chunk containing the physical dimensions of the PNG's pixels.
    # @return [ChunkyPNG::Chunk::Physical]
    attr_accessor :physical_chunk

    # The chunks that together compose the images pixel data.
    # @return [Array<ChunkyPNG::Chunk::ImageData>]
    attr_accessor :data_chunks

    # The Animation Control chunk, if this datastream is an animated PNG.
    # @return [ChunkyPNG::Chunk::AnimationControl, nil]
    attr_accessor :animation_chunk

    # The frame chunks of this animation as pairs of a
    # {ChunkyPNG::Chunk::FrameControl} chunk and the list of IDAT or fdAT
    # chunks that hold the frame's pixel data.
    #
    # If the default image is part of the animation, its frame is the first
    # entry in this list and its data chunks are regular IDAT chunks.
    #
    # @return [Array<Array(ChunkyPNG::Chunk::FrameControl, Array<ChunkyPNG::Chunk::Base>)>]
    attr_accessor :frame_chunks

    # The empty chunk that signals the end of this datastream
    # @return [ChunkyPNG::Chunk::Header]
    attr_accessor :end_chunk

    # Initializes a new Datastream instance.
    def initialize
      @other_chunks = []
      @data_chunks  = []
      @frame_chunks = []
    end

    ##############################################################################
    # LOADING DATASTREAMS
    ##############################################################################

    class << self
      # Reads a PNG datastream from a string.
      # @param [String] str The PNG encoded string to load from.
      # @return [ChunkyPNG::Datastream] The loaded datastream instance.
      def from_blob(str)
        from_io(StringIO.new(str, "rb"))
      end

      alias from_string from_blob

      # Reads a PNG datastream from a file.
      # @param [String] filename The path of the file to load from.
      # @return [ChunkyPNG::Datastream] The loaded datastream instance.
      def from_file(filename)
        ds = nil
        File.open(filename, "rb") { |f| ds = from_io(f) }
        ds
      end

      # Reads a PNG datastream from an input stream
      # @param [IO] io The stream to read from.
      # @return [ChunkyPNG::Datastream] The loaded datastream instance.
      def from_io(io)
        io.set_encoding(::Encoding::BINARY)
        verify_signature!(io)

        ds = new
        expected_sequence_number = 0
        default_image_frame = nil
        idat_seen = false
        while ds.end_chunk.nil?
          chunk = ChunkyPNG::Chunk.read(io)
          case chunk
            when ChunkyPNG::Chunk::Header       then ds.header_chunk = chunk
            when ChunkyPNG::Chunk::Palette      then ds.palette_chunk = chunk
            when ChunkyPNG::Chunk::Transparency then ds.transparency_chunk = chunk
            when ChunkyPNG::Chunk::Physical     then ds.physical_chunk = chunk
            when ChunkyPNG::Chunk::AnimationControl then ds.animation_chunk = chunk
            when ChunkyPNG::Chunk::FrameControl
              frame_number = ds.frame_chunks.length + 1
              begin
                chunk.validate!(ds.header_chunk.width, ds.header_chunk.height, first_frame: frame_number == 1 && !idat_seen)
              rescue ChunkyPNG::Exception => e
                raise ChunkyPNG::ExpectationFailed, "Invalid fcTL chunk for frame #{frame_number}: #{e.message}"
              end

              if chunk.sequence_number != expected_sequence_number && ds.animation_chunk
                raise ChunkyPNG::ExpectationFailed,
                  "Invalid sequence number #{chunk.sequence_number} for the fcTL chunk of frame #{frame_number}, expected #{expected_sequence_number}!"
              end
              expected_sequence_number += 1 if ds.animation_chunk

              frame = [chunk, []]
              ds.frame_chunks << frame
              # The default image is part of the animation only when its
              # fcTL chunk precedes the IDAT chunks.
              default_image_frame = frame if frame_number == 1 && !idat_seen
            when ChunkyPNG::Chunk::ImageData
              idat_seen = true
              ds.data_chunks << chunk
              default_image_frame[1] << chunk if default_image_frame
            when ChunkyPNG::Chunk::FrameData
              unless ds.animation_chunk
                raise ChunkyPNG::ExpectationFailed, "Found a fdAT chunk but no acTL chunk in this datastream!"
              end
              if chunk.sequence_number != expected_sequence_number
                raise ChunkyPNG::ExpectationFailed,
                  "Invalid fdAT sequence number #{chunk.sequence_number}, expected #{expected_sequence_number}!"
              end
              expected_sequence_number += 1
              raise ChunkyPNG::ExpectationFailed, "Found a fdAT chunk without a preceding fcTL chunk!" if ds.frame_chunks.empty?
              ds.frame_chunks.last[1] << chunk
            when ChunkyPNG::Chunk::End          then ds.end_chunk = chunk
            else ds.other_chunks << chunk
          end
        end

        if ds.animation_chunk && ds.frame_chunks.length != ds.animation_chunk.num_frames
          raise ChunkyPNG::ExpectationFailed,
            "The acTL chunk declares #{ds.animation_chunk.num_frames} frames but found #{ds.frame_chunks.length} fcTL chunks!"
        end
        ds
      end

      # Verifies that the current stream is a PNG datastream by checking its signature.
      #
      # This method reads the PNG signature from the stream, setting the current position
      # of the stream directly after the signature, where the IHDR chunk should begin.
      #
      # @param [IO] io The stream to read the PNG signature from.
      # @raise [RuntimeError] An exception is raised if the PNG signature is not found at
      #    the beginning of the stream.
      def verify_signature!(io)
        signature = io.read(ChunkyPNG::Datastream::SIGNATURE.length)
        unless signature == ChunkyPNG::Datastream::SIGNATURE
          raise ChunkyPNG::SignatureMismatch, "PNG signature not found, found #{signature.inspect} instead of #{ChunkyPNG::Datastream::SIGNATURE.inspect}!"
        end
      end
    end

    ##################################################################################
    # CHUNKS
    ##################################################################################

    # Enumerates the chunks in this datastream.
    #
    # This will iterate over the chunks using the order in which the chunks
    # should appear in the PNG file.
    #
    # @yield [chunk] Yields the chunks in this datastream, one by one in the correct order.
    # @yieldparam [ChunkyPNG::Chunk::Base] chunk A chunk in this datastream.
    # @see ChunkyPNG::Datastream#chunks
    def each_chunk
      return each_animated_chunk { |chunk| yield(chunk) } if animated?

      yield(header_chunk)
      other_chunks.each { |chunk| yield(chunk) }
      yield(palette_chunk)      if palette_chunk
      yield(transparency_chunk) if transparency_chunk
      yield(physical_chunk)     if physical_chunk
      data_chunks.each { |chunk| yield(chunk) }
      yield(end_chunk)
    end

    # Enumerates the chunks of an animated datastream in the order required by
    # the APNG specification: IHDR, acTL, other chunks, PLTE/tRNS, the default
    # image IDATs (with the first frame's fcTL when applicable), and the
    # remaining frames as fcTL/fdAT groups.
    #
    # @yield [chunk] Yields the chunks in this datastream in APNG order.
    def each_animated_chunk
      yield(header_chunk)
      yield(animation_chunk)
      other_chunks.each { |chunk| yield(chunk) }
      yield(palette_chunk)      if palette_chunk
      yield(transparency_chunk) if transparency_chunk
      yield(physical_chunk)     if physical_chunk

      first_control, first_data = frame_chunks.first
      first_uses_idat = !first_data.empty? && first_data.first.is_a?(ChunkyPNG::Chunk::ImageData)

      if first_uses_idat
        yield(first_control)
        first_data.each { |chunk| yield(chunk) }
        remaining_frames = frame_chunks[1..-1] || []
      else
        data_chunks.each { |chunk| yield(chunk) }
        remaining_frames = frame_chunks
      end

      remaining_frames.each do |control, chunks|
        yield(control)
        chunks.each { |chunk| yield(chunk) }
      end

      yield(end_chunk)
    end

    # @return [true, false] Whether this datastream contains animation data.
    def animated?
      !animation_chunk.nil?
    end

    # Returns an enumerator instance for this datastream's chunks.
    # @return [Enumerable::Enumerator] An enumerator for the :each_chunk method.
    # @see ChunkyPNG::Datastream#each_chunk
    def chunks
      enum_for(:each_chunk)
    end

    # Returns all the textual metadata key/value pairs as hash.
    # @return [Hash] A hash containing metadata fields and their values.
    def metadata
      metadata = {}
      other_chunks.each do |chunk|
        metadata[chunk.keyword] = chunk.value if chunk.respond_to?(:keyword) && chunk.respond_to?(:value)
      end
      metadata
    end

    # Returns the uncompressed image data, combined from all the IDAT chunks
    # @return [String] The uncompressed image data for this datastream
    def imagedata
      ChunkyPNG::Chunk::ImageData.combine_chunks(data_chunks)
    end

    # Returns the uncompressed pixel data for a given frame, combining and
    # inflating its IDAT or fdAT chunks.
    # @param frame_index [Integer] The zero-based index of the frame.
    # @return [String] The uncompressed pixel data for the frame.
    def frame_imagedata(frame_index)
      _control, chunks = frame_chunks.fetch(frame_index)
      image_data, frame_data = chunks.partition { |chunk| chunk.is_a?(ChunkyPNG::Chunk::ImageData) }
      if frame_data.empty?
        ChunkyPNG::Chunk::ImageData.combine_chunks(image_data)
      else
        ChunkyPNG::Chunk::FrameData.combine_chunks(frame_data)
      end
    end

    ##################################################################################
    # WRITING DATASTREAMS
    ##################################################################################

    # Writes the datastream to the given output stream.
    # @param [IO] io The output stream to write to.
    def write(io)
      io << SIGNATURE
      each_chunk { |c| c.write(io) }
    end

    # Saves this datastream as a PNG file.
    # @param [String] filename The filename to use.
    def save(filename)
      File.open(filename, "wb") { |f| write(f) }
    end

    # Encodes this datastream into a string.
    # @return [String] The encoded PNG datastream.
    def to_blob
      str = StringIO.new
      str.set_encoding("ASCII-8BIT")
      write(str)
      str.string
    end

    alias to_string to_blob
    alias to_s to_blob
  end
end
