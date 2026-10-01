# frozen-string-literal: true

module ChunkyPNG
  class Canvas
    # Pure Ruby Poisson image blending.
    #
    # The discrete Poisson equation is solved independently for the red,
    # green, and blue channels. The target alpha channel is preserved.
    module PoissonBlending
      # The result of a Poisson blend.
      class Result
        # @return [ChunkyPNG::Canvas] The blended canvas.
        attr_reader :canvas

        # @return [Symbol] +:converged+ or +:max_iterations+.
        attr_reader :status

        # @return [Float] Maximum absolute residual in color-value units.
        attr_reader :residual

        # @return [Integer] Number of iterations used by the iterative solver.
        attr_reader :iterations

        # @return [Symbol] The solver that produced the result.
        attr_reader :solver

        def initialize(canvas, status, residual, iterations, solver)
          @canvas = canvas
          @status = status
          @residual = residual
          @iterations = iterations
          @solver = solver
        end

        # @return [Boolean] Whether the requested tolerance was reached.
        def converged?
          status == :converged
        end
      end

      # Poisson-composes a source canvas onto this target canvas.
      #
      # Mask pixels with a nonzero alpha value are blended. A source-sized
      # mask is interpreted in source coordinates. When the mask has the
      # target dimensions, it is interpreted in target coordinates and the
      # offset only locates source samples. Active pixels outside the target
      # canvas are clipped away; every retained active pixel must have a
      # source pixel.
      #
      # Target pixels adjacent to an inactive or absent mask pixel are fixed
      # Dirichlet boundary values. A direction that leaves the target canvas
      # contributes no equation term or guidance value (a zero Neumann edge).
      # Mask holes are therefore fixed target boundaries. If a connected mask
      # component covers the entire canvas and has no fixed target neighbor,
      # one pixel in that component is anchored to the target value to remove
      # the constant ambiguity of the Poisson equation.
      #
      # @param [ChunkyPNG::Canvas] source The source image supplying guidance.
      # @param [ChunkyPNG::Canvas] mask The binary or alpha mask.
      # @param [Integer] offset_x X position of the source on the target.
      # @param [Integer] offset_y Y position of the source on the target.
      # @param [Hash] options Solver options.
      # @option options [Symbol] :gradient +:normal+ (default) uses source
      #   gradients; +:mixed+ selects the stronger source or target gradient.
      # @option options [Symbol] :solver +:auto+ (default), +:direct+, or
      #   +:gauss_seidel+.
      # @option options [Integer] :max_iterations Iteration limit (1000).
      # @option options [Float] :tolerance Maximum residual tolerance (0.5).
      # @option options [Integer] :direct_limit Maximum unknown count for the
      #   automatic direct solver (256).
      # @return [ChunkyPNG::Canvas::PoissonBlending::Result] The result.
      def poisson_compose!(source, mask, offset_x = 0, offset_y = 0, options = {})
        result = PoissonBlending.blend(self, source, mask, offset_x, offset_y, options)
        pixels = result.canvas.pixels.dup
        result.canvas.replace_canvas!(width, height, pixels.dup)
        replace_canvas!(width, height, pixels)
        result
      end

      alias poisson_blend! poisson_compose!

      # Solves a Poisson blend without modifying this canvas.
      # @see #poisson_compose!
      def poisson_compose(source, mask, offset_x = 0, offset_y = 0, options = {})
        dup.poisson_compose!(source, mask, offset_x, offset_y, options)
      end

      alias poisson_blend poisson_compose

      class << self
        # Builds and solves a Poisson blending problem without depending on
        # instance methods so the algorithm is also usable directly.
        #
        # @param (see ChunkyPNG::Canvas#poisson_compose!)
        # @return [ChunkyPNG::Canvas::PoissonBlending::Result]
        def blend(target, source, mask, offset_x = 0, offset_y = 0, options = {})
          gradient = options.fetch(:gradient, :normal).to_sym
          unless gradient == :normal || gradient == :mixed
            raise ArgumentError, "gradient must be :normal or :mixed"
          end

          solver = options.fetch(:solver, :auto).to_sym
          unless solver == :auto || solver == :direct || solver == :gauss_seidel
            raise ArgumentError, "solver must be :auto, :direct, or :gauss_seidel"
          end

          max_iterations = Integer(options.fetch(:max_iterations, 1000))
          tolerance = Float(options.fetch(:tolerance, 0.5))
          direct_limit = Integer(options.fetch(:direct_limit, 256))
          if max_iterations < 0 || tolerance < 0 || direct_limit < 0
            raise ArgumentError, "solver limits cannot be negative"
          end

          problem = build_problem(target, source, mask, offset_x, offset_y, gradient)
          solver = :direct if solver == :auto && problem[:count] <= direct_limit

          if solver == :direct
            solution, residual = solve_direct(problem)
            iterations = 0
          else
            solution, residual, iterations = solve_gauss_seidel(
              problem, max_iterations, tolerance
            )
          end

          converged = solver == :direct || residual <= tolerance
          status = converged ? :converged : :max_iterations
          canvas = render(target, problem, solution)
          Result.new(canvas, status, residual, iterations, solver)
        end

        private

        def build_problem(target, source, mask, offset_x, offset_y, gradient)
          mask_target_sized = mask.width == target.width && mask.height == target.height
          mask_source_sized = mask.width == source.width && mask.height == source.height
          unless mask_target_sized || mask_source_sized
            raise ArgumentError, "mask dimensions must match either the target or source"
          end

          indices = Array.new(target.width * target.height, -1)
          positions = []

          mask.height.times do |my|
            mask.width.times do |mx|
              next unless active_mask_pixel?(mask.get_pixel(mx, my))

              x = mask_target_sized ? mx : mx + offset_x
              y = mask_target_sized ? my : my + offset_y
              next unless x >= 0 && x < target.width && y >= 0 && y < target.height

              sx = x - offset_x
              sy = y - offset_y
              unless sx >= 0 && sx < source.width && sy >= 0 && sy < source.height
                raise ArgumentError, "active mask pixels must have a source pixel"
              end

              index = positions.length
              indices[y * target.width + x] = index
              positions << {x: x, y: y, sx: sx, sy: sy}
            end
          end

          count = positions.length
          neighbors = Array.new(count) { [] }
          fixed_terms = Array.new(count) { [0.0, 0.0, 0.0] }
          rhs = Array.new(count) { [0.0, 0.0, 0.0] }
          degrees = Array.new(count, 0)
          target_values = Array.new(count)

          directions = [[1, 0], [-1, 0], [0, 1], [0, -1]]

          count.times do |index|
            position = positions[index]
            x = position[:x]
            y = position[:y]
            sx = position[:sx]
            sy = position[:sy]
            center_target = target.get_pixel(x, y)
            center_source = source.get_pixel(sx, sy)
            target_values[index] = [
              ChunkyPNG::Color.r(center_target).to_f,
              ChunkyPNG::Color.g(center_target).to_f,
              ChunkyPNG::Color.b(center_target).to_f
            ]

            directions.each do |dx, dy|
              nx = x + dx
              ny = y + dy
              next unless nx >= 0 && nx < target.width && ny >= 0 && ny < target.height

              degrees[index] += 1
              neighbor_index = indices[ny * target.width + nx]
              target_pixel = target.get_pixel(nx, ny)

              if neighbor_index >= 0
                neighbors[index] << neighbor_index
              else
                fixed_terms[index][0] += ChunkyPNG::Color.r(target_pixel)
                fixed_terms[index][1] += ChunkyPNG::Color.g(target_pixel)
                fixed_terms[index][2] += ChunkyPNG::Color.b(target_pixel)
              end

              snx = sx + dx
              sny = sy + dy
              if snx >= 0 && snx < source.width && sny >= 0 && sny < source.height
                source_neighbor = source.get_pixel(snx, sny)
                guidance = gradient_values(
                  center_source, source_neighbor, center_target, target_pixel, gradient
                )
                3.times { |channel| rhs[index][channel] += guidance[channel] }
              elsif gradient == :mixed
                rhs[index][0] += ChunkyPNG::Color.r(center_target) - ChunkyPNG::Color.r(target_pixel)
                rhs[index][1] += ChunkyPNG::Color.g(center_target) - ChunkyPNG::Color.g(target_pixel)
                rhs[index][2] += ChunkyPNG::Color.b(center_target) - ChunkyPNG::Color.b(target_pixel)
              end
            end
          end

          anchors = anchor_indices(count, neighbors, degrees)

          {
            positions: positions,
            neighbors: neighbors,
            fixed_terms: fixed_terms,
            rhs: rhs,
            degrees: degrees,
            target_values: target_values,
            anchors: anchors,
            count: count
          }
        end

        def active_mask_pixel?(pixel)
          ChunkyPNG::Color.a(pixel) > 0
        end

        def gradient_values(source_center, source_neighbor, target_center, target_neighbor, gradient)
          source = [
            ChunkyPNG::Color.r(source_center) - ChunkyPNG::Color.r(source_neighbor),
            ChunkyPNG::Color.g(source_center) - ChunkyPNG::Color.g(source_neighbor),
            ChunkyPNG::Color.b(source_center) - ChunkyPNG::Color.b(source_neighbor)
          ]
          return source unless gradient == :mixed

          target = [
            ChunkyPNG::Color.r(target_center) - ChunkyPNG::Color.r(target_neighbor),
            ChunkyPNG::Color.g(target_center) - ChunkyPNG::Color.g(target_neighbor),
            ChunkyPNG::Color.b(target_center) - ChunkyPNG::Color.b(target_neighbor)
          ]

          source_magnitude = source.reduce(0.0) { |sum, value| sum + value * value }
          target_magnitude = target.reduce(0.0) { |sum, value| sum + value * value }
          target_magnitude > source_magnitude ? target : source
        end

        def anchor_indices(count, neighbors, degrees)
          visited = Array.new(count, false)
          anchors = []

          count.times do |start|
            next if visited[start]

            component = []
            queue = [start]
            visited[start] = true
            has_boundary = false

            until queue.empty?
              index = queue.shift
              component << index
              edge_count = neighbors[index].length
              has_boundary = true if edge_count < degrees[index]
              neighbors[index].each do |neighbor|
                next if visited[neighbor]
                visited[neighbor] = true
                queue << neighbor
              end
            end

            anchors << component.first unless has_boundary
          end

          anchors
        end

        def solve_gauss_seidel(problem, max_iterations, tolerance)
          count = problem[:count]
          return [[], 0.0, 0] if count.zero?

          target_values = problem[:target_values]
          solution = target_values.map { |pixel| pixel.dup }
          anchor = anchored_map(problem)

          iterations = 0
          residual = residual_norm(solution, problem, anchor)

          if max_iterations > 0 && residual > tolerance
            loop do
              iterations += 1
              update_values(solution, problem, anchor)
              residual = residual_norm(solution, problem, anchor)
              break if residual <= tolerance || iterations >= max_iterations
            end
          end

          [solution, residual, iterations]
        end

        def update_values(values, problem, anchor)
          count = problem[:count]
          count.times do |index|
            next if anchor[index]
            degree = problem[:degrees][index]
            3.times do |channel|
              sum = problem[:fixed_terms][index][channel] + problem[:rhs][index][channel]
              problem[:neighbors][index].each do |neighbor|
                sum += values[neighbor][channel]
              end
              values[index][channel] = sum / degree
            end
          end
        end

        def solve_direct(problem)
          count = problem[:count]
          return [[], 0.0] if count.zero?

          target_values = problem[:target_values]
          anchor = anchored_map(problem)
          matrix = Array.new(count) { Array.new(count + 3, 0.0) }

          count.times do |index|
            if anchor[index]
              matrix[index][index] = 1.0
              3.times { |channel| matrix[index][count + channel] = target_values[index][channel] }
            else
              matrix[index][index] = problem[:degrees][index].to_f
              problem[:neighbors][index].each { |neighbor| matrix[index][neighbor] = -1.0 }
              3.times do |channel|
                matrix[index][count + channel] =
                  problem[:fixed_terms][index][channel] + problem[:rhs][index][channel]
              end
            end
          end

          gaussian_elimination(matrix, count)
          solution = Array.new(count) { [0.0, 0.0, 0.0] }
          count.times do |index|
            3.times { |channel| solution[index][channel] = matrix[index][count + channel] }
          end

          [solution, direct_residual(solution, problem, anchor)]
        end

        def gaussian_elimination(matrix, count)
          count.times do |column|
            pivot = column
            largest = matrix[column][column].abs
            (column + 1...count).each do |row|
              candidate = matrix[row][column].abs
              next unless candidate > largest
              largest = candidate
              pivot = row
            end

            if largest < 1.0e-12
              raise ChunkyPNG::Exception, "Poisson system is singular"
            end
            matrix[column], matrix[pivot] = matrix[pivot], matrix[column] if pivot != column

            pivot_row = matrix[column]
            pivot_value = pivot_row[column]
            (column + 1...count).each do |row|
              factor = matrix[row][column] / pivot_value
              next if factor.zero?
              values = matrix[row]
              (column...(count + 3)).each do |column_index|
                values[column_index] -= factor * pivot_row[column_index]
              end
            end
          end

          (count - 1).downto(0) do |row|
            values = matrix[row]
            3.times do |channel|
              rhs_column = count + channel
              sum = values[rhs_column]
              ((row + 1)...count).each do |column|
                sum -= values[column] * matrix[column][rhs_column]
              end
              values[rhs_column] = sum / values[row]
            end
          end
        end

        def direct_residual(values, problem, anchor)
          result = 0.0

          values.each_with_index do |value, index|
            next if anchor[index]
            3.times do |channel|
              expected = problem[:fixed_terms][index][channel] + problem[:rhs][index][channel]
              problem[:neighbors][index].each { |neighbor| expected += values[neighbor][channel] }
              residual = (problem[:degrees][index] * value[channel] - expected).abs
              result = residual if residual > result
            end
          end

          result
        end

        def residual_norm(values, problem, anchor)
          result = 0.0

          values.each_with_index do |value, index|
            next if anchor[index]
            3.times do |channel|
              equation_value = problem[:degrees][index] * value[channel]
              problem[:neighbors][index].each { |neighbor| equation_value -= values[neighbor][channel] }
              equation_value -= problem[:fixed_terms][index][channel]
              equation_value -= problem[:rhs][index][channel]
              difference = equation_value.abs
              result = difference if difference > result
            end
          end

          result
        end

        def anchored_map(problem)
          anchor = Array.new(problem[:count], false)
          problem[:anchors].each { |index| anchor[index] = true }
          anchor
        end

        def render(target, problem, solution)
          canvas = target.dup
          solution.each_with_index do |value, index|
            position = problem[:positions][index]
            x = position[:x]
            y = position[:y]
            original = target.get_pixel(x, y)
            color = ChunkyPNG::Color.rgba(
              clamp_channel(value[0].round),
              clamp_channel(value[1].round),
              clamp_channel(value[2].round),
              ChunkyPNG::Color.a(original)
            )
            canvas.set_pixel(x, y, color)
          end
          canvas
        end

        def clamp_channel(value)
          return 0 if value < 0
          return 255 if value > 255
          value
        end
      end
    end
  end
end
