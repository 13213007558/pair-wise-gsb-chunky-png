# frozen-string-literal: true

require "matrix"

module ChunkyPNG
  # Describes the RGB color space of encoded pixel values.
  class ColorProfile
    class InvalidColorSpace < ChunkyPNG::Exception
    end

    # Chromaticity values from a PNG cHRM chunk.
    class Chromaticities
      attr_reader :white_x, :white_y, :red_x, :red_y, :green_x, :green_y, :blue_x, :blue_y

      def self.srgb
        new(
          white_x: Rational(31270, 100_000), white_y: Rational(32900, 100_000),
          red_x: Rational(64000, 100_000), red_y: Rational(33000, 100_000),
          green_x: Rational(30000, 100_000), green_y: Rational(60000, 100_000),
          blue_x: Rational(15000, 100_000), blue_y: Rational(6000, 100_000)
        )
      end

      def initialize(white_x:, white_y:, red_x:, red_y:, green_x:, green_y:, blue_x:, blue_y:)
        @white_x, @white_y, @red_x, @red_y, @green_x, @green_y, @blue_x, @blue_y =
          white_x, white_y, red_x, red_y, green_x, green_y, blue_x, blue_y
      end

      def values
        {
          white_x: white_x, white_y: white_y,
          red_x: red_x, red_y: red_y,
          green_x: green_x, green_y: green_y,
          blue_x: blue_x, blue_y: blue_y,
        }
      end

      def ==(other)
        other.is_a?(Chromaticities) && values == other.values
      end
      alias eql? ==

      def hash
        values.hash
      end

      def white_point
        normalized_xyz(white_x, white_y)
      end

      def primaries
        [
          normalized_xyz(red_x, red_y),
          normalized_xyz(green_x, green_y),
          normalized_xyz(blue_x, blue_y),
        ]
      end

      private

      def normalized_xyz(x, y)
        [x / y, 1, (1 - x - y) / y]
      end
    end

    SRGB_GAMMA = Rational(45_455, 100_000)
    DEFAULT_MISSING_POLICY = :assume_srgb
    DEFAULT_CONFLICT_POLICY = :raise
    DEFAULT_INVALID_WHITE_POLICY = :raise

    BRADFORD = Matrix[
      [0.8951, 0.2664, -0.1614],
      [-0.7502, 1.7135, 0.0367],
      [0.0389, -0.0685, 1.0296]
    ]

    @linear_rgb_matrices = {}
    @rgb_to_xyz_matrices = {}

    class << self
      def srgb(explicit: true)
        return SRGB if explicit
        new(standard: true, explicit: false)
      end

      def custom(gamma:, chromaticities:, explicit: true)
        new(gamma: gamma, chromaticities: chromaticities, explicit: explicit)
      end

      def linear_rgb_matrix(source, target)
        @linear_rgb_matrices[[source, target]] ||= build_linear_rgb_matrix(source, target)
      end

      def rgb_to_xyz_matrix(profile)
        @rgb_to_xyz_matrices[profile.chromaticities] ||= build_rgb_to_xyz_matrix(profile)
      end

      private

      def build_linear_rgb_matrix(source, target)
        return Matrix.identity(3) if source.chromaticities == target.chromaticities

        source_white = BRADFORD * Matrix.column_vector(source.chromaticities.white_point)
        target_white = BRADFORD * Matrix.column_vector(target.chromaticities.white_point)
        source_white_values = source_white.to_a.flatten
        target_white_values = target_white.to_a.flatten
        scale = target_white_values.map.with_index { |target, index| target / source_white_values[index] }
        adaptation = BRADFORD.inverse * Matrix.diagonal(*scale) * BRADFORD

        rgb_to_xyz_matrix(target).inverse * adaptation * rgb_to_xyz_matrix(source)
      end

      def build_rgb_to_xyz_matrix(profile)
        chromaticities = profile.chromaticities
        primaries = Matrix.columns(chromaticities.primaries)
        coefficients = primaries.inverse * Matrix.column_vector(chromaticities.white_point)
        primaries * Matrix.diagonal(*coefficients.to_a.flatten)
      end
    end

    attr_reader :gamma

    def initialize(gamma: nil, chromaticities: nil, standard: false, explicit: true)
      @explicit = explicit

      if standard || (gamma.nil? && chromaticities.nil?)
        @standard = true
        @gamma = nil
        @chromaticities = nil
      else
        if gamma.nil? || chromaticities.nil?
          raise ArgumentError, "A custom RGB profile requires both gAMA and cHRM metadata."
        end
        raise ArgumentError, "Gamma must be greater than zero." unless valid_number?(gamma) && gamma > 0

        @standard = false
        @gamma = gamma.to_f
        @chromaticities = chromaticities
        validate_primaries!
      end
    end

    def standard_srgb?
      @standard
    end

    def explicit?
      @explicit
    end

    def chromaticities
      @chromaticities || Chromaticities.srgb
    end

    def ==(other)
      other.is_a?(ColorProfile) &&
        standard_srgb? == other.standard_srgb? &&
        gamma == other.gamma &&
        chromaticities == other.chromaticities
    end
    alias eql? ==

    def hash
      [standard_srgb?, gamma, chromaticities].hash
    end

    def decode_component(value, alpha)
      return 0.0 if alpha.zero?
      decode_light(value / Color::MAX.to_f)
    end

    def encode_component(value)
      value = 0.0 if value < 0 && value > -1e-9
      value = 1.0 if value > 1 && value < 1 + 1e-9
      value = [[value, 0.0].max, 1.0].min
      (encode_light(value) * Color::MAX).round
    end

    def matrix_to(target)
      self.class.send(:linear_rgb_matrix, self, target)
    end

    def to_chunks
      return [] unless explicit?
      return [Chunk::SRGB.new] if standard_srgb?

      [
        Chunk::Gamma.new((100_000 / gamma).round),
        Chunk::Chromaticities.new(chromaticities.values),
      ]
    end

    private

    def decode_light(value)
      if standard_srgb?
        value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4
      else
        value ** (1.0 / gamma)
      end
    end

    def encode_light(value)
      if standard_srgb?
        value <= 0.0031308 ? value * 12.92 : 1.055 * value ** (1.0 / 2.4) - 0.055
      else
        value ** gamma
      end
    end

    def valid_number?(value)
      value.is_a?(Numeric) && (value.to_f == value.to_f) && !value.to_f.infinite?
    end

    def finite_number?(value)
      value.is_a?(Numeric) && value.to_f == value.to_f && value.to_f.infinite?.nil?
    end

    def validate_primaries!
      primary_matrix = Matrix.columns(chromaticities.primaries)
      determinant = primary_matrix.determinant
      unless finite_number?(determinant) && determinant.abs > 1e-10
        raise InvalidColorSpace, "cHRM does not describe a valid RGB color space."
      end

      coefficients = primary_matrix.inverse * Matrix.column_vector(chromaticities.white_point)
      coefficients.to_a.flatten.each do |coefficient|
        unless finite_number?(coefficient)
          raise InvalidColorSpace, "cHRM does not describe a valid RGB color space."
        end
        raise InvalidColorSpace, "cHRM white point is outside the RGB primaries triangle." if coefficient < -1e-10
      end
    end

    SRGB = new(standard: true).freeze
  end
end
