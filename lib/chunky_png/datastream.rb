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

    # The empty chunk that signals the end of this datastream
    # @return [ChunkyPNG::Chunk::Header]
    attr_accessor :end_chunk

    # Initializes a new Datastream instance.
    def initialize
      @other_chunks = []
      @data_chunks  = []
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
        while ds.end_chunk.nil?
          chunk = ChunkyPNG::Chunk.read(io)
          case chunk
            when ChunkyPNG::Chunk::Header       then ds.header_chunk = chunk
            when ChunkyPNG::Chunk::Palette      then ds.palette_chunk = chunk
            when ChunkyPNG::Chunk::Transparency then ds.transparency_chunk = chunk
            when ChunkyPNG::Chunk::ImageData    then ds.data_chunks << chunk
            when ChunkyPNG::Chunk::Physical     then ds.physical_chunk = chunk
            when ChunkyPNG::Chunk::End          then ds.end_chunk = chunk
            else ds.other_chunks << chunk
          end
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
      yield(header_chunk)
      other_chunks.each { |chunk| yield(chunk) }
      yield(palette_chunk)      if palette_chunk
      yield(transparency_chunk) if transparency_chunk
      yield(physical_chunk)     if physical_chunk
      data_chunks.each { |chunk| yield(chunk) }
      yield(end_chunk)
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

    # Returns the color profile represented by the sRGB, gAMA and cHRM chunks.
    #
    # @option policy [Symbol] :missing (`:assume_srgb`) Use `:raise` to reject
    #   datastreams with incomplete color profile metadata.
    # @option policy [Symbol] :conflict (`:raise`) Use `:prefer_first` or
    #   `:prefer_srgb` to resolve duplicate or disagreeing profile chunks.
    # @option policy [Symbol] :invalid_white (`:raise`) Use `:assume_srgb` or
    #   `:ignore_chrm` to recover from an invalid cHRM white point.
    def color_profile(policy = {})
      policy = color_profile_policy(policy)
      srgb_chunks = other_chunks.select { |chunk| chunk.is_a?(ChunkyPNG::Chunk::SRGB) }
      gamma_chunks = other_chunks.select { |chunk| chunk.is_a?(ChunkyPNG::Chunk::Gamma) }
      chrm_chunks = other_chunks.select { |chunk| chunk.is_a?(ChunkyPNG::Chunk::Chromaticities) }
      profile_chunks = srgb_chunks + gamma_chunks + chrm_chunks

      if profile_chunks.empty?
        handle_missing_profile(policy[:missing])
      elsif srgb_chunks.length > 1 || gamma_chunks.length > 1 || chrm_chunks.length > 1
        handle_profile_conflict(policy[:conflict], srgb_chunks, gamma_chunks, chrm_chunks, policy)
      else
        build_color_profile(srgb_chunks.first, gamma_chunks.first, chrm_chunks.first, policy)
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

    private

    def color_profile_policy(policy)
      {
        missing: ChunkyPNG::ColorProfile::DEFAULT_MISSING_POLICY,
        conflict: ChunkyPNG::ColorProfile::DEFAULT_CONFLICT_POLICY,
        invalid_white: ChunkyPNG::ColorProfile::DEFAULT_INVALID_WHITE_POLICY,
      }.merge(policy)
    end

    def handle_missing_profile(option)
      case option
        when :assume_srgb then ChunkyPNG::ColorProfile.srgb(explicit: false)
        when :raise then raise ChunkyPNG::MissingColorProfile, "PNG has no sRGB, gAMA or cHRM chunk."
        else raise ArgumentError, "Unknown missing color profile policy: #{option.inspect}."
      end
    end

    def handle_profile_conflict(option, srgb_chunks, gamma_chunks, chrm_chunks, policy)
      case option
        when :raise
          raise ChunkyPNG::ExpectationFailed, "Duplicate PNG color profile chunks were found."
        when :prefer_first
          first_color_chunk = other_chunks.find { |chunk| color_profile_chunk?(chunk) }
          first_srgb = first_color_chunk if first_color_chunk.is_a?(ChunkyPNG::Chunk::SRGB)
          first_gamma = first_color_chunk if first_color_chunk.is_a?(ChunkyPNG::Chunk::Gamma)
          first_chrm = first_color_chunk if first_color_chunk.is_a?(ChunkyPNG::Chunk::Chromaticities)
          build_color_profile(
            first_srgb,
            first_gamma,
            first_chrm,
            policy.merge(conflict: option)
          )
        when :prefer_srgb
          if srgb_chunks.any?
            ChunkyPNG::ColorProfile.srgb
          else
            build_color_profile(nil, gamma_chunks.first, chrm_chunks.first, policy.merge(conflict: option))
          end
        else raise ArgumentError, "Unknown color profile conflict policy: #{option.inspect}."
      end
    end

    def color_profile_chunk?(chunk)
      chunk.is_a?(ChunkyPNG::Chunk::SRGB) ||
        chunk.is_a?(ChunkyPNG::Chunk::Gamma) ||
        chunk.is_a?(ChunkyPNG::Chunk::Chromaticities)
    end

    def build_color_profile(srgb_chunk, gamma_chunk, chrm_chunk, policy)
      if srgb_chunk
        profile = ChunkyPNG::ColorProfile.srgb
        compatible = if gamma_chunk && chrm_chunk
          gamma_chunk.gamma == 45_455 &&
            chrm_chunk.to_profile_chromaticities == ChunkyPNG::ColorProfile::Chromaticities.srgb
        elsif gamma_chunk
          gamma_chunk.gamma == 45_455
        elsif chrm_chunk
          chrm_chunk.to_profile_chromaticities == ChunkyPNG::ColorProfile::Chromaticities.srgb
        else
          true
        end
        unless compatible
          case policy[:conflict]
            when :raise then raise ChunkyPNG::ExpectationFailed, "PNG color profile chunks disagree."
            when :prefer_first
              if gamma_chunk
                return ChunkyPNG::ColorProfile.custom(
                  gamma: Rational(100_000, gamma_chunk.gamma),
                  chromaticities: chrm_chunk ? chrm_chunk.to_profile_chromaticities : srgb_chromaticities
                )
              end
              profile = ChunkyPNG::ColorProfile.custom(
                gamma: ChunkyPNG::ColorProfile::SRGB_GAMMA,
                chromaticities: chrm_chunk.to_profile_chromaticities
              ) if chrm_chunk
              profile
            when :prefer_srgb then return profile
            else raise ArgumentError, "Unknown color profile conflict policy: #{policy[:conflict].inspect}."
          end
        end
        profile
      elsif gamma_chunk && chrm_chunk
        custom_color_profile(gamma_chunk, chrm_chunk, policy)
      else
        handle_partial_custom_profile(gamma_chunk, chrm_chunk, policy[:missing])
      end
    end

    def srgb_chromaticities
      ChunkyPNG::ColorProfile::Chromaticities.srgb
    end

    def custom_color_profile(gamma_chunk, chrm_chunk, policy)
      ChunkyPNG::ColorProfile.custom(
        gamma: Rational(100_000, gamma_chunk.gamma),
        chromaticities: chrm_chunk.to_profile_chromaticities
      )
    rescue ChunkyPNG::ColorProfile::InvalidColorSpace
      handle_invalid_white(gamma_chunk, chrm_chunk, policy[:invalid_white])
    end

    def handle_partial_custom_profile(gamma_chunk, chrm_chunk, option)
      case option
        when :assume_srgb, :fill_srgb_defaults
          ChunkyPNG::ColorProfile.srgb(explicit: false)
        when :raise
          raise ChunkyPNG::ExpectationFailed, "A custom PNG color profile requires both gAMA and cHRM chunks."
        else raise ArgumentError, "Unknown missing color profile policy: #{option.inspect}."
      end
    rescue ChunkyPNG::ColorProfile::InvalidColorSpace
      handle_invalid_white(gamma_chunk, chrm_chunk, option)
    end

    def handle_invalid_white(gamma_chunk, chrm_chunk, option)
      case option
        when :raise
          raise
        when :assume_srgb
          ChunkyPNG::ColorProfile.srgb(explicit: false)
        when :ignore_chrm
          gamma = gamma_chunk ? Rational(100_000, gamma_chunk.gamma) : ChunkyPNG::ColorProfile::SRGB_GAMMA
          ChunkyPNG::ColorProfile.custom(gamma: gamma, chromaticities: ChunkyPNG::ColorProfile::Chromaticities.srgb)
        else raise ArgumentError, "Unknown invalid white point policy: #{option.inspect}."
      end
    end
  end
end
