# frozen-string-literal: true

module ChunkyPNG
  # The ChunkyPNG::Watershed module implements marker-controlled watershed
  # segmentation of a height map.
  #
  # Given a height map (a two-dimensional array of numbers) and a set of
  # labeled markers, the immersion-based watershed algorithm floods the
  # height map from the markers, level by level, and assigns every reachable
  # pixel to one of the markers. Pixels where two or more floods meet are
  # marked as watershed (boundary) pixels.
  #
  # The flooding claims frontier pixels in increasing height order, and all
  # frontier pixels of the same height are claimed simultaneously, in waves
  # of equal geodesic distance to the markers. Because of this, plateaus
  # (connected regions of equal height) are split purely by distance to the
  # markers and never by scan order: the result is invariant under rotations
  # and flips of the input.
  #
  # @example Segmenting a small height map
  #   heights = [[1, 2, 3, 2, 1]]
  #   markers = [[1, 0, 0, 0, 2]]
  #   result = ChunkyPNG::Watershed.segment(heights, markers, connectivity: 4)
  #   result.labels # => [[1, 1, -1, 2, 2]]
  #
  module Watershed
    # Label value used for pixels that have not been assigned to a region.
    # This includes pixels outside the mask and connected components of the
    # mask that do not contain a marker.
    UNLABELED = 0

    # Label value used for watershed pixels, i.e. pixels where the floods of
    # two or more markers meet.
    WATERSHED = -1

    # Neighbor offsets for 4-connectivity (edge-adjacent pixels).
    NEIGHBORS_4 = [[1, 0], [-1, 0], [0, 1], [0, -1]].freeze

    # Neighbor offsets for 8-connectivity (edge- and corner-adjacent pixels).
    NEIGHBORS_8 = (NEIGHBORS_4 + [[1, 1], [1, -1], [-1, 1], [-1, -1]]).freeze

    # The outcome of a watershed segmentation. See {Watershed.segment}.
    class Result
      # @return [Integer] The width of the segmented height map.
      attr_reader :width

      # @return [Integer] The height of the segmented height map.
      attr_reader :height

      # @return [Integer] The connectivity that was used, either 4 or 8.
      attr_reader :connectivity

      def initialize(labels, connectivity) # :nodoc:
        @labels = labels
        @height = labels.size
        @width = labels[0].size
        @connectivity = connectivity
      end

      # Returns the label matrix as an array of rows. Each row is an array of
      # per-pixel labels: a positive marker id, {Watershed::WATERSHED} for
      # boundary pixels, or {Watershed::UNLABELED} for pixels that were not
      # reached by any marker (including pixels outside the mask).
      #
      # @return [Array<Array<Integer>>] The label rows, indexed as [y][x].
      def labels
        @labels.map(&:dup)
      end

      # Returns the label of a single pixel.
      #
      # @param [Integer] x The x-coordinate of the pixel.
      # @param [Integer] y The y-coordinate of the pixel.
      # @return [Integer] The label of the pixel.
      def [](x, y)
        @labels[y][x]
      end

      # Checks whether a pixel lies on a boundary between regions. A pixel is
      # a boundary pixel when it is a watershed pixel, or when one of its
      # neighbors (using the connectivity of the segmentation) carries a
      # different positive label. The latter also catches markers that touch
      # each other directly.
      #
      # @param [Integer] x The x-coordinate of the pixel.
      # @param [Integer] y The y-coordinate of the pixel.
      # @return [Boolean] True when the pixel lies on a region boundary.
      def boundary?(x, y)
        label = @labels[y][x]
        return true if label == WATERSHED
        return false if label <= UNLABELED

        offsets.any? do |dx, dy|
          nx, ny = x + dx, y + dy
          next false if nx < 0 || ny < 0 || nx >= @width || ny >= @height
          other = @labels[ny][nx]
          other > UNLABELED && other != label
        end
      end

      # Returns the boundary map as an array of boolean rows.
      #
      # @return [Array<Array<Boolean>>] Boundary rows, indexed as [y][x].
      def boundaries
        Array.new(@height) { |y| Array.new(@width) { |x| boundary?(x, y) } }
      end

      # Renders the segmentation as an image for visualization. Every label
      # gets a distinct, deterministic color; watershed pixels are drawn in
      # black and unlabeled pixels are fully transparent.
      #
      # @param [Hash{Integer => Integer}] color_map Optional mapping of label
      #   ids to ChunkyPNG colors, overriding the generated colors.
      # @return [ChunkyPNG::Canvas] A canvas visualizing the segmentation.
      def to_image(color_map = {})
        canvas = ChunkyPNG::Canvas.new(@width, @height, ChunkyPNG::Color::TRANSPARENT)
        @height.times do |y|
          @width.times do |x|
            canvas[x, y] = color_for(@labels[y][x], color_map)
          end
        end
        canvas
      end

      private

      def offsets
        (@connectivity == 8) ? NEIGHBORS_8 : NEIGHBORS_4
      end

      def color_for(label, color_map)
        if label == WATERSHED
          ChunkyPNG::Color::BLACK
        elsif label <= UNLABELED
          ChunkyPNG::Color::TRANSPARENT
        elsif color_map.key?(label)
          color_map[label]
        else
          default_color(label)
        end
      end

      # Deterministic, well-spread color per label using the golden angle.
      def default_color(label)
        ChunkyPNG::Color.from_hsl((label * 137.508) % 360, 0.65, 0.55)
      end
    end

    # Performs marker-controlled watershed segmentation on a height map.
    #
    # The height map is flooded from the markers in increasing height order.
    # All frontier pixels of one height are claimed simultaneously, in waves
    # of equal geodesic distance to the markers, so the outcome never depends
    # on scan order. A pixel reached by floods of different markers at the
    # same distance becomes a {WATERSHED} pixel.
    #
    # Marker pixels always keep their own label, even when two different
    # markers touch each other; the boundary between them is reported by
    # {Result#boundary?}. Pixels outside the mask, and connected regions of
    # the mask that contain no marker, are labeled {UNLABELED}.
    #
    # @param [Array<Array<Numeric>>] heights The height map, as an array of
    #   rows indexed as heights[y][x].
    # @param [Array<Array<Integer>>] markers The marker map, same dimensions
    #   as the height map. Zero means unmarked, a positive integer is a
    #   marker label.
    # @param [Integer] connectivity Pixel connectivity, either 4 or 8.
    # @param [Array<Array<Boolean>>, nil] mask Optional mask, same dimensions
    #   as the height map. Pixels where the mask is falsy are excluded from
    #   the segmentation and labeled {UNLABELED}.
    # @return [ChunkyPNG::Watershed::Result] The segmentation result.
    # @raise [ArgumentError] When connectivity is not 4 or 8.
    # @raise [ChunkyPNG::ExpectationFailed] When the matrices are malformed.
    def self.segment(heights, markers, connectivity: 8, mask: nil)
      offsets =
        case connectivity
        when 4 then NEIGHBORS_4
        when 8 then NEIGHBORS_8
        else raise ArgumentError, "Connectivity must be 4 or 8, got #{connectivity.inspect}"
        end

      height = validate_matrix!(heights, "heights")
      width = heights[0].size
      validate_matrix!(markers, "markers", width, height)
      validate_matrix!(mask, "mask", width, height) if mask

      in_mask = Array.new(height) { |y| Array.new(width) { |x| mask.nil? || !!mask[y][x] } }
      labels = Array.new(height) { Array.new(width, UNLABELED) }

      # The frontier holds the unlabeled pixels that border a claimed pixel,
      # grouped by their height. Flooding always claims the lowest frontier
      # pixels first.
      frontier = Hash.new { |hash, key| hash[key] = [] }
      in_frontier = Array.new(height) { Array.new(width, false) }
      add_to_frontier = lambda do |x, y|
        if in_mask[y][x] && labels[y][x] == UNLABELED && !in_frontier[y][x]
          in_frontier[y][x] = true
          frontier[heights[y][x]] << [x, y]
        end
      end

      height.times do |y|
        width.times do |x|
          validate_marker!(markers[y][x], x, y)
          labels[y][x] = markers[y][x] if in_mask[y][x] && markers[y][x] > UNLABELED
        end
      end

      height.times do |y|
        width.times do |x|
          next unless labels[y][x] > UNLABELED
          each_neighbor(x, y, width, height, offsets) { |nx, ny| add_to_frontier.call(nx, ny) }
        end
      end

      until frontier.empty?
        level = frontier.keys.min
        batch = frontier.delete(level)
        batch.each { |x, y| in_frontier[y][x] = false }

        # Compute all assignments of this batch from the same starting state,
        # so that pixels at equal height and distance are claimed
        # simultaneously and never in scan order.
        assignments = []
        batch.each do |x, y|
          candidate = nil
          conflict = false
          each_neighbor(x, y, width, height, offsets) do |nx, ny|
            other = labels[ny][nx]
            next unless other > UNLABELED
            if candidate.nil?
              candidate = other
            elsif candidate != other
              conflict = true
              break
            end
          end
          next unless conflict || candidate
          assignments << [x, y, conflict ? WATERSHED : candidate]
        end

        newly_labeled = []
        assignments.each do |x, y, label|
          labels[y][x] = label
          newly_labeled << [x, y]
        end

        # Claiming a pixel can bring new pixels of any height into reach:
        # higher neighbors are flooded next, lower neighbors are filled by
        # the cascade of the same basin.
        newly_labeled.each do |x, y|
          each_neighbor(x, y, width, height, offsets) { |nx, ny| add_to_frontier.call(nx, ny) }
        end
      end

      Result.new(labels, connectivity)
    end

    # @private
    def self.each_neighbor(x, y, width, height, offsets)
      offsets.each do |dx, dy|
        nx, ny = x + dx, y + dy
        yield(nx, ny) if nx >= 0 && ny >= 0 && nx < width && ny < height
      end
    end

    # @private
    def self.validate_matrix!(matrix, name, width = nil, height = nil)
      unless matrix.is_a?(Array) && !matrix.empty? && matrix.all? { |row| row.is_a?(Array) }
        raise ChunkyPNG::ExpectationFailed, "The #{name} matrix must be a non-empty array of rows"
      end
      if height && matrix.size != height
        raise ChunkyPNG::ExpectationFailed,
          "The #{name} matrix has #{matrix.size} rows, expected #{height}"
      end
      expected_width = width || matrix[0].size
      if expected_width.zero? || matrix.any? { |row| row.size != expected_width }
        raise ChunkyPNG::ExpectationFailed,
          "All rows of the #{name} matrix must have the same, non-zero width"
      end
      matrix.size
    end

    # @private
    def self.validate_marker!(marker, x, y)
      unless marker.is_a?(Integer) && marker >= 0
        raise ChunkyPNG::ExpectationFailed,
          "Markers must be non-negative integers, got #{marker.inspect} at (#{x}, #{y})"
      end
    end

    private_class_method :each_neighbor, :validate_matrix!, :validate_marker!
  end
end
