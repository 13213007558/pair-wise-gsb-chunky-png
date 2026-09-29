# frozen_string_literal: true

module ChunkyPNG
  # Metadata-enabled {ChunkyPNG::Canvas16} equivalent of {ChunkyPNG::Image}.
  class Image16 < Canvas16
    METADATA_COMPRESSION_TRESHOLD = 300

    attr_accessor :metadata

    def initialize(width, height, bg_color = Color16::TRANSPARENT, metadata = {})
      super(width, height, bg_color)
      @metadata = metadata
    end

    def initialize_copy(other)
      super(other)
      @metadata = other.metadata
    end

    def metadata_chunks
      metadata.map do |key, value|
        if value.length >= METADATA_COMPRESSION_TRESHOLD
          ChunkyPNG::Chunk::CompressedText.new(key, value)
        else
          ChunkyPNG::Chunk::Text.new(key, value)
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
