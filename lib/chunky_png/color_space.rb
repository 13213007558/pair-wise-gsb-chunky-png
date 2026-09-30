# frozen-string-literal: true

module ChunkyPNG
  # Represents an RGB color space used for color-managed PNG compositing.
  class ColorSpace
    SRGB_WHITE_POINT = [0.3127, 0.3290].freeze
    SRGB_PRIMARIES = [
      [0.6400, 0.3300],
      [0.3000, 0.6000],
      [0.1500, 0.0600],
    ].freeze

    BRADFORD = [
      [0.8951, 0.2664, -0.1614],
      [-0.7502, 1.7135, 0.0367],
      [0.0389, -0.0685, 1.0296],
    ].freeze

    BRADFORD_INVERSE = [
      [0.9869929, -0.1470543, 0.1599627],
      [0.4323053, 0.5183603, 0.0492912],
      [-0.0085287, 0.0400428, 0.9684867],
    ].freeze

    DEFAULT_POLICIES = {
      on_missing_color_profile: :assume_srgb,
      on_conflicting_color_metadata: :raise,
      on_invalid_white_point: :raise,
    }.freeze

    attr_reader :encoding_gamma, :white_point, :primaries

    def self.srgb
      @srgb ||= new(
        encoding_gamma: nil,
        white_point: SRGB_WHITE_POINT,
        primaries: SRGB_PRIMARIES,
        srgb_transfer: true
      )
    end

    def self.from_chunks(srgb_chunks, gamma_chunks, chromaticity_chunks, options = {})
      options = DEFAULT_POLICIES.merge(options)
      srgb_chunks = Array(srgb_chunks).compact
      gamma_chunks = Array(gamma_chunks).compact
      chromaticity_chunks = Array(chromaticity_chunks).compact

      conflict = conflicting_metadata?(srgb_chunks, gamma_chunks, chromaticity_chunks)
      if conflict
        case options[:on_conflicting_color_metadata]
        when :raise then raise ColorProfileError, "Conflicting PNG color profile metadata"
        when :prefer_srgb
          if srgb_chunks.empty?
            gamma_chunks = []
            chromaticity_chunks = []
          else
            srgb_chunks = srgb_chunks.first(1)
            gamma_chunks = gamma_chunks.select { |chunk| (chunk.gamma - 0.45455).abs <= 0.00002 }
            chromaticity_chunks = chromaticity_chunks.select { |chunk| self.class.srgb_chromaticity?(chunk) }
          end
        when :prefer_gama_chrm
          srgb_chunks = []
          gamma_chunks = gamma_chunks.first(1)
          chromaticity_chunks = chromaticity_chunks.first(1)
        when :first
          srgb_chunks = srgb_chunks.first(1)
          gamma_chunks = gamma_chunks.first(1)
          chromaticity_chunks = chromaticity_chunks.first(1)
        when :last
          srgb_chunks = srgb_chunks.last(1)
          gamma_chunks = gamma_chunks.last(1)
          chromaticity_chunks = chromaticity_chunks.last(1)
        else
          raise ArgumentError,
            "Unknown conflicting color metadata policy: #{options[:on_conflicting_color_metadata].inspect}"
        end
      end

      unless srgb_chunks.empty?
        validate_srgb_intent!(srgb_chunks.first)
        return srgb
      end

      gamma_chunk = gamma_chunks.first
      chromaticity_chunk = chromaticity_chunks.first

      if gamma_chunk.nil? || chromaticity_chunk.nil?
        case options[:on_missing_color_profile]
        when :assume_srgb then return srgb
        when :assume_linear
          gamma_chunk ||= Chunk::Gamma.new(1.0)
          chromaticity_chunk ||= Chunk::Chromaticity.new(*([SRGB_WHITE_POINT] + SRGB_PRIMARIES).flatten)
        when :raise
          raise ColorProfileError, "PNG color profile metadata is incomplete"
        else
          raise ArgumentError, "Unknown missing color profile policy: #{options[:on_missing_color_profile].inspect}"
        end
      end

      gamma = gamma_chunk && gamma_chunk.gamma
      valid_gamma = numeric?(gamma) && finite_number?(gamma) && gamma > 0
      raise ColorProfileError, "Invalid gAMA value" unless valid_gamma

      if chromaticity_chunk
        unless valid_white_point?(chromaticity_chunk.white_point)
          case options[:on_invalid_white_point]
          when :raise then raise ColorProfileError, "Invalid cHRM white point"
          when :assume_srgb
            chromaticity_chunk = Chunk::Chromaticity.new(
              *(SRGB_WHITE_POINT + chromaticity_chunk.primaries.flatten)
            )
          else
            raise ArgumentError, "Unknown invalid white point policy: #{options[:on_invalid_white_point].inspect}"
          end
        end
      end

      new(
        encoding_gamma: gamma,
        white_point: chromaticity_chunk.white_point,
        primaries: chromaticity_chunk.primaries
      )
    end

    def self.conflicting_metadata?(srgb_chunks, gamma_chunks, chromaticity_chunks)
      return true if srgb_chunks.length > 1 || gamma_chunks.length > 1 || chromaticity_chunks.length > 1
      return false if srgb_chunks.empty?

      gamma_chunks.any? { |chunk| (chunk.gamma - 0.45455).abs > 0.00002 } ||
        chromaticity_chunks.any? { |chunk| !srgb_chromaticity?(chunk) }
    end

    def self.srgb_chromaticity?(chunk)
      values = [chunk.white_point, *chunk.primaries].flatten
      expected = [SRGB_WHITE_POINT, *SRGB_PRIMARIES].flatten
      values.zip(expected).all? { |actual, expected_value| (actual - expected_value).abs <= 0.00002 }
    end

    def self.valid_white_point?(point)
      point.is_a?(Array) &&
        point.length == 2 &&
        point.all? { |value| numeric?(value) && finite_number?(value) } &&
        point.first >= 0 && point.first <= 1 &&
          point.last > 0 && point.last <= 1 &&
          point.first + point.last <= 1
    end

    def self.numeric?(value)
      value.is_a?(Numeric) && !value.is_a?(Complex)
    end

    def self.finite_number?(value)
      value.respond_to?(:finite?) ? value.finite? : true
    end

    def self.validate_srgb_intent!(chunk)
      raise ColorProfileError, "Invalid sRGB rendering intent" unless (0..3).cover?(chunk.rendering_intent)
    end

    def initialize(options)
      @srgb_transfer = options.fetch(:srgb_transfer, false)
      @encoding_gamma = options[:encoding_gamma]
      @encoding_gamma = 0.45455 if @srgb_transfer && @encoding_gamma.nil?
      @white_point = options.fetch(:white_point, SRGB_WHITE_POINT)
      @primaries = options.fetch(:primaries, SRGB_PRIMARIES)

      unless @srgb_transfer
        unless numeric?(@encoding_gamma) &&
          finite_number?(@encoding_gamma) &&
          @encoding_gamma > 0
          raise ArgumentError, "encoding gamma must be positive"
        end
      end
      unless self.class.valid_white_point?(@white_point) && valid_primaries?
        raise ArgumentError, "Invalid RGB chromaticities"
      end
    end

    def srgb_transfer?
      @srgb_transfer
    end

    def srgb?
      srgb_transfer? &&
        (white_point.map(&:to_f) == SRGB_WHITE_POINT.map(&:to_f)) &&
        primaries.flatten == SRGB_PRIMARIES.flatten
    end

    def chunks
      if srgb?
        [Chunk::SRGB.new(0)]
      else
        [
          Chunk::Gamma.new(encoding_gamma || 0.45455),
          Chunk::Chromaticity.new(*([white_point] + primaries).flatten),
        ]
      end
    end

    def decode(value)
      if srgb_transfer?
        value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4
      else
        value ** encoding_gamma
      end
    end

    def encode(value)
      value = clamp(value)
      if srgb_transfer?
        value <= 0.0031308 ? value * 12.92 : 1.055 * (value ** (1.0 / 2.4)) - 0.055
      else
        value ** (1.0 / encoding_gamma)
      end
    end

    def ==(other)
      other.is_a?(self.class) &&
        srgb_transfer? == other.srgb_transfer? &&
        encoding_gamma == other.encoding_gamma &&
        white_point == other.white_point &&
        primaries == other.primaries
    end

    alias eql? ==

    def hash
      [srgb_transfer?, encoding_gamma, white_point, primaries].hash
    end

    def to_linear_srgb(rgb)
      return rgb.dup if self == self.class.srgb
      linear_rgb = rgb.map { |value| decode(value) }
      xyz = matrix_multiply(rgb_to_xyz_matrix, linear_rgb)
      adapted_xyz = adapt_to_srgb(xyz)
      matrix_multiply(self.class.srgb.rgb_to_xyz_matrix_inverse, adapted_xyz)
    end

    def from_linear_srgb(rgb)
      return rgb.dup if self == self.class.srgb
      target_srgb = self.class.srgb
      xyz = matrix_multiply(target_srgb.rgb_to_xyz_matrix, rgb)
      adapted_xyz = adapt_from_srgb(xyz)
      linear_rgb = matrix_multiply(rgb_to_xyz_matrix_inverse, adapted_xyz)
      linear_rgb.map { |value| encode(value) }
    end

    def rgb_to_xyz_matrix
      @rgb_to_xyz_matrix ||= begin
        primary_rows = primaries.map do |primary|
          x, y = primary
          raise ArgumentError, "Invalid RGB chromaticity" if y.nil? || y.abs <= 1e-12
          [x / y, 1.0, (1.0 - x - y) / y]
        end
        white_xyz = chromaticity_to_xyz(white_point)
        scales = matrix_multiply(matrix_inverse(primary_rows.transpose), white_xyz)
        scaled_rows = primary_rows.each_with_index.map do |row, index|
          row.map { |value| value * scales[index] }
        end
        scaled_rows.transpose
      end
    end

    def rgb_to_xyz_matrix_inverse
      @rgb_to_xyz_matrix_inverse ||= matrix_inverse(rgb_to_xyz_matrix)
    end

    private

    def valid_primaries?
      primaries.is_a?(Array) &&
        primaries.length == 3 &&
        primaries.all? do |primary|
          primary.is_a?(Array) &&
            primary.length == 2 &&
            primary.all? do |value|
              numeric?(value) && finite_number?(value) &&
                value >= 0 && value <= 1
            end &&
            primary.last > 0
        end &&
        begin
          rgb_to_xyz_matrix
          true
        rescue ArgumentError
          false
        end
    end

    def chromaticity_to_xyz(point)
      x, y = point
      [x / y, 1.0, (1.0 - x - y) / y]
    end

    def adapt_to_srgb(xyz)
      adapt_xyz(xyz, white_point, self.class.srgb.white_point)
    end

    def adapt_from_srgb(xyz)
      adapt_xyz(xyz, self.class.srgb.white_point, white_point)
    end

    def adapt_xyz(xyz, source_point, destination_point)
      source = bradford_cone(chromaticity_to_xyz(source_point))
      destination = bradford_cone(chromaticity_to_xyz(destination_point))
      cones = matrix_multiply(BRADFORD, xyz)
      adapted_cones = cones.each_with_index.map { |value, index| value * destination[index] / source[index] }
      matrix_multiply(BRADFORD_INVERSE, adapted_cones)
    end

    def bradford_cone(xyz)
      matrix_multiply(BRADFORD, xyz)
    end

    def clamp(value)
      [[value, 0.0].max, 1.0].min
    end

    def numeric?(value)
      value.is_a?(Numeric) && !value.is_a?(Complex)
    end

    def finite_number?(value)
      value.respond_to?(:finite?) ? value.finite? : true
    end

    def matrix_multiply(matrix, vector)
      matrix.map do |row|
        row.each_with_index.inject(0.0) do |sum, (value, index)|
          sum + value * vector[index]
        end
      end
    end

    def matrix_inverse(matrix)
      a = matrix.map(&:dup)
      inverse = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]

      3.times do |column|
        pivot = (column...3).max_by { |row_index| a[row_index][column].abs }
        if a[pivot][column].abs <= 1e-12
          raise ArgumentError, "RGB primary matrix is singular"
        end
        a[column], a[pivot] = a[pivot], a[column] unless pivot == column
        inverse[column], inverse[pivot] = inverse[pivot], inverse[column] unless pivot == column

        pivot_value = a[column][column]
        a[column] = a[column].map { |value| value / pivot_value }
        inverse[column] = inverse[column].map { |value| value / pivot_value }

        3.times do |row|
          next if row == column
          factor = a[row][column]
          a[row] = a[row].each_with_index.map { |value, index| value - factor * a[column][index] }
          inverse[row] = inverse[row].each_with_index.map { |value, index| value - factor * inverse[column][index] }
        end
      end

      inverse
    end
  end
end
