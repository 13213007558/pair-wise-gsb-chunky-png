# frozen_string_literal: true

module ChunkyPNG
  # 16-bit-per-channel RGBA colors represented as 64-bit integers. These
  # values are intentionally distinct from the 32-bit values handled by
  # {ChunkyPNG::Color}.
  module Color16
    extend self

    MAX = 0xffff
    BLACK = 0x0000000000000000
    WHITE = 0xffffffffffffffff
    TRANSPARENT = 0x0000000000000000

    def rgba(r, g, b, a)
      r << 48 | g << 32 | b << 16 | a
    end

    def rgb(r, g, b)
      rgba(r, g, b, MAX)
    end

    def grayscale(value)
      rgb(value, value, value)
    end

    def grayscale_alpha(value, a)
      rgba(value, value, value, a)
    end

    def r(color)
      (color >> 48) & MAX
    end

    def g(color)
      (color >> 32) & MAX
    end

    def b(color)
      (color >> 16) & MAX
    end

    def a(color)
      color & MAX
    end

    def to_truecolor_alpha_bytes(color)
      [r(color), g(color), b(color), a(color)]
    end

    def to_truecolor_bytes(color)
      [r(color), g(color), b(color)]
    end

    def to_grayscale_bytes(color)
      [r(color)]
    end

    def to_grayscale_alpha_bytes(color)
      [r(color), a(color)]
    end

    def from_color(color)
      rgba(
        ChunkyPNG::Color.r(color) * 257,
        ChunkyPNG::Color.g(color) * 257,
        ChunkyPNG::Color.b(color) * 257,
        ChunkyPNG::Color.a(color) * 257,
      )
    end

    def to_color(color, rounding = :truncate)
      r, g, b, a = to_truecolor_alpha_bytes(color)
      ChunkyPNG::Color.rgba(
        downsample(r, rounding),
        downsample(g, rounding),
        downsample(b, rounding),
        downsample(a, rounding),
      )
    end

    def downsample(value, rounding = :truncate)
      case rounding
      when :truncate, :floor
        value >> 8
      when :round, :nearest
        (value + 128) / 257
      else
        raise ArgumentError, "Unknown 16-bit rounding rule: #{rounding.inspect}"
      end
    end

    def to_hex(color)
      "#%016x" % color
    end
  end
end
