# frozen-string-literal: true

module ChunkyPNG
  class Canvas
    # Color-managed alpha compositing for canvas instances.
    module ColorManagement
      # Composes another canvas after converting both images to linear sRGB.
      #
      # @option options [ChunkyPNG::ColorSpace] :foreground_color_space
      # @option options [ChunkyPNG::ColorSpace] :background_color_space
      # @option options [Symbol] :on_missing_color_profile Either
      #   +:assume_srgb+ (default), +:raise+, or +:assume_linear+.
      # @option options [Symbol] :on_conflicting_color_metadata Either
      #   +:raise+ (default), +:prefer_srgb+, +:prefer_gama_chrm+, +:first+, or
      #   +:last+.
      # @option options [Symbol] :on_invalid_white_point Either +:raise+
      #   (default) or +:assume_srgb+.
      def compose_managed!(other, offset_x = 0, offset_y = 0, options = {})
        check_size_constraints!(other, offset_x, offset_y)

        foreground_space = resolve_foreground_color_space(other, options)
        destination_space = resolve_background_color_space(options)

        for y in 0...other.height do
          for x in 0...other.width do
            destination_x = x + offset_x
            destination_y = y + offset_y
            set_pixel(
              destination_x,
              destination_y,
              ChunkyPNG::Color.compose_managed(
                other.get_pixel(x, y),
                get_pixel(destination_x, destination_y),
                foreground_space,
                destination_space
              )
            )
          end
        end
        self
      end

      def compose_managed(other, offset_x = 0, offset_y = 0, options = {})
        dup.compose_managed!(other, offset_x, offset_y, options)
      end

      alias compose_color_managed! compose_managed!
      alias compose_color_managed compose_managed
      alias color_managed_compose! compose_managed!
      alias color_managed_compose compose_managed

      def resolve_color_space(options = {})
        return color_space if color_space

        chunks = color_profile_chunks || {}
        ColorSpace.from_chunks(
          chunks[:srgb],
          chunks[:gama],
          chunks[:chrm],
          normalized_color_profile_options(options)
        )
      end

      private

      def resolve_foreground_color_space(other, options)
        options[:foreground_color_space] ||
          options[:source_color_space] ||
          options[:fg_color_space] ||
          other.resolve_color_space(options)
      end

      def resolve_background_color_space(options)
        options[:background_color_space] ||
          options[:destination_color_space] ||
          options[:bg_color_space] ||
          resolve_color_space(options)
      end

      def normalized_color_profile_options(options)
        normalized = ColorSpace::DEFAULT_POLICIES.dup
        aliases = {
          on_missing_color_profile: [
            :missing_color_profile_policy, :on_missing_color_profile,
            :on_missing, :missing_policy
          ],
          on_conflicting_color_metadata: [
            :conflicting_color_metadata_policy, :on_conflicting_color_metadata,
            :on_conflict, :conflict_policy
          ],
          on_invalid_white_point: [
            :invalid_white_point_policy, :on_invalid_white_point,
            :white_point_policy
          ],
        }
        aliases.each do |key, option_names|
          option_names.each do |name|
            normalized[key] = options[name] if options.key?(name)
          end
        end
        normalized
      end
    end
  end
end
