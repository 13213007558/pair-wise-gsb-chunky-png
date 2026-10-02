# frozen_string_literal: true

module ChunkyPNG
  class Canvas
    # Exposes signed Euclidean distance field computation on a canvas.
    module DistanceField
      # Builds a binary alpha mask and computes its signed Euclidean distance
      # field. See {ChunkyPNG::DistanceField.signed_euclidean_distance} for the
      # distance, sign, all-empty, all-foreground, and image-exterior rules.
      #
      # @param [Integer] alpha_threshold Inclusive alpha threshold. A pixel is
      #   foreground when its alpha value is greater than or equal to this
      #   value. Defaults to 128.
      # @return [Array<Float>] The row-major signed distance field.
      def signed_euclidean_distance_field(alpha_threshold = 128)
        unless alpha_threshold.between?(0, ChunkyPNG::Color::MAX)
          raise ArgumentError, "The alpha threshold should be between 0 and 255!"
        end

        mask = pixels.map { |pixel| ChunkyPNG::Color.a(pixel) >= alpha_threshold }
        ChunkyPNG::DistanceField.signed_euclidean_distance(mask, width, height)
      end

      alias signed_distance_field signed_euclidean_distance_field
      alias_method :signed_euclidean_distance, :signed_euclidean_distance_field
    end
  end
end
