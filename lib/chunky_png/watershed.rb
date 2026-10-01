# frozen-string-literal: true

module ChunkyPNG
  # Marker-controlled watershed segmentation for height maps.
  #
  # The watershed transform partitions a height map into regions ("catchment
  # basins"), one per marker, by simulating an immersion process: water rises
  # from every marker, one height level at a time, and dams are built where
  # water coming from different markers would meet.
  #
  # The implementation processes all pixels of the same height level together
  # and, within a level, propagates labels layer by layer in order of
  # increasing geodesic distance from the already flooded area. The assigned
  # label of a pixel only depends on pixels processed strictly earlier, so the
  # result is independent of scan order: on plateaus that are claimed by two
  # markers at the same distance, the contested pixels become watershed
  # (boundary) pixels instead of being grabbed by whichever marker happens to
  # be scanned first.
  #
  # @example
  #   result = ChunkyPNG::Watershed.segment(heights, markers, connectivity: 8)
  #   result.labels      #=> 2D array of per-pixel labels
  #   result.boundaries  #=> 2D array of booleans marking watershed lines
  #   result.to_image.save("segmentation.png")
  module Watershed
    # Label assigned to watershed line pixels: pixels that are reached by
    # water from two or more markers at exactly the same flooding distance,
    # so they cannot be assigned to a single region.
    BOUNDARY = 0

    # Label assigned to in-mask pixels that are never reached by the flood.
    # These are the pixels in connected components of the masked-in area
    # (using the chosen connectivity) that do not contain any marker.
    UNLABELED = -1

    # Pixels excluded by the mask are +nil+ in the labels matrix. They do not
    # take part in the flooding and are never assigned a label.

    # Neighbor offsets for the supported connectivities.
    # @private
    NEIGHBOR_OFFSETS = {
      4 => [[1, 0], [-1, 0], [0, 1], [0, -1]].freeze,
      8 => [[1, 0], [-1, 0], [0, 1], [0, -1],
            [1, 1], [1, -1], [-1, 1], [-1, -1]].freeze
    }.freeze

    # Default color palette used by {Result#to_image}. Label +n+ is mapped to
    # color +(n - 1) % palette length+.
    DEFAULT_PALETTE = [
      0xe6194b, 0x3cb44b, 0xffe119, 0x4363d8, 0xf58231,
      0x911eb4, 0x46f0f0, 0xf032e6, 0xbcf60c, 0xfabebe,
      0x008080, 0xe6beff, 0x9a6324, 0xfffac8, 0x800000,
      0xaaffc3, 0x808000, 0xffd8b1, 0x000075, 0x808080
    ].map { |rgb| ChunkyPNG::Color.rgb((rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff) }.freeze

    # The outcome of a watershed segmentation.
    class Result
      # @return [Array<Array<Integer, nil>>] Per-pixel labels, row by row.
      #   Positive integers are marker labels, {Watershed::BOUNDARY} marks
      #   watershed line pixels, {Watershed::UNLABELED} marks pixels in
      #   connected components without a marker, and +nil+ marks pixels that
      #   were excluded by the mask.
      attr_reader :labels

      # @return [Integer] The connectivity (4 or 8) used for the segmentation.
      attr_reader :connectivity

      def initialize(labels, connectivity)
        @labels = labels
        @connectivity = connectivity
      end

      # @return [Integer] Width of the segmented grid.
      def width
        labels.first.size
      end

      # @return [Integer] Height of the segmented grid.
      def height
        labels.size
      end

      # @return [Integer, nil] The label of a single pixel.
      def [](x, y)
        labels[y][x]
      end

      # Computes the watershed lines of the segmentation. A pixel is on a
      # watershed line when it is a {Watershed::BOUNDARY} pixel, or when one
      # of its neighbors (using the segmentation connectivity) carries a
      # different marker label. The latter also covers markers that touch
      # each other directly, without a boundary pixel in between.
      #
      # @return [Array<Array<Boolean, nil>>] Row by row: +true+ for pixels on
      #   a watershed line, +false+ for other in-mask pixels and +nil+ for
      #   masked-out pixels.
      def boundaries
        offsets = NEIGHBOR_OFFSETS[connectivity]
        Array.new(height) do |y|
          Array.new(width) do |x|
            label = labels[y][x]
            if label.nil?
              nil
            elsif label == BOUNDARY
              true
            elsif label == UNLABELED
              false
            else
              offsets.any? do |dx, dy|
                nx = x + dx
                ny = y + dy
                next false if nx < 0 || ny < 0 || nx >= width || ny >= height
                other = labels[ny][nx]
                other.is_a?(Integer) && other > BOUNDARY && other != label
              end
            end
          end
        end
      end

      # Renders the segmentation as an image: every region gets a color from
      # the palette, watershed lines are drawn in black, unlabeled pixels in
      # gray and masked-out pixels are left transparent.
      #
      # @param palette [Array<Integer>] Color values used for the regions.
      # @return [ChunkyPNG::Image] The rendered segmentation.
      def to_image(palette = DEFAULT_PALETTE)
        raise ArgumentError, "palette must not be empty" if palette.empty?
        boundary_map = boundaries
        image = ChunkyPNG::Image.new(width, height, ChunkyPNG::Color::TRANSPARENT)
        height.times do |y|
          width.times do |x|
            label = labels[y][x]
            image[x, y] =
              if label.nil?
                ChunkyPNG::Color::TRANSPARENT
              elsif boundary_map[y][x]
                ChunkyPNG::Color::BLACK
              elsif label == UNLABELED
                ChunkyPNG::Color.rgb(0x99, 0x99, 0x99)
              else
                palette[(label - 1) % palette.length]
              end
          end
        end
        image
      end
    end

    # Segments a height map into one region per marker.
    #
    # @param heights [Array<Array<Numeric>>] Height value per pixel, row by
    #   row. All rows must have the same length.
    # @param markers [Array<Array<Integer, nil>>] Marker label per pixel, row
    #   by row, with the same dimensions as +heights+. Positive integers are
    #   marker labels; +0+ or +nil+ means "no marker".
    # @param connectivity [Integer] Pixel connectivity used for the flooding:
    #   4 (orthogonal neighbors only) or 8 (also diagonal neighbors).
    # @param mask [Array<Array<Boolean>>, nil] Optional mask with the same
    #   dimensions as +heights+. Pixels whose mask value is falsy are
    #   excluded: they get a +nil+ label and do not take part in the
    #   flooding. Markers on masked-out pixels are ignored.
    # @return [Watershed::Result] The segmentation result.
    def self.segment(heights, markers, connectivity: 8, mask: nil)
      offsets = NEIGHBOR_OFFSETS[connectivity]
      raise ArgumentError, "connectivity must be 4 or 8" if offsets.nil?

      height = heights.size
      raise ArgumentError, "heights must contain at least one row" if height.zero?
      width = heights.first.size
      raise ArgumentError, "heights rows must not be empty" if width.zero?
      unless heights.all? { |row| row.is_a?(Array) && row.size == width }
        raise ArgumentError, "all heights rows must have the same length"
      end
      unless markers.size == height && markers.all? { |row| row.is_a?(Array) && row.size == width }
        raise ArgumentError, "markers must have the same dimensions as heights"
      end
      if mask && !(mask.size == height && mask.all? { |row| row.is_a?(Array) && row.size == width })
        raise ArgumentError, "mask must have the same dimensions as heights"
      end

      included = Array.new(height) do |y|
        Array.new(width) { |x| mask.nil? || !!mask[y][x] }
      end

      marker_labels = Array.new(height) { Array.new(width, 0) }
      markers.each_with_index do |row, y|
        row.each_with_index do |value, x|
          next if value.nil? || value == 0
          unless value.is_a?(Integer) && value > 0
            raise ArgumentError, "marker labels must be positive integers, got #{value.inspect}"
          end
          marker_labels[y][x] = value if included[y][x]
        end
      end

      labels = Array.new(height) do |y|
        Array.new(width) { |x| included[y][x] ? UNLABELED : nil }
      end
      distance = Array.new(height) { Array.new(width, 0) }
      label_level = Array.new(height) { Array.new(width) }

      by_level = Hash.new { |hash, key| hash[key] = [] }
      height.times do |y|
        width.times do |x|
          by_level[heights[y][x]] << [x, y] if included[y][x]
        end
      end

      each_neighbor = lambda do |x, y, &block|
        offsets.each do |dx, dy|
          nx = x + dx
          ny = y + dy
          if nx >= 0 && nx < width && ny >= 0 && ny < height && included[ny][nx]
            block.call(nx, ny)
          end
        end
      end

      # Immersion, one height level at a time. Markers only become active
      # when the water reaches their own height level, so a high marker
      # cannot claim lower terrain before the flood gets there.
      by_level.keys.sort.each do |level|
        queue = []

        # Activate the markers located at this level.
        by_level[level].each do |x, y|
          marker = marker_labels[y][x]
          next if marker.zero?
          labels[y][x] = marker
          label_level[y][x] = level
          queue << [x, y]
        end

        # Seed the unlabeled pixels of this level that touch the flooded area.
        by_level[level].each do |x, y|
          next unless labels[y][x] == UNLABELED
          touches_flood = false
          each_neighbor.call(x, y) do |nx, ny|
            neighbor_label = labels[ny][nx]
            if neighbor_label && neighbor_label != UNLABELED
              touches_flood = true
              break
            end
          end
          next unless touches_flood
          distance[y][x] = 1
          queue << [x, y]
        end

        # Grow the basins over this level, one geodesic distance layer at a
        # time. A pixel's label is decided only by pixels processed strictly
        # earlier (a lower level, a marker, or a smaller distance), which
        # makes the outcome independent of scan order. Pixels left over from
        # lower levels (unmarked pits) are absorbed here as well.
        head = 0
        while head < queue.length
          x, y = queue[head]
          head += 1
          d = distance[y][x]

          if labels[y][x] == UNLABELED
            found = nil
            conflict = false
            boundary_neighbor = false
            each_neighbor.call(x, y) do |nx, ny|
              neighbor_label = labels[ny][nx]
              next if neighbor_label.nil? || neighbor_label == UNLABELED
              # A neighbor counts as earlier when it was labeled on a
              # previous level, or on this level with a smaller geodesic
              # distance from the flooded area (markers have distance 0).
              neighbor_level = label_level[ny][nx]
              earlier = !neighbor_level.nil? &&
                (neighbor_level < level || distance[ny][nx] < d)
              next unless earlier
              if neighbor_label == BOUNDARY
                boundary_neighbor = true
              elsif found.nil?
                found = neighbor_label
              elsif found != neighbor_label
                conflict = true
              end
            end

            labels[y][x] =
              if conflict
                BOUNDARY
              elsif found
                found
              else
                # Reached only through other watershed line pixels: the line
                # continues across this pixel.
                boundary_neighbor ? BOUNDARY : UNLABELED
              end
            label_level[y][x] = level unless labels[y][x] == UNLABELED
          end

          each_neighbor.call(x, y) do |nx, ny|
            next unless labels[ny][nx] == UNLABELED && distance[ny][nx].zero?
            next unless heights[ny][nx] <= level
            distance[ny][nx] = d + 1
            queue << [nx, ny]
          end
        end
      end

      Result.new(labels, connectivity)
    end
  end
end
