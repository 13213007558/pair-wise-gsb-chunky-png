# frozen-string-literal: true

module ChunkyPNG
  class Canvas
    # Result of a Poisson image blend.
    #
    # The solver never raises when it runs out of iterations. Inspect
    # {#converged?} before treating {#canvas} as a finished blend.
    class PoissonBlendResult
      # @return [ChunkyPNG::Canvas] The blended canvas.
      attr_reader :canvas

      # @return [Symbol] +:source+ or +:mixed+.
      attr_reader :mode

      # @return [Symbol] +:direct+ or +:gauss_seidel+.
      attr_reader :solver

      # @return [Integer] Number of pixels in the binary mask.
      attr_reader :mask_pixels

      # @return [Integer] Number of solver iterations that were performed.
      attr_reader :iterations

      # @return [Integer] Requested iteration limit.
      attr_reader :iteration_budget

      # @return [Float] Largest residual over all masked pixels and RGB
      #   channels, measured in the 0-255 intensity scale.
      attr_reader :residual

      def initialize(canvas, mode, solver, mask_pixels, iterations, iteration_budget, residual, tolerance)
        @canvas = canvas
        @mode = mode
        @solver = solver
        @mask_pixels = mask_pixels
        @iterations = iterations
        @iteration_budget = iteration_budget
        @residual = residual
        @tolerance = tolerance
        @converged = residual <= tolerance
      end

      # @return [Boolean] Whether the requested tolerance was reached.
      def converged?
        @converged
      end

      # @return [Float] Residual tolerance that was requested.
      attr_reader :tolerance
    end

    # Pure Ruby Poisson image blending.
    #
    # The method solves the discrete Poisson equation independently for the
    # red, green and blue channels. Values outside the mask remain unchanged,
    # and those target values also provide the Dirichlet boundary conditions.
    # The mask may contain holes and multiple disconnected components.
    #
    # A fully opaque canvas mask selects bright pixels (luminance greater than
    # 127), which supports the conventional black/white mask. A canvas mask with
    # transparency selects every non-transparent pixel (alpha > 0). An array
    # mask may contain +true+, +false+, +1+, +0+, and numeric values; values
    # greater than 0.5 are selected.
    # The mask must match the source dimensions. Selected pixels must leave a
    # one-pixel border inside both images so all four source gradients and the
    # target boundary values are available.
    #
    # Alpha is not included in the Poisson system and is not used as a soft
    # coverage weight: source pixels are read as their stored RGB values. The
    # result preserves the target alpha channel. Composite a semi-transparent
    # source over an opaque background before blending if premultiplied RGB is
    # required.
    #
    # @param source [ChunkyPNG::Canvas] Image providing source gradients.
    # @param mask [ChunkyPNG::Canvas, Array] Binary mask with source size.
    # @param offset_x [Integer] Destination x-coordinate of the source origin.
    # @param offset_y [Integer] Destination y-coordinate of the source origin.
    # @param options [Hash] Solver options.
    # @option options [Symbol] :mode +:source+ uses source gradients; +:mixed+
    #   uses the stronger source or target gradient on each edge.
    # @option options [Integer] :iterations Maximum Gauss-Seidel iterations
    #   for each color channel.
    # @option options [Float] :tolerance Maximum absolute residual over all
    #   masked pixels and color channels.
    # @option options [Symbol] :solver +:auto+ (default), +:gauss_seidel+, or
    #   +:direct+. The direct solver is Gaussian elimination and is intended
    #   for small masks and tests.
    # @option options [Integer] :direct_limit Maximum mask size for +:auto+
    #   direct solving.
    # @return [ChunkyPNG::Canvas::PoissonBlendResult]
    def poisson_blend(source, mask, offset_x = 0, offset_y = 0, options = {})
      dup.poisson_blend!(source, mask, offset_x, offset_y, options)
    end

    # In-place variant of {#poisson_blend}.
    # @return [ChunkyPNG::Canvas::PoissonBlendResult]
    def poisson_blend!(source, mask, offset_x = 0, offset_y = 0, options = {})
      setup = setup_poisson_blend(source, mask, offset_x, offset_y, options)
      result = solve_poisson_blend(setup)
      Canvas::PoissonBlendResult.new(
        self,
        setup[:mode],
        result[:solver],
        setup[:positions].length,
        result[:iterations],
        setup[:iterations],
        result[:residual],
        setup[:tolerance]
      )
    end

    private

    def setup_poisson_blend(source, mask, offset_x, offset_y, options)
      unless source.is_a?(Canvas)
        raise ArgumentError, "source must be a ChunkyPNG::Canvas"
      end

      mode = options.fetch(:mode, :source)
      unless [:source, :mixed].include?(mode)
        raise ArgumentError, "mode must be :source or :mixed"
      end

      iterations = options.fetch(:iterations, 1000).to_i
      raise ArgumentError, "iterations must be non-negative" if iterations < 0

      tolerance = options.fetch(:tolerance, 0.01).to_f
      raise ArgumentError, "tolerance must be non-negative" if tolerance < 0

      solver = options.fetch(:solver, :auto)
      unless [:auto, :gauss_seidel, :direct].include?(solver)
        raise ArgumentError, "solver must be :auto, :gauss_seidel, or :direct"
      end

      direct_limit = options.fetch(:direct_limit, 16).to_i
      raise ArgumentError, "direct_limit must be non-negative" if direct_limit < 0

      unless offset_x.is_a?(Integer) && offset_y.is_a?(Integer)
        raise ArgumentError, "offset coordinates must be integers"
      end

      selected = poisson_mask_values(mask, source.width, source.height)
      check_poisson_geometry!(source, selected, offset_x, offset_y)

      positions = []
      selected.each_with_index { |value, index| positions << index if value }

      {
        mode: mode,
        iterations: iterations,
        tolerance: tolerance,
        solver: solver,
        direct_limit: direct_limit,
        source: source,
        offset_x: offset_x,
        offset_y: offset_y,
        selected: selected,
        positions: positions
      }
    end

    def poisson_mask_values(mask, mask_width, mask_height)
      values = if mask.is_a?(Canvas)
        unless mask.width == mask_width && mask.height == mask_height
          raise ArgumentError, "mask dimensions must match source dimensions"
        end
        opaque_mask = mask.pixels.all? { |pixel| ChunkyPNG::Color.opaque?(pixel) }
        mask.pixels.map do |pixel|
          if opaque_mask
            (ChunkyPNG::Color.r(pixel) +
              ChunkyPNG::Color.g(pixel) +
              ChunkyPNG::Color.b(pixel)) > 3 * 127
          else
            ChunkyPNG::Color.a(pixel) > 0
          end
        end
      elsif mask.is_a?(Array)
        unless mask.length == mask_width * mask_height
          raise ArgumentError, "mask must contain width * height elements"
        end
        mask.map do |value|
          case value
          when true, false then value
          when Numeric then value.to_f > 0.5
          else raise ArgumentError, "mask values must be boolean or numeric"
          end
        end
      else
        raise ArgumentError, "mask must be a ChunkyPNG::Canvas or an Array"
      end

      values
    end

    def check_poisson_geometry!(source, selected, offset_x, offset_y)
      if offset_x < 0 || offset_y < 0 ||
          offset_x + source.width > width || offset_y + source.height > height
        raise ChunkyPNG::OutOfBounds, "source does not fit in target at offset"
      end

      source.height.times do |y|
        source.width.times do |x|
          next unless selected[y * source.width + x]
          if x == 0 || y == 0 || x == source.width - 1 || y == source.height - 1 ||
             offset_x + x == 0 || offset_y + y == 0 ||
             offset_x + x == width - 1 || offset_y + y == height - 1
            raise ArgumentError, "mask pixels must be at least one pixel from all borders"
          end
        end
      end
    end

    def solve_poisson_blend(setup)
      positions = setup[:positions]
      return { solver: :direct, iterations: 0, residual: 0.0 } if positions.empty?

      source = setup[:source]
      offset_x = setup[:offset_x]
      offset_y = setup[:offset_y]
      count = positions.length
      index_map = Array.new(source.width * source.height, -1)
      neighbors = Array.new(count)
      target_indices = Array.new(count)

      positions.each_with_index do |source_index, unknown_index|
        x = source_index % source.width
        y = source_index / source.width
        target_indices[unknown_index] = (y + offset_y) * width + x + offset_x
        index_map[source_index] = unknown_index
      end

      positions.each_with_index do |source_index, unknown_index|
        x = source_index % source.width
        y = source_index / source.width
        local_neighbors = [[0, -1], [1, 0], [0, 1], [-1, 0]].map do |delta_x, delta_y|
          neighbor_x = x + delta_x
          neighbor_y = y + delta_y
          source_neighbor = neighbor_y * source.width + neighbor_x
          target_neighbor = (neighbor_y + offset_y) * width + neighbor_x + offset_x
          [source_neighbor, target_neighbor, index_map[source_neighbor]]
        end
        neighbors[unknown_index] = local_neighbors
      end

      use_direct = setup[:solver] == :direct ||
        (setup[:solver] == :auto && count <= setup[:direct_limit])

      if use_direct
        solve_poisson_direct(setup, positions, neighbors, target_indices)
      else
        solve_poisson_gauss_seidel(setup, positions, neighbors, target_indices)
      end
    end

    def solve_poisson_direct(setup, positions, neighbors, target_indices)
      count = positions.length
      iterations = 0
      residual = 0.0
      source = setup[:source]

      [0, 1, 2].each do |channel|
        source_values = poisson_channel_values(source.pixels, channel)
        target_values = poisson_channel_values(pixels, channel)
        guide = poisson_channel_guide(
          setup[:mode], count, neighbors, target_indices,
          source_values, target_values, positions
        )
        matrix = Array.new(count) do |i|
          boundary_sum = neighbors[i].inject(0) do |sum, edge|
            edge[2] >= 0 ? sum : sum + target_values[edge[1]]
          end
          [Array.new(count, 0), boundary_sum + guide[i]]
        end

        count.times do |i|
          matrix[i][0][i] = 4
          neighbors[i].each do |edge|
            unknown_neighbor = edge[2]
            matrix[i][0][unknown_neighbor] = -1 if unknown_neighbor >= 0
          end
        end

        values = solve_poisson_matrix(
          matrix.map { |row| [row[0].map { |value| Rational(value) }, Rational(row[1])] }
        )
        write_poisson_channel(channel, target_indices, values)
        channel_residual = poisson_linear_residual(values, neighbors, target_values, guide)
        residual = [residual, channel_residual].max
      end

      {
        solver: :direct,
        iterations: iterations,
        residual: residual.to_f
      }
    end

    def solve_poisson_gauss_seidel(setup, positions, neighbors, target_indices)
      count = positions.length
      source = setup[:source]
      red = []
      black = []
      positions.each_with_index do |source_index, unknown_index|
        x = source_index % source.width
        y = source_index / source.width
        ((x + y).even? ? red : black) << unknown_index
      end

      values_by_channel = []
      residual = 0.0
      performed_iterations = 0

      [0, 1, 2].each do |channel|
        source_values = poisson_channel_values(source.pixels, channel)
        target_values = poisson_channel_values(pixels, channel)
        guide = poisson_channel_guide(
          setup[:mode], count, neighbors, target_indices,
          source_values, target_values, positions
        )
        rhs = guide
        values = positions.map.with_index do |_source_index, unknown_index|
          target_values[target_indices[unknown_index]].to_f
        end
        iterations = 0
        channel_residual = nil

        loop do
          channel_residual = poisson_linear_residual(values, neighbors, target_values, rhs)
          break if channel_residual <= setup[:tolerance] || iterations >= setup[:iterations]

          red.each do |unknown_index|
            values[unknown_index] = poisson_update_value(
              unknown_index, neighbors, target_indices, values, rhs, target_values
            )
          end
          black.each do |unknown_index|
            values[unknown_index] = poisson_update_value(
              unknown_index, neighbors, target_indices, values, rhs, target_values
            )
          end
          iterations += 1
        end

        channel_residual = poisson_linear_residual(values, neighbors, target_values, rhs)
        residual = [residual, channel_residual].max
        values_by_channel << values
        performed_iterations = [performed_iterations, iterations].max
      end

      values_by_channel.each_with_index do |values, channel|
        write_poisson_channel(channel, target_indices, values)
      end

      {
        solver: :gauss_seidel,
        iterations: performed_iterations,
        residual: residual
      }
    end

    def poisson_update_value(unknown_index, neighbors, target_indices, values, rhs, target_values)
      sum = 0.0
      neighbors[unknown_index].each do |edge|
        target_neighbor = edge[1]
        unknown_neighbor = edge[2]
        sum += unknown_neighbor >= 0 ? values[unknown_neighbor] : target_values[target_neighbor]
      end
      (rhs[unknown_index] + sum) / 4.0
    end

    def poisson_channel_guide(mode, count, neighbors, target_indices, source_values, target_values, positions)
      Array.new(count) do |unknown_index|
        center_source_index = positions[unknown_index]
        center_target_index = target_indices[unknown_index]
        neighbors[unknown_index].inject(0) do |sum, edge|
          source_neighbor, target_neighbor, _unknown_neighbor = edge
          source_difference = source_values[center_source_index] - source_values[source_neighbor]
          if mode == :mixed
            target_difference = target_values[center_target_index] - target_values[target_neighbor]
            source_difference = target_difference if target_difference.abs > source_difference.abs
          end

          sum + source_difference
        end
      end
    end

    def poisson_linear_residual(values, neighbors, target_values, guide)
      values.each_with_index.inject(0.0) do |maximum, (value, unknown_index)|
        residual = neighbors[unknown_index].inject(0.0) do |total, edge|
          _source_neighbor, target_neighbor, unknown_neighbor = edge
          neighbor_value = unknown_neighbor >= 0 ? values[unknown_neighbor] : target_values[target_neighbor]
          total + neighbor_value
        end
        [maximum, (guide[unknown_index] + residual - 4 * value).abs.to_f].max
      end
    end

    def solve_poisson_matrix(matrix)
      count = matrix.length
      count.times do |pivot|
        row = (pivot...count).max_by { |row| matrix[row][0][pivot].abs }
        if matrix[row][0][pivot] == 0
          raise ChunkyPNG::Exception, "Poisson system is singular"
        end
        matrix[pivot], matrix[row] = matrix[row], matrix[pivot] if row != pivot

        pivot_value = matrix[pivot][0][pivot]
        (pivot + 1...count).each do |row|
          factor = matrix[row][0][pivot] / pivot_value
          next if factor == 0
          (pivot...count).each do |column|
            matrix[row][0][column] -= factor * matrix[pivot][0][column]
          end
          matrix[row][1] -= factor * matrix[pivot][1]
        end
      end

      values = Array.new(count)
      (count - 1).downto(0) do |row|
        sum = matrix[row][1]
        (row + 1...count).each do |column|
          sum -= matrix[row][0][column] * values[column]
        end
        values[row] = sum / matrix[row][0][row]
      end
      values
    end

    def poisson_channel_values(pixel_values, channel)
      shifts = [24, 16, 8]
      pixel_values.map { |pixel| (pixel >> shifts[channel]) & 0xff }
    end

    def write_poisson_channel(channel, target_indices, values)
      shifts = [24, 16, 8]
      shift = shifts[channel]
      values.each_with_index do |value, unknown_index|
        target_index = target_indices[unknown_index]
        component = value.to_f.round
        component = 0 if component < 0
        component = 255 if component > 255
        pixels[target_index] = (pixels[target_index] & ~(0xff << shift)) | (component << shift)
      end
    end
  end
end
