# frozen-string-literal: true

module ChunkyPNG
  # Factory method to create a 16-bit RGBA color value.
  def self.Color16(*args) # rubocop:disable Naming/MethodName
    case args.length
      when 1 then Color16.parse(args.first)
      when 3 then Color16.rgb(*args)
      when 4 then Color16.rgba(*args)
      else raise ArgumentError, "Don't know how to create a 16-bit color from #{args.inspect}!"
    end
  end
  # rubocop:enable Naming/MethodName

  # 16-bit per channel RGBA color helpers. Colors are stored as 64-bit
  # integers: 16 bits each for red, green, blue and alpha.
  module Color16
    extend self

    # @return [Integer] Maximum value of one 16-bit color sample.
    MAX = 0xffff

    # @return [Integer] Fully transparent black in 16-bit RGBA encoding.
    TRANSPARENT = 0

    def parse(value)
      raise ArgumentError, "Don't know how to create a 16-bit color from #{value.inspect}!" unless value.is_a?(Integer)
      value
    end

    # Creates a 16-bit RGBA color.
    def rgba(r, g, b, a)
      r << 48 | g << 32 | b << 16 | a
    end

    # Creates an opaque 16-bit RGB color.
    def rgb(r, g, b)
      rgba(r, g, b, MAX)
    end

    # Creates an opaque 16-bit grayscale color.
    def grayscale(value)
      rgb(value, value, value)
    end

    # Creates a 16-bit grayscale color with alpha.
    def grayscale_alpha(value, a)
      rgba(value, value, value, a)
    end

    # Returns the red sample of a 16-bit RGBA color.
    def r(value)
      (value & 0xffff000000000000) >> 48
    end

    # Returns the green sample of a 16-bit RGBA color.
    def g(value)
      (value & 0x0000ffff00000000) >> 32
    end

    # Returns the blue sample of a 16-bit RGBA color.
    def b(value)
      (value & 0x00000000ffff0000) >> 16
    end

    # Returns the alpha sample of a 16-bit RGBA color.
    def a(value)
      value & 0x000000000000ffff
    end

    # Expands an 8-bit sample to 16 bits by duplicating it into both bytes.
    # For example, 0x01 becomes 0x0101 and 0xff becomes 0xffff.
    def from_8bit(value)
      (value << 8) | value
    end

    # Reduces a 16-bit sample to 8 bits using nearest-integer scaling.
    # Values whose scaled result is exactly x.5 round away from zero.
    def to_8bit(value)
      (value * 255 / 65535.0).round
    end

    # Converts an 8-bit RGBA color to a 16-bit RGBA color.
    def from_color(color)
      rgba(
        from_8bit(Color.r(color)),
        from_8bit(Color.g(color)),
        from_8bit(Color.b(color)),
        from_8bit(Color.a(color))
      )
    end

    # Converts a 16-bit RGBA color to an 8-bit RGBA color.
    def to_color(color)
      Color.rgba(
        to_8bit(r(color)),
        to_8bit(g(color)),
        to_8bit(b(color)),
        to_8bit(a(color))
      )
    end
  end
end
