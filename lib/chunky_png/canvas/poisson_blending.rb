# frozen_string_literal: true

module ChunkyPNG
  class Canvas
    # Pure Ruby Poisson image blending.
    #
    # The red, green and blue channels are solved independently. The alpha
    # channel is not part of the linear system and is left unchanged in the
    # returned image. Source and mask alpha values are ignored; callers that
    # need alpha compositing should do it before or after blending.
    module PoissonBlending
      # Result of a Poisson blend attempt.
      class Result
        # @return [ChunkyPNG::Canvas, nil] The blended image, or +nil+ when the
        #   solver did not converge.
        attr_reader :image

        # @return [Boolean] Whether every color channel reached the tolerance.
        attr_reader :converged

        # @return [Integer] Largest number of completed sweeps used by any one
        #   color channel.
        attr_reader :iterations

        # @return [Integer] Requested per-channel iteration budget.
        attr_reader :iterations_budget

        # @return [Float] Largest equation residual in 8-bit color units across
        #   all unknown pixels and color channels.
        attr_reader :residual

        # @return [Integer] Number of mask pixels that were solved.
        attr_reader :mask_size

        # @private
        def initialize(image, converged, iterations, iterations_budget, residual, mask_size)
          @image = image
          @converged = converged
          @iterations = iterations
          @iterations_budget = iterations_budget
          @residual = residual
          @mask_size = mask_size
        end

        # @return [Boolean] Whether the result converged.
        alias converged? converged

        # Supports <tt>image, converged, iterations, residual = result</tt>.
        # @return [Array] The image, convergence flag, iterations and residual.
        def to_a
          [image, converged, iterations, residual]
        end
      end

      # Blends pixels from +source+ into this canvas using a binary mask.
      #
      # The mask and source have the same dimensions. A mask pixel is active
      # when its alpha byte is fully opaque; all other mask pixels are
      # inactive. RGB bytes of the mask are ignored, so black and white opaque
      # masks both work. Active pixels may contain holes and several
      # disconnected components. Every component must touch at least one
      # inactive destination pixel; that pixel supplies the Dirichlet value.
      #
      # In +:source_gradients+ mode the divergence of the source gradients is
      # preserved (classic seamless cloning). In +:mixed_gradients+ mode each
      # directed edge and color channel uses whichever of source or target
      # gradient has the larger absolute value. Out-of-bounds source edges
      # contribute a zero gradient; only in-bounds destination neighbors are
      # part of the Laplacian stencil.
      #
      # RGB channels are solved independently. The returned alpha byte at each
      # destination pixel is that pixel's original destination alpha; source
      # and mask alpha do not affect the solve. RGB channels use unassociated
      # channel values. Solved RGB values are clamped to 0..255 only when a
      # converged result is written.
      #
      # @param [ChunkyPNG::Canvas] source Source image.
      # @param [ChunkyPNG::Canvas] mask Binary source-sized mask.
      # @param [Integer] offset_x Destination x coordinate of source origin.
      # @param [Integer] offset_y Destination y coordinate of source origin.
      # @param [Symbol] mode +:source_gradients+ or +:mixed_gradients+.
      # @param [Integer] iterations_budget Maximum Gauss-Seidel sweeps per
      #   color channel.
      # @param [Float] tolerance Maximum accepted residual in 8-bit units.
      # @param [Symbol] solver +:gauss_seidel+, or +:exact+ for a small-mask
      #   direct Gaussian elimination solution.
      # @return [ChunkyPNG::Canvas::PoissonBlending::Result] Solver result.
      # @raise [ArgumentError] On invalid dimensions, mode, mask, budget or
      #   tolerance.
      # @raise [ChunkyPNG::OutOfBounds] When an active pixel falls outside the
      #   destination.
      def poisson_blend(
        source,
        mask,
        offset_x = 0,
        offset_y = 0,
        mode: :source_gradients,
        iterations_budget: 10_000,
        tolerance: 1e-3,
        solver: :gauss_seidel
      )
        validate_poisson_inputs!(source, mask, mode, iterations_budget, tolerance, solver)

        active = poisson_active_mask(mask)
        raise ArgumentError, "Mask must contain at least one active pixel!" if active.empty?

        positions = active.map { |index| poisson_position(index, mask.width) }
        target_map, target_neighbors = poisson_target_mapping(positions, offset_x, offset_y)
        ensure_poisson_boundaries!(target_neighbors)

        result_pixels = pixels.dup
        max_residual = 0.0
        max_iterations = 0
        converged = true

        [:r, :g, :b].each do |channel|
          problem = poisson_problem(
            channel, source, positions, target_neighbors,
            offset_x, offset_y, mode
          )

          values, iterations, residual, channel_converged =
            if solver == :exact
              poisson_solve_exact(problem, tolerance)
            else
              poisson_solve_gauss_seidel(problem, iterations_budget, tolerance)
            end

          max_residual = [max_residual, residual].max
          max_iterations = [max_iterations, iterations].max
          converged &&= channel_converged
          poisson_write_channel!(result_pixels, positions, offset_x, offset_y, values, channel)
        end

        image = converged ? self.class.new(width, height, result_pixels) : nil
        Result.new(
          image, converged, max_iterations, iterations_budget, max_residual, active.length
        )
      end

      private

      def validate_poisson_inputs!(source, mask, mode, iterations_budget, tolerance, solver)
        unless source.is_a?(Canvas) && mask.is_a?(Canvas)
          raise ArgumentError, "Source and mask must be ChunkyPNG canvases!"
        end
        unless source.width == mask.width && source.height == mask.height
          raise ArgumentError, "Source and mask must have the same dimensions!"
        end
        unless [:source_gradients, :mixed_gradients].include?(mode)
          raise ArgumentError, "Mode must be :source_gradients or :mixed_gradients!"
        end
        unless [:gauss_seidel, :exact].include?(solver)
          raise ArgumentError, "Solver must be :gauss_seidel or :exact!"
        end
        unless iterations_budget.is_a?(Integer) && iterations_budget >= 0
          raise ArgumentError, "Iterations budget must be a non-negative integer!"
        end
        unless tolerance.is_a?(Numeric) && tolerance >= 0
          raise ArgumentError, "Tolerance must be non-negative!"
        end
      end

      def poisson_active_mask(mask)
        active = []
        mask.pixels.each_with_index do |pixel, index|
          alpha = ChunkyPNG::Color.a(pixel)
          unless alpha.zero? || alpha == ChunkyPNG::Color::MAX
            raise ArgumentError, "Mask must be binary (alpha values 0 or 255)!"
          end
          active << index if alpha == ChunkyPNG::Color::MAX
        end
        active
      end

      def poisson_position(index, source_width)
        [index % source_width, index / source_width]
      end

      def poisson_target_mapping(positions, offset_x, offset_y)
        target_map = Array.new(width * height)
        target_positions = []

        positions.each_with_index do |(source_x, source_y), unknown|
          target_x = source_x + offset_x
          target_y = source_y + offset_y
          unless include_xy?(target_x, target_y)
            raise ChunkyPNG::OutOfBounds, "Active mask pixel falls outside the destination!"
          end

          target_index = target_y * width + target_x
          target_map[target_index] = unknown
          target_positions << [target_x, target_y, target_index]
        end

        neighbors = [[0, -1], [0, 1], [-1, 0], [1, 0]].map do |delta_x, delta_y|
          target_positions.map do |target_x, target_y, _|
            neighbor_x = target_x + delta_x
            neighbor_y = target_y + delta_y
            unless include_xy?(neighbor_x, neighbor_y)
              nil
            else
              neighbor_index = neighbor_y * width + neighbor_x
              if target_map[neighbor_index]
                [:unknown, target_map[neighbor_index]]
              else
                [:boundary, pixels[neighbor_index]]
              end
            end
          end
        end

        [target_map, neighbors.transpose]
      end

      def ensure_poisson_boundaries!(target_neighbors)
        seen = Array.new(target_neighbors.length, false)
        queue = []

        target_neighbors.each_with_index do |_, start|
          next if seen[start]
          seen[start] = true
          queue << start
          has_boundary = false

          until queue.empty?
            current = queue.shift
            target_neighbors[current].each do |neighbor|
              next unless neighbor
              has_boundary ||= neighbor.first == :boundary
              unknown = neighbor[1]
              if neighbor.first == :unknown && !seen[unknown]
                seen[unknown] = true
                queue << unknown
              end
            end
          end

          unless has_boundary
            raise ArgumentError, "Every disconnected mask component must touch a target boundary!"
          end
        end
      end

      def poisson_problem(
        channel, source, positions, target_neighbors, offset_x, offset_y, mode
      )
        size = positions.length
        rhs = Array.new(size, 0.0)
        initial = Array.new(size)
        directions = [[0, -1], [0, 1], [-1, 0], [1, 0]]

        positions.each_with_index do |(source_x, source_y), index|
          target_x = source_x + offset_x
          target_y = source_y + offset_y
          center_pixel = pixels[target_y * width + target_x]
          initial[index] = poisson_channel_value(center_pixel, channel).to_f

          target_neighbors[index].each_with_index do |neighbor, edge_index|
            next unless neighbor

            delta_x, delta_y = directions[edge_index]
            source_neighbor_x = source_x + delta_x
            source_neighbor_y = source_y + delta_y
            source_gradient =
              if source.include_xy?(source_neighbor_x, source_neighbor_y)
                source_current = source.get_pixel(source_x, source_y)
                source_neighbor = source.get_pixel(source_neighbor_x, source_neighbor_y)
                poisson_channel_value(source_neighbor, channel) -
                  poisson_channel_value(source_current, channel)
              else
                0.0
              end

            gradient = source_gradient
            if mode == :mixed_gradients
              destination_pixel = center_pixel
              target_neighbor_pixel =
                if neighbor[0] == :boundary
                  neighbor[1]
                else
                  neighbor_source_x, neighbor_source_y = positions[neighbor[1]]
                  neighbor_target_x = neighbor_source_x + offset_x
                  neighbor_target_y = neighbor_source_y + offset_y
                  get_pixel(neighbor_target_x, neighbor_target_y)
                end
              target_gradient =
                poisson_channel_value(target_neighbor_pixel, channel) -
                  poisson_channel_value(destination_pixel, channel)
              gradient = target_gradient.abs > source_gradient.abs ? target_gradient : source_gradient
            end

            rhs[index] += gradient
            if neighbor[0] == :boundary
              rhs[index] += poisson_channel_value(neighbor[1], channel)
            end
          end
        end

        {neighbors: target_neighbors, rhs: rhs, initial: initial}
      end

      def poisson_channel_value(pixel, channel)
        case channel
        when :r then ChunkyPNG::Color.r(pixel)
        when :g then ChunkyPNG::Color.g(pixel)
        else ChunkyPNG::Color.b(pixel)
        end
      end

      def poisson_solve_gauss_seidel(problem, iterations_budget, tolerance)
        values = problem[:initial].dup
        iterations = 0
        residual = poisson_residual(problem, values)

        if residual <= tolerance
          return [values, iterations, residual, true]
        end

        while iterations < iterations_budget
          iterations += 1
          problem[:neighbors].each_with_index do |neighbors, index|
            sum = problem[:rhs][index]
            degree = 0

            neighbors.each do |neighbor|
              next unless neighbor
              degree += 1
              sum += values[neighbor[1]] if neighbor[0] == :unknown
            end

            values[index] = sum / degree
          end

          residual = poisson_residual(problem, values)
          if residual <= tolerance
            return [values, iterations, residual, true]
          end
        end

        [values, iterations, residual, false]
      end

      def poisson_residual(problem, values)
        max_residual = 0.0

        problem[:neighbors].each_with_index do |neighbors, index|
          degree = 0
          sum = problem[:rhs][index]

          neighbors.each do |neighbor|
            next unless neighbor
            degree += 1
            sum += values[neighbor[1]] if neighbor[0] == :unknown
          end

          residual = (degree * values[index] - sum).abs
          max_residual = residual if residual > max_residual
        end

        max_residual
      end

      def poisson_solve_exact(problem, tolerance)
        size = problem[:rhs].length
        matrix = Array.new(size) { Array.new(size + 1, 0.0) }

        problem[:neighbors].each_with_index do |neighbors, row|
          matrix[row][row] = neighbors.compact.length
          matrix[row][size] = problem[:rhs][row]
          neighbors.each do |neighbor|
            if neighbor && neighbor[0] == :unknown
              matrix[row][neighbor[1]] -= 1
            end
          end
        end

        values = poisson_gaussian_elimination(matrix)
        residual = poisson_residual(problem, values)
        [values, 0, residual, residual <= tolerance]
      end

      def poisson_gaussian_elimination(matrix)
        size = matrix.length

        size.times do |pivot|
          pivot_row = (pivot...size).max_by { |row| matrix[row][pivot].abs }
          if matrix[pivot_row][pivot].abs < 1e-12
            raise ArgumentError, "Poisson system is singular!"
          end

          matrix[pivot], matrix[pivot_row] = matrix[pivot_row], matrix[pivot]
          pivot_value = matrix[pivot][pivot]
          (pivot...(size + 1)).each { |column| matrix[pivot][column] /= pivot_value }

          size.times do |row|
            next if row == pivot
            factor = matrix[row][pivot]
            next if factor.zero?
            (pivot...(size + 1)).each do |column|
              matrix[row][column] -= factor * matrix[pivot][column]
            end
          end
        end

        matrix.map { |row| row[size] }
      end

      def poisson_write_channel!(pixels, positions, offset_x, offset_y, values, channel)
        positions.each_with_index do |(source_x, source_y), index|
          target_x = source_x + offset_x
          target_y = source_y + offset_y
          pixel_index = target_y * width + target_x
          pixel = pixels[pixel_index]
          value = values[index].round
          value = 0 if value < 0
          value = ChunkyPNG::Color::MAX if value > ChunkyPNG::Color::MAX

          r = ChunkyPNG::Color.r(pixel)
          g = ChunkyPNG::Color.g(pixel)
          b = ChunkyPNG::Color.b(pixel)
          a = ChunkyPNG::Color.a(pixel)

          case channel
          when :r then r = value
          when :g then g = value
          else b = value
          end

          pixels[pixel_index] = ChunkyPNG::Color.rgba(r, g, b, a)
        end
      end
    end
  end
end
