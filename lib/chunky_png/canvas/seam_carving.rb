# frozen-string-literal: true

module ChunkyPNG
  class Canvas
    # The ChunkyPNG::Canvas::SeamCarving module implements content-aware image
    # resizing using the seam carving algorithm. Instead of scaling every
    # pixel, seam carving removes the least important connected paths of
    # pixels (seams) from the image, so unimportant content is removed first
    # when an image is made narrower or shorter.
    #
    # The module is included into the Canvas class so all these methods are
    # available on every canvas.
    #
    # @see ChunkyPNG::Canvas
    module SeamCarving
      # Exception raised when no feasible seam can be found because the
      # protection mask blocks every possible path across the canvas.
      class NoFeasibleSeamError < ChunkyPNG::ExpectationFailed; end

      # The energy bonus that is subtracted from pixels marked in the
      # removal priority mask. It is a large finite number, so marked pixels
      # are strongly preferred for removal, while protected pixels (which
      # have infinite energy) always win.
      REMOVAL_BONUS = 1 << 40

      # The result of a seam carving operation.
      #
      # @!attribute [r] canvas
      #   @return [ChunkyPNG::Canvas] The carved canvas.
      # @!attribute [r] seams
      #   @return [Array<ChunkyPNG::Canvas::SeamCarving::Seam>] The seams that
      #     were removed, in the order in which they were removed.
      class CarveResult
        attr_reader :canvas, :seams

        def initialize(canvas, seams)
          @canvas = canvas
          @seams = seams
        end

        # @return [Integer] The width of the carved canvas.
        def width
          canvas.width
        end

        # @return [Integer] The height of the carved canvas.
        def height
          canvas.height
        end
      end

      # A single seam that was removed from a canvas.
      #
      # @!attribute [r] orientation
      #   @return [Symbol] Either +:vertical+ (the seam runs from top to
      #     bottom and removing it makes the image narrower) or +:horizontal+
      #     (the seam runs from left to right and removing it makes the
      #     image shorter).
      # @!attribute [r] points
      #   @return [Array<Array(Integer, Integer)>] The pixels that made up
      #     this seam, as +[x, y]+ coordinates on the *original* canvas,
      #     ordered from top to bottom for vertical seams and from left to
      #     right for horizontal seams.
      class Seam
        attr_reader :orientation, :points

        def initialize(orientation, points)
          @orientation = orientation
          @points = points
        end

        def ==(other)
          other.is_a?(Seam) &&
            orientation == other.orientation &&
            points == other.points
        end
        alias_method :eql?, :==
      end

      # Carves seams out of the canvas to make it smaller, removing the
      # least important content first.
      #
      # The energy of every pixel is derived from the gradient of its
      # neighborhood, and is recomputed after every removed seam. This means
      # that new adjacencies that are formed when a seam is removed are
      # taken into account when selecting the next seam.
      #
      # This method will not modify the current canvas, but returns a
      # {CarveResult} containing the carved canvas and the removed seams.
      # Every removed seam records its pixels as coordinates on this
      # (original) canvas, so it is always possible to trace which original
      # pixels were removed.
      #
      # @param [Integer] vertical The number of vertical seams to remove,
      #   i.e. the number of columns to carve away. At most +width - 1+,
      #   because the width may never drop below 1.
      # @param [Integer] horizontal The number of horizontal seams to
      #   remove, i.e. the number of rows to carve away. At most
      #   +height - 1+, because the height may never drop below 1.
      # @param [ChunkyPNG::Canvas, nil] protect_mask An optional canvas of
      #   the same dimensions as this canvas. Every non-transparent pixel
      #   marks a pixel of this canvas that may never be removed. If the
      #   mask blocks every possible path across the canvas, a
      #   {NoFeasibleSeamError} is raised; seams will never cross protected
      #   pixels.
      # @param [ChunkyPNG::Canvas, nil] remove_mask An optional canvas of
      #   the same dimensions as this canvas. Every non-transparent pixel
      #   marks a pixel of this canvas that should preferably be removed.
      # @raise [ArgumentError] If a seam count is negative or would reduce
      #   the width or height below 1, or if a mask has the wrong
      #   dimensions.
      # @raise [ChunkyPNG::Canvas::SeamCarving::NoFeasibleSeamError] If the
      #   protection mask blocks every feasible path across the canvas.
      # @return [ChunkyPNG::Canvas::SeamCarving::CarveResult] The carved
      #   canvas together with the removed seams.
      def carve_seams(vertical: 0, horizontal: 0, protect_mask: nil, remove_mask: nil)
        validate_seam_count(vertical, width, :vertical)
        validate_seam_count(horizontal, height, :horizontal)
        protect = seam_mask_flags(protect_mask, :protect_mask)
        remove = seam_mask_flags(remove_mask, :remove_mask)

        carved = pixels.dup
        coords = (0...height).flat_map { |y| (0...width).map { |x| [x, y] } }
        seams = []
        w = width
        h = height

        vertical.times do |i|
          seam = find_vertical_seam(seam_energy(carved, w, h, protect, remove), w, h)
          raise_no_feasible_seam!(:vertical, i, vertical) if seam.nil?
          seams << Seam.new(:vertical, seam.each_with_index.map { |x, y| coords[y * w + x].dup })
          carved = remove_vertical_seam(carved, w, h, seam)
          coords = remove_vertical_seam(coords, w, h, seam)
          protect = remove_vertical_seam(protect, w, h, seam) if protect
          remove = remove_vertical_seam(remove, w, h, seam) if remove
          w -= 1
        end

        horizontal.times do |i|
          seam = find_horizontal_seam(seam_energy(carved, w, h, protect, remove), w, h)
          raise_no_feasible_seam!(:horizontal, i, horizontal) if seam.nil?
          seams << Seam.new(:horizontal, seam.each_with_index.map { |y, x| coords[y * w + x].dup })
          carved = remove_horizontal_seam(carved, w, h, seam)
          coords = remove_horizontal_seam(coords, w, h, seam)
          protect = remove_horizontal_seam(protect, w, h, seam) if protect
          remove = remove_horizontal_seam(remove, w, h, seam) if remove
          h -= 1
        end

        CarveResult.new(self.class.new(w, h, carved), seams)
      end

      private

      # Validates that removing +count+ seams in the given orientation keeps
      # the canvas at least 1 pixel wide or tall.
      # @raise [ArgumentError] if the count is invalid.
      def validate_seam_count(count, length, orientation)
        unless count.is_a?(Integer) && count >= 0
          raise ArgumentError, "The number of #{orientation} seams to remove must be a non-negative Integer, got #{count.inspect}"
        end
        if count > length - 1
          raise ArgumentError, "Cannot remove #{count} #{orientation} seams: the #{orientation == :vertical ? "width" : "height"} would drop below 1 pixel"
        end
      end

      # @raise [ChunkyPNG::Canvas::SeamCarving::NoFeasibleSeamError] always.
      def raise_no_feasible_seam!(orientation, removed, requested)
        raise NoFeasibleSeamError,
          "Cannot remove #{orientation} seam #{removed + 1} of #{requested}: " +          "the protection mask blocks every feasible path across the canvas"
      end

      # Converts a mask canvas into an array of booleans, where +true+ marks
      # the non-transparent (masked) pixels.
      # @raise [ArgumentError] if the mask has the wrong dimensions.
      def seam_mask_flags(mask, name)
        return nil if mask.nil?
        unless mask.width == width && mask.height == height
          raise ArgumentError, "The #{name} must have the same dimensions as the canvas (#{width}x#{height})"
        end
        mask.pixels.map { |pixel| ChunkyPNG::Color.a(pixel) > 0 }
      end

      # Computes the energy map for the given pixel matrix. The energy of a
      # pixel is the sum of the absolute grayscale gradients to its
      # horizontal and vertical neighbors. Protected pixels get infinite
      # energy; pixels marked for removal get a large bonus subtracted.
      def seam_energy(carved, w, h, protect, remove)
        gray = carved.map do |pixel|
          (ChunkyPNG::Color.r(pixel) * 299 + ChunkyPNG::Color.g(pixel) * 587 + ChunkyPNG::Color.b(pixel) * 114) / 1000
        end
        energy = Array.new(w * h)
        for y in 0...h
          for x in 0...w
            i = y * w + x
            gx = gray[y * w + [x + 1, w - 1].min] - gray[y * w + [x - 1, 0].max]
            gy = gray[[y + 1, h - 1].min * w + x] - gray[[y - 1, 0].max * w + x]
            value = gx.abs + gy.abs
            if protect && protect[i]
              value = Float::INFINITY
            elsif remove && remove[i]
              value -= REMOVAL_BONUS
            end
            energy[i] = value
          end
        end
        energy
      end

      # Finds the minimum cost vertical seam through the energy map using
      # dynamic programming. Returns an array of +h+ x-coordinates, one per
      # row, or +nil+ when every feasible path is blocked by protected
      # pixels.
      def find_vertical_seam(energy, w, h)
        cost = energy[0, w].dup
        back = Array.new(w * h)
        for y in 1...h
          previous = cost
          cost = Array.new(w)
          for x in 0...w
            best_x = x
            best = previous[x]
            if x > 0 && previous[x - 1] < best
              best = previous[x - 1]
              best_x = x - 1
            end
            if x < w - 1 && previous[x + 1] < best
              best = previous[x + 1]
              best_x = x + 1
            end
            cost[x] = energy[y * w + x] + best
            back[y * w + x] = best_x
          end
        end

        minimum = cost.min
        return nil if minimum == Float::INFINITY

        seam = Array.new(h)
        x = cost.index(minimum)
        (h - 1).downto(1) do |y|
          seam[y] = x
          x = back[y * w + x]
        end
        seam[0] = x
        seam
      end

      # Finds the minimum cost horizontal seam through the energy map by
      # transposing it. Returns an array of +w+ y-coordinates, one per
      # column, or +nil+ when every feasible path is blocked.
      def find_horizontal_seam(energy, w, h)
        transposed = Array.new(w * h)
        for y in 0...h
          for x in 0...w
            transposed[x * h + y] = energy[y * w + x]
          end
        end
        find_vertical_seam(transposed, h, w)
      end

      # Removes a vertical seam from a row-major matrix of +w+ by +h+
      # elements, returning a new matrix of +w - 1+ by +h+ elements.
      def remove_vertical_seam(matrix, w, h, seam)
        result = Array.new((w - 1) * h)
        for y in 0...h
          source = y * w
          target = y * (w - 1)
          skip = seam[y]
          xi = 0
          for x in 0...w
            next if x == skip
            result[target + xi] = matrix[source + x]
            xi += 1
          end
        end
        result
      end

      # Removes a horizontal seam from a row-major matrix of +w+ by +h+
      # elements, returning a new matrix of +w+ by +h - 1+ elements.
      def remove_horizontal_seam(matrix, w, h, seam)
        result = Array.new(w * (h - 1))
        for x in 0...w
          skip = seam[x]
          yi = 0
          for y in 0...h
            next if y == skip
            result[yi * w + x] = matrix[y * w + x]
            yi += 1
          end
        end
        result
      end
    end
  end
end
