# frozen-string-literal: true

require "chunky_png/canvas/png16_encoding"
require "chunky_png/canvas/png16_decoding"

module ChunkyPNG
  # A raster canvas that preserves 16 bits per PNG sample. Its pixels are
  # {ChunkyPNG::Color16} integers. Unlike Canvas, no implicit 8-bit color
  # conversion is performed.
  class Canvas16 < Canvas
    include PNG16Encoding
    extend PNG16Decoding

    class << self
      alias from_blob16 from_blob
      alias from_string16 from_string
      alias from_file16 from_file
      alias from_io16 from_io
      alias from_stream16 from_stream
    end

    def initialize(width, height, initial = Color16::TRANSPARENT)
      if initial.is_a?(Array)
        super(width, height, initial)
      else
        @width, @height = width, height
        @pixels = Array.new(width * height, initial)
      end
    end

    def []=(x, y, color)
      assert_xy!(x, y)
      @pixels[y * width + x] = color
    end

    def self.from_canvas(canvas)
      pixels = canvas.pixels.map { |color| Color16.from_color(color) }
      new(canvas.width, canvas.height, pixels)
    end

    def to_canvas(rounding = :nearest)
      pixels = @pixels.map { |color| Color16.to_color(color, rounding) }
      Canvas.new(width, height, pixels)
    end

    def to_image
      Image16.from_canvas(self)
    end

    alias to_blob16 to_blob
    alias to_string16 to_string

    def self.adam7_extract_pass(pass, canvas)
      x_shift, x_offset, y_shift, y_offset = Canvas.adam7_multiplier_offset(pass)
      pixels = []

      y_offset.step(canvas.height - 1, 1 << y_shift) do |y|
        x_offset.step(canvas.width - 1, 1 << x_shift) do |x|
          pixels << canvas[x, y]
        end
      end

      new(*Canvas.adam7_pass_size(pass, canvas.width, canvas.height), pixels)
    end

    def inspect
      inspected = +"<#{self.class.name} #{width}x#{height} ["
      pixels.each_slice(width) do |row|
        inspected << "\n\t["
        inspected << row.map { |pixel| Color16.to_truecolor_alpha_bytes(pixel).inspect }.join(" ")
        inspected << "]"
      end
      inspected << "\n]>"
    end
  end
end
