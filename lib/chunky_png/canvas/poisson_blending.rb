# frozen-string-literal: true

module ChunkyPNG
  class Canvas
    # The ChunkyPNG::Canvas::PoissonBlending module implements Poisson image
    # editing (seamless cloning) as an alternative to plain alpha blending
    # when pasting one image onto another. Instead of copying the source
    # colors, it copies the source *gradients* into the masked region and
    # solves the Poisson equation so the pasted region blends smoothly into
    # the target image, avoiding visible seams at the mask boundary.
    #
    # The module is included into {ChunkyPNG::Canvas}, so every canvas can be
    # used as the target image for a blend.
    #
    # == Boundary conditions
    #
    # The Poisson equation is solved for every target pixel that is covered
    # by the mask (after applying the offset). For each such pixel, its four
    # direct neighbors are treated as follows:
    #
    # * Neighbors inside the canvas but outside the mask are *Dirichlet*
    #   boundary conditions: their value is fixed to the current target
    #   color. This is what preserves the target image around (and inside
    #   holes of) the masked region.
    # * Neighbors outside the canvas are *Neumann* boundary conditions with
    #   zero flux: the gradient across the canvas edge is assumed to be zero,
    #   so those neighbors simply drop out of the equation. This allows masks
    #   that touch the canvas edges.
    # * Source pixels that fall outside the source canvas contribute a zero
    #   guidance gradient for that direction.
    #
    # Masks may contain holes and may consist of multiple disconnected
    # regions; every connected region is solved independently within the same
    # linear system. If a connected region has no Dirichlet boundary at all
    # (e.g. the mask covers the entire canvas), the system would be
    # underdetermined; in that case the first pixel of that region is pinned
    # to its current target color to make the system well-posed.
    #
    # Only the red, green and blue channels are solved; the alpha channel of
    # the target image is left untouched everywhere.
    module PoissonBlending
      # The four neighbor directions used for the discrete Laplace operator.
      # @private
      DIRECTIONS = [[1, 0], [-1, 0], [0, 1], [0, -1]].freeze

      # The outcome of a {ChunkyPNG::Canvas#poisson_blend} call.
      #
      # Besides the blended image, it reports whether the solver converged,
      # how many iterations were performed and the final residual of the
      # linear system. When the solver reaches the iteration limit before
      # reaching the requested tolerance, {#converged?} returns false and
      # {#residual} reports the remaining error, so a non-converged result
      # can never be mistaken for a successful blend.
      class Result
        # @return [ChunkyPNG::Canvas] The blended image. Pixels outside the
        #   mask are identical to the target image.
        attr_reader :image

        # @return [Integer] The number of solver iterations performed.
        attr_reader :iterations

        # @return [Float] The final residual of the linear system, i.e. the
        #   infinity norm of <tt>A x - b</tt> over all masked pixels and
        #   color channels, expressed in color channel units (0-255).
        attr_reader :residual

        # @return [Integer] The number of masked pixels that were solved for.
        attr_reader :mask_size

        def initialize(image:, iterations:, residual:, converged:, mask_size:)
          @image = image
          @iterations = iterations
          @residual = residual
          @converged = converged
          @mask_size = mask_size
        end

        # @return [Boolean] true when the solver reached the requested
        #   tolerance within the iteration limit, false otherwise.
        def converged?
          @converged
        end
      end

      # Blends a source image into this canvas using Poisson blending,
      # returning a {PoissonBlending::Result} with the blended image and
      # solver diagnostics. This canvas is left unmodified.
      #
      # @param [ChunkyPNG::Canvas] source The source image providing the
      #   guidance gradients.
      # @param [ChunkyPNG::Canvas] mask A canvas with the same dimensions as
      #   the source image. A pixel belongs to the blended region when it is
      #   both non-transparent and non-black (i.e. its alpha channel and at
      #   least one color channel are non-zero).
      # @param [Integer] offset_x The horizontal offset of the source image
      #   on this canvas.
      # @param [Integer] offset_y The vertical offset of the source image on
      #   this canvas.
      # @param [Symbol] mode The guidance field to use: +:normal+ uses the
      #   source gradients, +:mixed+ uses, per direction and channel,
      #   whichever of the source and target gradient has the larger
      #   magnitude ("mixed gradients" from the Poisson image editing paper).
      # @param [Symbol] solver The linear solver to use: +:iterative+ uses
      #   Gauss-Seidel iteration, +:direct+ assembles and solves the linear
      #   system directly with Gaussian elimination. The direct solver is
      #   only practical for small masks and mainly serves as a reference.
      # @param [Integer] max_iterations The maximum number of iterations for
      #   the iterative solver. Reaching this limit means the result did not
      #   converge, which is reported via the returned result object.
      # @param [Float] tolerance The residual (in color channel units) at
      #   which the iterative solver is considered converged.
      # @return [ChunkyPNG::Canvas::PoissonBlending::Result] The blend result.
      # @raise [ChunkyPNG::ExpectationFailed] when the mask dimensions do not
      #   match the source dimensions, or when an unknown mode or solver is
      #   requested.
      # @see #poisson_blend!
      def poisson_blend(source, mask, offset_x = 0, offset_y = 0, mode: :normal, solver: :iterative, max_iterations: 2000, tolerance: 0.5)
        unless mask.width == source.width && mask.height == source.height
          raise ChunkyPNG::ExpectationFailed,
            "The mask dimensions (#{mask.width}x#{mask.height}) must match the source dimensions (#{source.width}x#{source.height})"
        end
        unless [:normal, :mixed].include?(mode)
          raise ChunkyPNG::ExpectationFailed, "Unknown Poisson blending mode: #{mode.inspect}"
        end
        unless [:iterative, :direct].include?(solver)
          raise ChunkyPNG::ExpectationFailed, "Unknown Poisson blending solver: #{solver.inspect}"
        end

        system = poisson_system(source, mask, offset_x, offset_y, mode)
        unknowns = system[:unknowns]

        if unknowns.empty?
          return Result.new(image: dup, iterations: 0, residual: 0.0, converged: true, mask_size: 0)
        end

        if solver == :direct
          solution = poisson_solve_direct(system)
          iterations = 1
        else
          solution, iterations = poisson_solve_iterative(system, max_iterations, tolerance)
        end
        residual = poisson_residual(system, solution)

        image = dup
        unknowns.each_with_index do |(x, y), i|
          alpha = ChunkyPNG::Color.a(image.pixels[y * width + x])
          image.pixels[y * width + x] = ChunkyPNG::Color.rgba(
            poisson_channel_to_byte(solution[i][0]),
            poisson_channel_to_byte(solution[i][1]),
            poisson_channel_to_byte(solution[i][2]),
            alpha
          )
        end

        Result.new(
          image: image,
          iterations: iterations,
          residual: residual,
          converged: residual <= tolerance,
          mask_size: unknowns.length
        )
      end

      # Blends a source image into this canvas using Poisson blending,
      # replacing the pixels of this canvas with the blended result.
      #
      # @param (see #poisson_blend)
      # @return [ChunkyPNG::Canvas::PoissonBlending::Result] The blend result.
      # @see #poisson_blend
      def poisson_blend!(source, mask, offset_x = 0, offset_y = 0, **options)
        result = poisson_blend(source, mask, offset_x, offset_y, **options)
        pixels.replace(result.image.pixels)
        result
      end

      private

      # Assembles the Poisson equation system for the masked region.
      #
      # For every masked pixel p with color channel value x_p:
      #
      #   N_p * x_p - sum(x_q for masked neighbors q) = b_p
      #
      # where N_p is the number of neighbors of p inside the canvas and b_p
      # accumulates the Dirichlet boundary values (target colors of unmasked
      # neighbors) and the guidance gradients.
      #
      # @return [Hash] the unknown coordinates, per-unknown neighbor count,
      #   neighbor unknown indices, right-hand side and initial solution
      #   (the current target colors).
      # @private
      def poisson_system(source, mask, offset_x, offset_y, mode)
        unknown_index = {}
        unknowns = []

        for sy in 0...source.height
          y = sy + offset_y
          next if y < 0 || y >= height
          for sx in 0...source.width
            x = sx + offset_x
            next if x < 0 || x >= width
            next unless poisson_mask_on?(mask.pixels[sy * mask.width + sx])
            unknown_index[y * width + x] = unknowns.length
            unknowns << [x, y]
          end
        end

        counts = []
        neighbors = []
        rhs = []
        initial = []
        dirichlet = []

        unknowns.each do |(x, y)|
          sx = x - offset_x
          sy = y - offset_y
          source_pixel = source.pixels[sy * source.width + sx]
          target_pixel = pixels[y * width + x]

          count = 0
          neighbor_indices = []
          boundary = false
          br = 0.0
          bg = 0.0
          bb = 0.0

          DIRECTIONS.each do |dx, dy|
            qx = x + dx
            qy = y + dy
            # Neumann boundary: zero gradient across the canvas edge.
            next if qx < 0 || qy < 0 || qx >= width || qy >= height
            count += 1

            vr, vg, vb = poisson_guidance(source, sx, sy, dx, dy, qx, qy, source_pixel, target_pixel, mode)
            br += vr
            bg += vg
            bb += vb

            neighbor = unknown_index[qy * width + qx]
            if neighbor
              neighbor_indices << neighbor
            else
              # Dirichlet boundary: fixed at the current target color.
              boundary_pixel = pixels[qy * width + qx]
              br += ChunkyPNG::Color.r(boundary_pixel)
              bg += ChunkyPNG::Color.g(boundary_pixel)
              bb += ChunkyPNG::Color.b(boundary_pixel)
              boundary = true
            end
          end

          counts << count
          neighbors << neighbor_indices
          rhs << [br, bg, bb]
          dirichlet << boundary
          initial << [
            ChunkyPNG::Color.r(target_pixel).to_f,
            ChunkyPNG::Color.g(target_pixel).to_f,
            ChunkyPNG::Color.b(target_pixel).to_f
          ]
        end

        poisson_pin_unbounded_components(unknowns, counts, neighbors, rhs, dirichlet)

        {
          unknowns: unknowns,
          counts: counts,
          neighbors: neighbors,
          rhs: rhs,
          initial: initial
        }
      end

      # Computes the guidance gradient for one direction of one masked pixel.
      #
      # In +:normal+ mode this is the source gradient. In +:mixed+ mode it
      # is, per color channel, whichever of the source and target gradient
      # has the larger absolute value. Directions for which the source
      # neighbor falls outside the source canvas contribute a zero source
      # gradient.
      #
      # @return [Array<Float>] the guidance gradient per color channel.
      # @private
      def poisson_guidance(source, sx, sy, dx, dy, qx, qy, source_pixel, target_pixel, mode)
        sqx = sx + dx
        sqy = sy + dy

        if sqx >= 0 && sqy >= 0 && sqx < source.width && sqy < source.height
          neighbor_pixel = source.pixels[sqy * source.width + sqx]
          vr = ChunkyPNG::Color.r(source_pixel) - ChunkyPNG::Color.r(neighbor_pixel)
          vg = ChunkyPNG::Color.g(source_pixel) - ChunkyPNG::Color.g(neighbor_pixel)
          vb = ChunkyPNG::Color.b(source_pixel) - ChunkyPNG::Color.b(neighbor_pixel)
        else
          vr = vg = vb = 0
        end

        return [vr, vg, vb] if mode == :normal

        target_neighbor = pixels[qy * width + qx]
        [
          poisson_mixed_gradient(vr, ChunkyPNG::Color.r(target_pixel) - ChunkyPNG::Color.r(target_neighbor)),
          poisson_mixed_gradient(vg, ChunkyPNG::Color.g(target_pixel) - ChunkyPNG::Color.g(target_neighbor)),
          poisson_mixed_gradient(vb, ChunkyPNG::Color.b(target_pixel) - ChunkyPNG::Color.b(target_neighbor))
        ]
      end

      # Picks whichever of the source and target gradient has the larger
      # absolute value, for one color channel.
      # @private
      def poisson_mixed_gradient(source_gradient, target_gradient)
        (source_gradient.abs >= target_gradient.abs) ? source_gradient : target_gradient
      end

      # A mask pixel marks the region to blend when it is both non-transparent
      # and non-black.
      # @private
      def poisson_mask_on?(pixel)
        ChunkyPNG::Color.a(pixel) > 0 &&
          (ChunkyPNG::Color.r(pixel) | ChunkyPNG::Color.g(pixel) | ChunkyPNG::Color.b(pixel)) > 0
      end

      # @private
      def poisson_channel_to_byte(value)
        byte = value.round
        return 0 if byte < 0
        return 255 if byte > 255
        byte
      end

      # Finds connected components of masked pixels that have no Dirichlet
      # boundary at all (e.g. a mask covering the entire canvas). The
      # Poisson equation is underdetermined for such components, so the
      # first pixel of each of them is pinned to its current target color.
      # @private
      def poisson_pin_unbounded_components(unknowns, counts, neighbors, rhs, dirichlet)
        visited = Array.new(unknowns.length, false)

        unknowns.each_index do |start|
          next if visited[start]

          bounded = false
          component = []
          queue = [start]
          visited[start] = true
          until queue.empty?
            current = queue.pop
            component << current
            bounded ||= dirichlet[current]
            neighbors[current].each do |neighbor|
              next if visited[neighbor]
              visited[neighbor] = true
              queue << neighbor
            end
          end

          next if bounded

          pinned = component.first
          x, y = unknowns[pinned]
          target_pixel = pixels[y * width + x]
          counts[pinned] = 1
          neighbors[pinned] = []
          rhs[pinned] = [
            ChunkyPNG::Color.r(target_pixel).to_f,
            ChunkyPNG::Color.g(target_pixel).to_f,
            ChunkyPNG::Color.b(target_pixel).to_f
          ]
        end
      end

      # Solves the Poisson system with Gauss-Seidel iteration, starting from
      # the current target colors. Stops as soon as the residual drops to or
      # below the tolerance, or when the iteration limit is reached.
      #
      # @return [Array(Array<Array<Float>>, Integer)] the solution and the
      #   number of iterations performed.
      # @private
      def poisson_solve_iterative(system, max_iterations, tolerance)
        counts = system[:counts]
        neighbors = system[:neighbors]
        rhs = system[:rhs]
        solution = system[:initial].map(&:dup)

        iterations = 0
        while iterations < max_iterations
          iterations += 1
          solution.each_index do |i|
            sum_r = rhs[i][0]
            sum_g = rhs[i][1]
            sum_b = rhs[i][2]
            neighbors[i].each do |j|
              sum_r += solution[j][0]
              sum_g += solution[j][1]
              sum_b += solution[j][2]
            end
            count = counts[i]
            solution[i][0] = sum_r / count
            solution[i][1] = sum_g / count
            solution[i][2] = sum_b / count
          end
          break if poisson_residual(system, solution) <= tolerance
        end

        [solution, iterations]
      end

      # Solves the Poisson system directly with Gaussian elimination with
      # partial pivoting. The system matrix is dense, so this is only
      # practical for small masks; it mainly serves as a reference for the
      # iterative solver.
      #
      # @return [Array<Array<Float>>] the solution.
      # @private
      def poisson_solve_direct(system)
        counts = system[:counts]
        neighbors = system[:neighbors]
        size = counts.length

        matrix = Array.new(size) { Array.new(size, 0.0) }
        rhs = Array.new(size) { |i| system[:rhs][i].dup }
        size.times do |i|
          matrix[i][i] = counts[i].to_f
          neighbors[i].each { |j| matrix[i][j] -= 1.0 }
        end

        size.times do |column|
          pivot = column
          (column + 1...size).each do |row|
            pivot = row if matrix[row][column].abs > matrix[pivot][column].abs
          end
          if matrix[pivot][column].zero?
            raise ChunkyPNG::Exception, "The Poisson system is singular and cannot be solved directly"
          end
          unless pivot == column
            matrix[column], matrix[pivot] = matrix[pivot], matrix[column]
            rhs[column], rhs[pivot] = rhs[pivot], rhs[column]
          end
          (column + 1...size).each do |row|
            factor = matrix[row][column] / matrix[column][column]
            next if factor.zero?
            (column...size).each do |k|
              matrix[row][k] -= factor * matrix[column][k]
            end
            3.times { |c| rhs[row][c] -= factor * rhs[column][c] }
          end
        end

        solution = Array.new(size) { [0.0, 0.0, 0.0] }
        (size - 1).downto(0) do |row|
          3.times do |c|
            sum = rhs[row][c]
            (row + 1...size).each do |k|
              sum -= matrix[row][k] * solution[k][c]
            end
            solution[row][c] = sum / matrix[row][row]
          end
        end
        solution
      end

      # Computes the residual of a solution as the infinity norm of
      # <tt>A x - b</tt> over all masked pixels and color channels.
      #
      # @return [Float] the residual in color channel units.
      # @private
      def poisson_residual(system, solution)
        counts = system[:counts]
        neighbors = system[:neighbors]
        rhs = system[:rhs]

        residual = 0.0
        solution.each_index do |i|
          3.times do |c|
            value = counts[i] * solution[i][c] - rhs[i][c]
            neighbors[i].each { |j| value -= solution[j][c] }
            residual = value.abs if value.abs > residual
          end
        end
        residual
      end
    end
  end
end
