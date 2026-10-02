# frozen-string-literal: true

module ChunkyPNG
  # A metadata-enabled 16-bit canvas.
  class Image16 < Canvas16
    METADATA_COMPRESSION_TRESHOLD = Image::METADATA_COMPRESSION_TRESHOLD

    attr_accessor :metadata

    def initialize(width, height, background_color = Color16::TRANSPARENT, metadata = {})
      super(width, height, background_color)
      @metadata = metadata
    end

    def initialize_copy(other)
      super(other)
      @metadata = other.metadata
    end

    def self.from_canvas(canvas, metadata = {})
      image = super(canvas)
      image.metadata = canvas.respond_to?(:metadata) ? canvas.metadata : metadata
      image
    end

    def metadata_chunks
      metadata.map do |key, value|
        if value.length >= METADATA_COMPRESSION_TRESHOLD
          Chunk::CompressedText.new(key, value)
        else
          Chunk::Text.new(key, value)
        end
      end
    end

    def to_datastream(constraints = {})
      ds = super(constraints)
      ds.other_chunks += metadata_chunks
      ds
    end

    def self.from_datastream(ds)
      image = super(ds)
      image.metadata = ds.metadata
      image
    end
  end
end
