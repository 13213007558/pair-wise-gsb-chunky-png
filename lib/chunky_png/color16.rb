# frozen_string-literal: true

module ChunkyPNG
  # Factory method to create a 16-bit RGBA color value.
  def self.Color16(*args) # rubocop:disable Naming/MethodName
    case args.length
      when 1 then args.first
      when 3 then Color16.rgb(*args)
      when 4 then Color16.rgba(*args)
      else raise ArgumentError, "Don't know how to create a 16-bit color from #{args.inspect}!"
    end
  end

  # 16-bit per channel RGBA colors. Pixels are stored as four 16-bit samples in
  # one integer: R in bits 48..63, G in 32..47, B in 16..31 and A in 0..15.
  module Color16
    extend self

    MAX = 0xffff
    SCALE_BITS = 8

    def rgba(r, g, b, a)
      r << 48 | g << 32 | b << 16 | a
    end

    def rgb(r, g, b)
      rgba(r, g, b, MAX)
    end

    def grayscale(value)
      rgb(value, value, value)
    end

    def grayscale_alpha(value, alpha)
      rgba(value, value, value, alpha)
    end

    BLACK = rgb(0, 0, 0)
    WHITE = rgb(MAX, MAX, MAX)
    TRANSPARENT = rgba(0, 0, 0, 0)

    def r(value)
      (value >> 48) & MAX
    end

    def g(value)
      (value >> 32) & MAX
    end

    def b(value)
      (value >> 16) & MAX
    end

    def a(value)
      value & MAX
    end

    def to_truecolor_alpha_bytes(color)
      [r(color), g(color), b(color), a(color)]
    end

    def to_truecolor_bytes(color)
      [r(color), g(color), b(color)]
    end

    def to_grayscale_alpha_bytes(color)
      [r(color), a(color)]
    end

    def to_grayscale_bytes(color)
      [r(color)]
    end

    # Scales an 8-bit sample to 16 bits using PNG's bit replication rule.
    def from_8bit(value)
      (value << SCALE_BITS) | value
    end

    # Scales a 16-bit sample linearly to 8 bits using round-to-nearest.
    # Use #to_8bit_truncated for the library's legacy high-byte rule.
    def to_8bit(value)
      (value * 0xff + 0x7fff) / 0xffff
    end

    # Legacy 16-to-8-bit conversion used while decoding 16-bit PNGs into the
    # original 8-bit Canvas API.
    def to_8bit_truncated(value)
      value >> SCALE_BITS
    end

    alias from_8bit_sample from_8bit
    alias to_8bit_sample to_8bit
    alias to_8bit_sample_truncated to_8bit_truncated
    alias upscale_8bit from_8bit
    alias downscale_16bit to_8bit
    alias downscale_16bit_truncated to_8bit_truncated

    def from_color(color)
      rgba(
        from_8bit(Color.r(color)),
        from_8bit(Color.g(color)),
        from_8bit(Color.b(color)),
        from_8bit(Color.a(color)),
      )
    end

    def to_color(color, rounding = :nearest)
      converter = case rounding
        when :nearest, :round then method(:to_8bit)
        when :truncate, :high_byte then method(:to_8bit_truncated)
        else raise ArgumentError, "Unknown rounding mode: #{rounding.inspect}!"
      end

      Color.rgba(*to_truecolor_alpha_bytes(color).map { |sample| converter.call(sample) })
    end
  end
end
